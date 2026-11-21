import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let classic: SpriteSheet
    private var sprites: SpriteSheet
    let settings = Settings()
    private(set) var play = Playground(position: .zero)
    private let catWindow = CatWindow()
    private let boneWindow = PropWindow(art: PixelArt.bone)
    private let boxWindow = PropWindow(art: PixelArt.box)
    private let yarnWindow = PropWindow(art: PixelArt.yarn)
    private let laserWindow = OverlayPanel()
    private let laserDot = OverlayPanel.pixelLayer()
    private(set) var laserOn = false
    let sounds = SoundBox()
    let stats = Stats()
    /// Extra cats (beyond the first, up to 50 in all), fully interactive.
    private var extras: [ExtraCat] = []
    /// Crowd mode: every cat past 50, drawn by the GPU.
    private var crowd: CrowdController?
    private let hintWindow = HintWindow()
    private var hoverSince: Double?
    private var draggingExtra: Int?
    private var coatPainter: CoatPainter?
    /// You've stepped away from the Mac (no input for 2 minutes).
    private var away = false
    private var wasAsleep = false
    private var statusItem: NSStatusItem!
    private var logicTimer: Timer?
    private var physicsTimer: Timer?
    private var world = World(screens: [], windows: [], cursor: .zero)
    private var tickCount = 0
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var dragging: Thing?
    private(set) var touchBar: TouchBarCat?
    private var monitors: [Any] = []
    private(set) var toolbox: ToolboxController?
    /// Fill With Color on the cat (Toolbox); nil = the chosen coat.
    private var paintedColor: RGBA?
    private var shrinkWork: DispatchWorkItem?

    init(sprites: SpriteSheet) {
        classic = sprites
        self.sprites = sprites
        super.init()
        self.sprites = sheetForCurrentSkin()
        world = WorldReader.read()
        play.cat.position = startPosition()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        laserDot.contents = PixelArt.laserDot.image
        laserDot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        laserDot.position = CGPoint(x: 16, y: 16)
        laserWindow.mouseView.layer?.addSublayer(laserDot)
        laserWindow.setSide(32)
        laserWindow.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        sounds.enabled = settings.sound
        sounds.volume = settings.volume
        confirmSavedCats()
        setCatCount(settings.catCount)
        applySettings()
        setUpStatusItem()
        wireMouse()
        restoreToys()
        observeSystem()
        applyHat()
        render()
        catWindow.orderFrontRegardless()
        if settings.touchBarCat && TouchBarCat.isSupported { setHome(touchBar: true) }

        setLogicRate(deepSleep ? 1.0 : 0.1)
        if !settings.seenWelcome {
            settings.seenWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWelcome() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePositions()
        touchBar?.uninstall()
    }

    // MARK: - Clocks

    /// 10 Hz: the classic oneko tick, plus windows, naps and fetch.
    private func tick() {
        if let tb = touchBar {   // Touch Bar mode: no desktop work at all
            tb.tick10(cursor: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame),
                      speed: max(4, CGFloat(settings.speed.rawValue) * 0.6), naps: settings.naps,
                      paused: settings.paused)
            startPhysicsIfNeeded()
            return
        }
        tickCount += 1
        let fresh = deepSleep || NSEvent.pressedMouseButtons & 1 != 0 || play.needsWindowTracking || tickCount % 10 == 0
        if fresh && !juggling {
            refreshWindows()
        } else {
            world = WorldReader.read(reusingWindowsOf: world)
            world.drawings = toolbox?.drawings ?? []
        }
        updateDeepSleep()
        if tickCount % 10 == 0 { updateReactions() }
        play.laser = laserOn
        play.tick10(world: world)
        handleEvents()
        tickExtras()
        // Just dozed off (classic idle sleep, a nap spot, the box, staying): a sleepy sigh.
        let asleep = play.cat.sprite == .sleeping
        if asleep && !wasAsleep && !deepSleep { sounds.play(.sleep) }
        wasAsleep = asleep
        toolbox?.tick(now: CACurrentMediaTime())
        if tickCount % 50 == 0 { savePositions() }
        if tickCount % 10 == 0, settingsWindow?.isVisible == true { settingsWindow?.refresh() }
        startPhysicsIfNeeded()
        render()
        updateClickThrough()
    }

    private var lastWindowRead = CACurrentMediaTime()
    private var physicsFrame = 0

    /// Mouse held while something is airborne or sitting on a window: track windows 30×/s
    /// so you can launch, bat and catch the cat with them.
    private var juggling: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && play.needsWindowTracking
    }

    private func refreshWindows() {
        world = WorldReader.read()
        world.drawings = toolbox?.drawings ?? []
        let now = CACurrentMediaTime()
        play.updateWindows(world, dt: CGFloat(min(0.25, now - lastWindowRead)))
        for e in extras { e.play.updateWindows(world, dt: CGFloat(min(0.25, now - lastWindowRead))) }
        lastWindowRead = now
    }

    /// 60 Hz, only while something is being thrown, carried, falling or juggled.
    private func startPhysicsIfNeeded() {
        let needed = touchBar.map { $0.needsPhysics }
            ?? (play.needsPhysics || juggling || extras.contains { $0.play.needsPhysics })
        guard physicsTimer == nil, needed else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.physicsStep() }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        physicsTimer = t
    }

    private static let debug = ProcessInfo.processInfo.environment["ONEKO_DEBUG"] != nil

    private func physicsStep() {
        if Self.debug, physicsFrame % 60 == 0 {
            let line = "physics: [\(play.physicsReason)] \(juggling ? "juggling" : "") \(extras.map { $0.play.physicsReason })\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if let tb = touchBar {
            tb.physics(dt: 1.0 / 60)
            if !tb.needsPhysics {
                physicsTimer?.invalidate()
                physicsTimer = nil
            }
            return
        }
        physicsFrame += 1
        if juggling && physicsFrame % 2 == 0 { refreshWindows() }
        world.cursor = NSEvent.mouseLocation
        world.drawings = toolbox?.drawings ?? []
        play.physics(dt: 1.0 / 60, world: world)
        for (i, e) in extras.enumerated() {
            var w = world
            w.cursor = target(of: i)
            e.play.physics(dt: 1.0 / 60, world: w)
        }
        handleEvents()
        render()
        if !play.needsPhysics && !juggling && !extras.contains(where: { $0.play.needsPhysics }) {
            physicsTimer?.invalidate()
            physicsTimer = nil
        }
    }

    private func handleEvents() {
        for e in play.drainEvents() { react(to: e, window: catWindow, primary: true) }
        for x in extras {
            for e in x.play.drainEvents() { react(to: e, window: x.window, primary: false) }
        }
    }

    /// Hearts, sounds and stats for whatever just happened.
    private func react(to e: PlaygroundEvent, window: CatWindow?, primary: Bool) {
        switch e {
        case .heart:
            window?.popHeart()
            sounds.play(.purr)
            stats.bump(.pets)
        case .thrown(let speed):
            if speed > 600 { stats.bump(.yeets) }
            if speed > 1500 { sounds.play(.mrrp) }
        case .apex(let h):
            stats.record(.highestYeet, max: Int(h))
        case .landed(let impact, let win, let at):
            if impact > 900 { sounds.play(.thud) }
            if primary { maybeDropIntoTouchBar(impact: impact, onWindow: win, at: at) }
        case .fetched: stats.bump(.fetches)
        case .bonked: stats.bump(.windowBonks); sounds.play(.mrrp)
        case .dockYeet: stats.bump(.dockYeets); sounds.play(.meow)
        case .boxHop: stats.bump(.boxNaps); sounds.play(.mrrp)
        case .batYarn: stats.bump(.yarnBats)
        case .woke: sounds.play(.meow)
        default: break
        }
    }

    // MARK: - Drawing

    private func render() {
        guard touchBar == nil else { return }   // the desktop cat is away on the Touch Bar
        let pose = play.catPose
        catWindow.render(pose, image: sprites.image(for: pose.sprite, frame: pose.frame), hatAnchor: hatAnchor(pose, sprites))
        for x in extras {
            let p = x.play.catPose
            x.window.render(p, image: x.sprites.image(for: p.sprite, frame: p.frame), hatAnchor: hatAnchor(p, x.sprites))
        }
        if play.yarn.isOut {
            yarnWindow.setClipped(play.yarn.state == .pinned)
            yarnWindow.render(play.yarn.body)
        }
        if laserOn { laserWindow.place(NSEvent.mouseLocation) }
        if play.bone.isOut {
            boneWindow.setClipped(play.bone.state == .pinned)
            boneWindow.render(play.bone.body)
        }
        if play.box.isOut {
            boxWindow.setArt(play.boxClosed ? PixelArt.boxClosed : PixelArt.box)
            boxWindow.setClipped(play.box.state == .pinned)
            boxWindow.render(play.box.body)
        }
        updateVisibility(pose)
    }

    private func updateVisibility(_ pose: CatPose) {
        let covered = settings.hideInFullScreen ? world.fullScreenDisplays : []
        func hiddenAt(_ p: CGPoint) -> Bool { covered.contains { $0.contains(p) } }

        let wantBox = play.box.isOut && !pose.inBox && !hiddenAt(play.box.body.pos)
        let wantBone = play.bone.isOut && !hiddenAt(play.bone.body.pos)
        let wantYarn = play.yarn.isOut && !hiddenAt(play.yarn.body.pos)
        let wantCat = !noCat && (!hiddenAt(pose.center) || dragging == .cat)
        var order: [(NSWindow, Bool)] = [(boxWindow, wantBox), (boneWindow, wantBone), (yarnWindow, wantYarn)]
        for (i, x) in extras.enumerated() { order.append((x.window, !hiddenAt(x.play.cat.position) || draggingExtra == i)) }
        order.append((catWindow, wantCat))
        order.append((laserWindow, laserOn))
        var restack = false
        for (w, want) in order {
            if want && !w.isVisible { restack = true } else if !want && w.isVisible { w.orderOut(nil) }
        }
        if restack {   // toys at the back, then the extra cats, the first cat, the laser dot
            for (w, want) in order where want { w.orderFrontRegardless() }
        }
    }

    // MARK: - Mouse

    private func wireMouse() {
        let pairs: [(OverlayPanel, Thing)] = [(catWindow, .cat), (boneWindow, .bone), (boxWindow, .box), (yarnWindow, .yarn)]
        for (window, thing) in pairs {
            window.mouseView.onDown = { [weak self] p, t in
                guard let self else { return }
                // A cat shut in a box: grabbing it grabs the box (with the cat inside).
                let target: Thing = thing == .cat && play.inBox && play.boxClosed ? .box : thing
                dragging = target
                play.mouseDown(on: target, at: p, time: t)
            }
            window.mouseView.onRightClick = { [weak self] in
                guard let self else { return }
                play.rightClick(thing)
                if !play.isDragging { dragging = nil }
                startPhysicsIfNeeded()
                render()
                updateClickThrough()
            }
            window.mouseView.onDrag = { [weak self] p, t in
                guard let self else { return }
                play.mouseDragged(to: p, time: t)
                startPhysicsIfNeeded()
                render()
            }
            window.mouseView.onUp = { [weak self] p, t, clicks in
                guard let self else { return }
                play.mouseUp(at: p, time: t, clickCount: clicks)
                dragging = nil
                handleEvents()
                startPhysicsIfNeeded()
                render()
                updateClickThrough()
            }
        }
        if !deepSleep { installMouseMonitors() }
    }

    /// Keeps click-through exact as the pointer moves. Removed in deep sleep, so mouse
    /// movement in a full-screen game doesn't wake the app at all.
    private func installMouseMonitors() {
        guard monitors.isEmpty else { return }
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            self?.updateClickThrough()
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
            self?.updateClickThrough()
            return e
        }) { monitors.append(l) }
    }

    private func removeMouseMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    /// Only the painted pixels of the cat and its toys catch clicks; everything else falls
    /// through to the app underneath.
    private func updateClickThrough() {
        guard dragging == nil, draggingExtra == nil, !deepSleep else { hideHint(); return }
        if laserOn { laserWindow.place(NSEvent.mouseLocation) }
        let all: [NSWindow] = [catWindow, boneWindow, boxWindow, yarnWindow] + extras.map(\.window)
        if let t = toolbox, t.tool != .pointer {   // a Paint tool is active: the canvas gets every click
            for w in all where !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
            hideHint()
            return
        }
        let p = NSEvent.mouseLocation
        let hit = thing(at: p)
        let hitExtra = hit == nil ? extras.firstIndex { catHit(p, $0.play.catPose, $0.sprites, $0.play.catScale, $0.window) } : nil
        for (w, t) in [(catWindow as NSWindow, Thing.cat), (boneWindow, .bone), (boxWindow, .box), (yarnWindow, .yarn)] {
            let ignore = hit != t
            if w.ignoresMouseEvents != ignore { w.ignoresMouseEvents = ignore }   // each set is a WindowServer call
        }
        for (i, x) in extras.enumerated() {
            let ignore = hitExtra != i
            if x.window.ignoresMouseEvents != ignore { x.window.ignoresMouseEvents = ignore }
        }
        // Hovering over a sleeping cat: tell people how to wake it.
        var sleeper: (CGPoint, CGFloat)?
        if hit == .cat, play.isSleeping { sleeper = (play.catPose.center, play.catScale) }
        if let i = hitExtra, extras[i].play.isSleeping { sleeper = (extras[i].play.catPose.center, extras[i].play.catScale) }
        if let (c, s) = sleeper {
            let now = CACurrentMediaTime()
            if hoverSince == nil { hoverSince = now }
            if now - hoverSince! > 0.4 { hintWindow.show(above: CGPoint(x: c.x, y: c.y + 14 * s)) }
        } else {
            hideHint()
        }
    }

    private func hideHint() {
        hoverSince = nil
        if hintWindow.isVisible { hintWindow.orderOut(nil) }
    }

    private func catHit(_ p: CGPoint, _ pose: CatPose, _ sheet: SpriteSheet, _ s: CGFloat, _ w: NSWindow) -> Bool {
        guard abs(p.x - pose.center.x) < 17 * s, abs(p.y - pose.center.y) < 17 * s, w.isVisible else { return false }
        let x = Int(((p.x - pose.center.x) / s + 16).rounded(.down))
        let y = Int(((pose.center.y - p.y) / s + 16).rounded(.down))
        return sheet.isOpaque(pose.sprite, frame: pose.frame, x: x, y: y)
            || (pose.inBox && (pose.boxClosed ? PixelArt.boxClosed : PixelArt.box).isOpaque(x: x, y: y))
    }

    private func thing(at p: CGPoint) -> Thing? {
        if !noCat, catHit(p, play.catPose, sprites, play.catScale, catWindow) { return .cat }
        if yarnWindow.isVisible, yarnWindow.hit(p, center: play.yarn.body.pos, slop: 2) { return .yarn }
        if boneWindow.isVisible, boneWindow.hit(p, center: play.bone.body.pos, slop: 2) { return .bone }
        if boxWindow.isVisible, boxWindow.hit(p, center: play.box.body.pos) { return .box }
        return nil
    }

    // MARK: - Settings

    private func sheetForCurrentSkin() -> SpriteSheet {
        if settings.skin == Skin.customID, let path = settings.customSheetPath,
           let custom = SpriteSheet.load(url: URL(fileURLWithPath: path)) {
            return custom
        }
        if settings.skin == Skin.paintedID { return classic.recolored(settings.paintedSkin) }
        let skin = Skin.all.first { $0.id == settings.skin } ?? Skin.all[0]
        return classic.recolored(skin)
    }

    func applySettings() {
        let scale = settings.size.rawValue
        if play.scale != CGFloat(scale) {
            shrinkWork?.cancel()
            play.setCatSize(1)
            play.setScale(scale)
            catWindow.setScale(scale)
            boneWindow.setScale(scale)
            boxWindow.setScale(scale)
            yarnWindow.setScale(scale)
            for x in extras { x.play.setScale(scale); x.window.setScale(scale) }
        }
        let night = settings.reacts && play.sleepy
        play.cat.speed = CGFloat(settings.speed.rawValue) * (night ? 0.75 : 1)
        play.cat.sleepEnabled = settings.naps
        play.spotWindows = settings.naps && settings.spotWindows
        play.spotMenuBar = settings.naps && settings.spotMenuBar
        play.spotDock = settings.naps && settings.spotDock
        play.cat.position = play.cat.clamp(play.cat.position, cursor: NSEvent.mouseLocation,
                                           screens: NSScreen.screens.map(\.frame))

        let wasPaused = play.paused
        let allPaused = settings.paused || deepSleep || away || (reduceMotion && !settings.ignoreReduceMotion)
        play.paused = allPaused || noCat
        if wasPaused && !play.paused { play.cat.wakeUp() }
        for (i, x) in extras.enumerated() {
            x.play.cat.speed = play.cat.speed * (1 + 0.08 * CGFloat(i % 8 + 1))   // a little personality
            x.play.cat.sleepEnabled = settings.naps
            x.play.paused = allPaused
            x.play.gravityMode = play.gravityMode
            x.play.sleepy = play.sleepy
        }
        crowd?.paused = allPaused
        crowd?.speed = play.cat.speed
        crowd?.scale = CGFloat(scale)
        crowd?.hideInFullScreen = settings.hideInFullScreen
        statusItem?.button?.appearsDisabled = allPaused
        render()
    }

    private func startPosition() -> CGPoint {
        if let saved = settings.lastPosition, world.screen(containing: saved) != nil { return saved }
        let main = NSScreen.main?.frame ?? .zero   // first launch: top-left, like oneko.js
        return CGPoint(x: main.minX + 32, y: main.maxY - 32)
    }

    private func restoreToys() {
        if settings.boxOut {
            if let p = settings.boxPosition, world.screen(containing: p) != nil {
                play.placeBox(at: p, falling: false)
            } else {
                play.placeBox(at: dropPoint(offset: 120), falling: true)
            }
        }
        if settings.boneOut {
            if let p = settings.bonePosition, world.screen(containing: p) != nil {
                play.placeBone(at: p, falling: false)
            } else {
                play.placeBone(at: dropPoint(offset: -80), falling: true)
            }
        }
        if settings.yarnOut { play.placeYarn(at: dropPoint(offset: 60), falling: true) }
        startPhysicsIfNeeded()
    }

    /// Next to the cursor; new toys fall from here.
    private func dropPoint(offset: CGFloat) -> CGPoint {
        let c = NSEvent.mouseLocation
        let p = CGPoint(x: c.x + offset, y: c.y)
        return world.screen(containing: p) != nil ? p : c
    }

    private func savePositions() {
        settings.lastPosition = play.cat.position
        if play.box.isResting || play.box.state == .pinned { settings.boxPosition = play.box.body.pos }
        if play.bone.isResting || play.bone.state == .pinned { settings.bonePosition = play.bone.body.pos }
    }

    /// Where Neko lives: on the desktop, or only on the Touch Bar (never both).
    func setHome(touchBar onBar: Bool) {
        settings.touchBarCat = onBar
        physicsTimer?.invalidate()
        physicsTimer = nil
        if onBar {
            guard TouchBarCat.isSupported else { settings.touchBarCat = false; return }
            if toolbox != nil { toggleToolbox() }      // the toolbox is a desktop thing
            savePositions()
            removeMouseMonitors()
            for w in [catWindow as NSWindow, boneWindow, boxWindow, yarnWindow, laserWindow, hintWindow] + extras.map(\.window) {
                w.orderOut(nil)
            }
            crowd?.setVisible(false)
            let tb = touchBar ?? TouchBarCat(sprites: sprites, icon: classic.menuBarIcon())
            tb.setCats(min(settings.catCount, TouchBarCat.maxCats), sheets: (0..<TouchBarCat.maxCats).map(extraSheet),
                       behavior: settings.catBehavior)
            tb.onNeedsPhysics = { [weak self] in self?.startPhysicsIfNeeded() }
            tb.onYeetToDesktop = { [weak self] along, v in self?.yeetFromTouchBar(along: along, velocity: v) }
            tb.onEvent = { [weak self] e in self?.react(to: e, window: nil, primary: false) }
            tb.flickToDesktop = settings.flickToDesktop
            touchBar = tb
            tb.install()
            tb.show()
            settings.boxOut = true          // the box always lives on the Touch Bar
            tb.setBox(true)
            tb.setBone(settings.boneOut)
            setLogicRate(0.1)
        } else {
            touchBar?.uninstall()
            touchBar = nil
            // Bring the desktop toys in line with what you chose while it was away.
            if settings.boxOut && play.box.state == .hidden { play.placeBox(at: dropPoint(offset: 120), falling: true) }
            if !settings.boxOut && play.box.state != .hidden { play.removeBox() }
            if settings.boneOut && play.bone.state == .hidden { play.placeBone(at: dropPoint(offset: -80), falling: true) }
            if !settings.boneOut && play.bone.state != .hidden { play.removeBone() }
            if !deepSleep { installMouseMonitors() }
            if !noCat { catWindow.orderFrontRegardless() }
            crowd?.setVisible(true)
            render()
            startPhysicsIfNeeded()
        }
    }

    // MARK: - System

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        // Going in or out of a full-screen app: check right away instead of at the next slow tick.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshWindows()
                self?.updateDeepSleep()
            }
        }
        nc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            applySettings()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()   // re-clamp onto a display that still exists
            self?.toolbox?.rebuildCanvases()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = classic.menuBarIcon()
        statusItem.button?.toolTip = "Oneko"
        statusItem.button?.appearsDisabled = play.paused
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Rebuilt every time it opens, so checkmarks always match the current state. Only the
    /// quick things live here; everything else is in Settings (⌘,).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func note(_ text: String) {
            let n = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
        if deepSleep { note("Asleep: a full-screen app is in front") }
        if away { note("Napping while you're away") }
        if reduceMotion && !settings.ignoreReduceMotion { note("Napping: Reduce Motion is on") }
        if menu.items.count > 0 { menu.addItem(.separator()) }

        menu.addItem(item(settings.paused ? "Resume" : "Pause", #selector(togglePause), key: "p"))
        menu.addItem(.separator())

        let toys = NSMenu()
        toys.addItem(item("Cardboard Box", #selector(toggleBox), checked: touchBar?.hasBox ?? (play.box.state != .hidden)))
        toys.addItem(item("Bone", #selector(toggleBone), checked: touchBar?.hasBone ?? (play.bone.state != .hidden)))
        toys.addItem(item("Ball of Yarn", #selector(toggleYarn), checked: play.yarn.state != .hidden, enabled: touchBar == nil))
        toys.addItem(item("Laser Pointer", #selector(toggleLaser), checked: laserOn, enabled: touchBar == nil))
        toys.addItem(.separator())
        toys.addItem(item("Give Catnip", #selector(giveCatnip), enabled: touchBar == nil))
        menu.addItem(submenu("Toys", toys))
        menu.addItem(item("Toolbox (Paint tools)", #selector(toggleToolbox), checked: toolbox != nil,
                          enabled: touchBar == nil))
        if TouchBarCat.isSupported {
            let home = NSMenu()
            home.addItem(item("Desktop", #selector(liveOnDesktop), checked: touchBar == nil))
            home.addItem(item("Touch Bar", #selector(liveOnTouchBar), checked: touchBar != nil))
            menu.addItem(submenu("Neko Lives On", home))
        }
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("How to Play…", #selector(showWelcome)))
        menu.addItem(item("About Oneko", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Quit Oneko", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private var settingsWindow: SettingsWindow?

    @objc func showSettings() {
        let w = settingsWindow ?? SettingsWindow(app: self)
        settingsWindow = w
        w.present()
    }

    private func item(_ title: String, _ action: Selector, key: String = "", checked: Bool = false,
                      tag: Int = 0, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = checked ? .on : .off
        i.tag = tag
        i.isEnabled = enabled
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    // MARK: - Actions

    @objc func togglePause() { settings.paused.toggle(); applySettings() }
    @objc func toggleNaps() { settings.naps.toggle(); applySettings() }
    @objc func toggleSpotWindows() { settings.spotWindows.toggle(); applySettings() }
    @objc func toggleSpotMenuBar() { settings.spotMenuBar.toggle(); applySettings() }
    @objc func toggleSpotDock() { settings.spotDock.toggle(); applySettings() }
    @objc func toggleIgnoreReduceMotion() { settings.ignoreReduceMotion.toggle(); applySettings() }
    @objc func toggleHideInFullScreen() { settings.hideInFullScreen.toggle(); render() }

    @objc func chooseCustomSheet() {
        let panel = NSOpenPanel()
        panel.title = "Choose a 256×128 sprite sheet (8×4 frames of 32×32, oneko layout)"
        panel.allowedContentTypes = [.png, .gif]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SpriteSheet.load(url: url) != nil else {
            let alert = NSAlert()
            alert.messageText = "That image can't be used"
            alert.informativeText = "Custom coats must be exactly 256×128 pixels: 8 columns × 4 rows of 32×32 frames, in the classic oneko layout."
            alert.runModal()
            return
        }
        settings.customSheetPath = url.path
        settings.skin = Skin.customID
        reloadSprites()
    }

    func reloadSprites() {
        sprites = sheetForCurrentSkin()
        if let c = paintedColor {
            sprites = classic.recolored(Skin(id: "paint", title: "Paint", outline: RGBA(r: 0, g: 0, b: 0), fill: c))
        }
        touchBar?.sprites = sprites
        touchBar?.setSheets((0..<TouchBarCat.maxCats).map(extraSheet))
        for (i, x) in extras.enumerated() { x.sprites = extraSheet(i) }
        crowd?.setCoats(crowdSheets())
        render()
    }

    @objc func toggleBox() {
        if let tb = touchBar {
            settings.boxOut = !tb.hasBox
            tb.setBox(settings.boxOut)
            return
        }
        if play.box.state == .hidden {
            play.placeBox(at: dropPoint(offset: 120), falling: true)
            settings.boxOut = true
        } else {
            play.removeBox()
            settings.boxOut = false
        }
        startPhysicsIfNeeded()
        render()
    }

    @objc func toggleBone() {
        if let tb = touchBar {
            settings.boneOut = !tb.hasBone
            tb.setBone(settings.boneOut)
            return
        }
        if play.bone.state == .hidden {
            play.placeBone(at: dropPoint(offset: -80), falling: true)
            settings.boneOut = true
        } else {
            play.removeBone()
            settings.boneOut = false
        }
        startPhysicsIfNeeded()
        render()
    }

    /// Flicked hard off the Touch Bar: Neko moves to the desktop, flying up out of the bottom
    /// of the built-in display (right above the Touch Bar). `v` is already scaled.
    private func yeetFromTouchBar(along: CGFloat, velocity v: CGVector) {
        setHome(touchBar: false)
        stats.bump(.touchBarTrips)
        sounds.play(.meow)
        let screen = builtInScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame, vis = screen.visibleFrame
        let start = CGPoint(x: f.minX + along * f.width, y: vis.minY + 20)
        world = WorldReader.read()
        withPlay { $0.launch(at: start, velocity: v) }
        catWindow.orderFrontRegardless()
    }

    @objc func liveOnDesktop() { setHome(touchBar: false) }
    @objc func toggleSlamToTouchBar() { settings.slamToTouchBar.toggle() }
    @objc func toggleFlickToDesktop() {
        settings.flickToDesktop.toggle()
        touchBar?.flickToDesktop = settings.flickToDesktop
    }
    @objc func liveOnTouchBar() { setHome(touchBar: true) }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
                + "\n\nTip: move Oneko.app to your Applications folder first."
            alert.runModal()
        }
    }

    private var aboutWindow: AboutWindow?
    private var welcomeWindow: WelcomeWindow?

    @objc func showWelcome() {
        let w = welcomeWindow ?? WelcomeWindow(icon: classic.image(for: .idle, frame: 0))
        welcomeWindow = w
        w.present()
    }

    @objc func showAbout() {
        let w = aboutWindow ?? AboutWindow(icon: classic.image(for: .idle, frame: 0))
        aboutWindow = w
        w.present()
    }

    // MARK: - Low-power sleep

    /// A full-screen app (Space, video, game) is in front where the cat or cursor is: the cat
    /// curls up, and the app drops to one quiet tick a second until you leave it.
    private(set) var deepSleep = ProcessInfo.processInfo.arguments.contains("--force-deep-sleep")

    private func updateDeepSleep() {
        if ProcessInfo.processInfo.arguments.contains("--force-deep-sleep") { return }   // for measuring
        let full = world.fullScreenDisplays
        let asleep = full.contains { $0.contains(world.cursor) || $0.contains(play.cat.position) }
        guard asleep != deepSleep else { return }
        deepSleep = asleep
        applySettings()                 // pauses the cat (it naps in place)
        setLogicRate(asleep ? 1.0 : 0.1)
        if asleep {
            physicsTimer?.invalidate()
            physicsTimer = nil
            removeMouseMonitors()
        } else {
            installMouseMonitors()
        }
    }

    /// The main clock: 10 Hz normally, 1 Hz in deep sleep. Tolerance lets macOS coalesce
    /// wake-ups with other timers, which saves energy.
    private func setLogicRate(_ interval: TimeInterval) {
        if let t = logicTimer, t.timeInterval == interval { return }
        logicTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)   // keep running while menus are open
        logicTimer = t
    }

    // MARK: - More cats

    /// No cats at all (count 0): just the toys.
    private var noCat: Bool { settings.catCount == 0 }

    /// Real cats (the first one has the toys), and in crowd mode the rest as a GPU-drawn
    /// crowd. Real cats arrive in batches of 100 a tick, so even thousands never freeze
    /// the Mac while they spawn.
    func setCatCount(_ n: Int) {
        wantExtras = max(0, settings.realCatCount - 1)
        while extras.count > wantExtras {
            let x = extras.removeLast()
            x.window.orderOut(nil)
        }
        growExtras()
        let crowdCount = settings.crowdCatCount
        if crowdCount > 0 {
            let c = crowd ?? CrowdController()
            crowd = c
            c.setCoats(crowdSheets())
            c.setCount(crowdCount, around: play.cat.position)
            c.setVisible(touchBar == nil)
        } else if let c = crowd {
            c.stop()
            crowd = nil
        }
        touchBar?.setCats(min(n, TouchBarCat.maxCats), sheets: (0..<TouchBarCat.maxCats).map(extraSheet),
                          behavior: settings.catBehavior)
        applySettings()
        updateVisibility(play.catPose)
    }

    /// Launching with thousands of real cats saved: ask before spawning them all.
    private func confirmSavedCats() {
        let n = settings.realCatCount
        guard n > 1000 else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spawn \(n.formatted()) real cats?"
        alert.informativeText = "Oneko was left with \(n.formatted()) real cats. Each one is its own little window with its own physics, which keeps your Mac busy. Crowd mode draws every cat past 50 on the graphics chip instead, which is much lighter."
        alert.addButton(withTitle: "Use Crowd Mode")
        alert.addButton(withTitle: "Spawn Them")
        alert.addButton(withTitle: "Just 1 Cat")
        switch alert.runModal() {
        case .alertFirstButtonReturn: settings.crowdMode = true
        case .alertThirdButtonReturn: settings.catCount = 1
        default: break
        }
    }

    /// How many extra real cats there should be (they may still be spawning).
    private var wantExtras = 0

    private func growExtras() {
        guard extras.count < wantExtras else { return }
        let scale = CGFloat(settings.size.rawValue)
        let until = min(wantExtras, extras.count + 100)
        while extras.count < until {
            let i = extras.count
            let o = Self.swarmOffset(i, scale: scale)
            let start = play.cat.clamp(CGPoint(x: play.cat.position.x + o.dx * swarmSquash, y: play.cat.position.y + o.dy * swarmSquash),
                                       cursor: play.cat.position, screens: world.screenFrames)
            var p = Playground(position: start)
            p.spotWindows = false; p.spotMenuBar = false; p.spotDock = false
            p.setScale(settings.size.rawValue)
            let x = ExtraCat(play: p, sprites: extraSheet(i))
            x.window.setScale(settings.size.rawValue)
            x.window.rig.setHat(currentHat())
            wire(extra: x, index: i)
            extras.append(x)
        }
        applySettings()
    }

    /// Behaviour changed: everyone starts over with the new rule.
    func catsChanged() {
        for x in extras { x.roam = nil }
        touchBar?.setCats(min(settings.catCount, TouchBarCat.maxCats), sheets: (0..<TouchBarCat.maxCats).map(extraSheet),
                          behavior: settings.catBehavior)
    }

    /// Where swarm cat `i` sits around your cursor: a sunflower, so nobody overlaps.
    static func swarmOffset(_ i: Int, scale: CGFloat) -> CGVector {
        let r = 30 * scale * CGFloat(Double(i + 1).squareRoot())
        let a = CGFloat(i + 1) * 2.399963
        return CGVector(dx: r * cos(a), dy: r * sin(a))
    }

    /// The coat extra cat `i` wears (cat 2 is `i` = 0). Sheets are shared between cats
    /// wearing the same coat, so thousands of cats don't mean thousands of sheets.
    func extraSheet(_ i: Int) -> SpriteSheet {
        switch settings.coatMode {
        case .same: return sprites
        case .rotate: return sheet(rotatingSkin(i))
        case .random: return sheet(Skin.random(seed: i % 64))
        case .custom:
            let id = settings.customCoats[safe: i] ?? ""
            if id == Skin.paintedID { return sheet(settings.paintedSkin) }
            if id == "random" { return sheet(Skin.random(seed: i % 64)) }
            if let skin = Skin.all.first(where: { $0.id == id }) { return sheet(skin) }
            return sheet(rotatingSkin(i))
        }
    }

    private var sheetCache: [String: SpriteSheet] = [:]

    private func sheet(_ skin: Skin) -> SpriteSheet {
        let key = skin.id == Skin.paintedID ? "painted-\(skin.fill.hex)\(skin.outline.hex)\((skin.accent ?? skin.fill).hex)\(skin.pattern.rawValue)" : skin.id
        if let s = sheetCache[key] { return s }
        let s = classic.recolored(skin)
        sheetCache[key] = s
        return s
    }

    /// Taking turns with the other coats.
    private func rotatingSkin(_ i: Int) -> Skin {
        let others = Skin.all.filter { $0.id != settings.skin && $0.id != "ghost" }
        return others[i % others.count]
    }

    /// The coats the crowd wears, as whole sheets.
    private func crowdSheets() -> [SpriteSheet] {
        switch settings.coatMode {
        case .same: return [sprites]
        case .random: return (0..<24).map { classic.recolored(Skin.random(seed: 1000 + $0)) }
        case .rotate, .custom:
            return Skin.all.filter { $0.id != settings.skin && $0.id != "ghost" }.map { classic.recolored($0) }
        }
    }

    /// What extra cat `i` runs after.
    private func target(of i: Int) -> CGPoint {
        switch settings.catBehavior {
        case .conga:
            return i == 0 ? play.cat.position : extras[i - 1].play.cat.position
        case .swarm:
            let o = Self.swarmOffset(i, scale: play.scale)
            return CGPoint(x: world.cursor.x + o.dx * swarmSquash, y: world.cursor.y + o.dy * swarmSquash)
        case .roam:
            return extras[i].roam ?? extras[i].play.cat.position
        }
    }

    /// Free roam: every now and then each cat picks somewhere new to wander to.
    private func updateRoaming() {
        guard settings.catBehavior == .roam, !world.screens.isEmpty else { return }
        for x in extras {
            let there = x.roam.map { hypot($0.x - x.play.cat.position.x, $0.y - x.play.cat.position.y) < x.play.cat.stopDistance + 4 } ?? true
            if x.roam == nil || (there && Int.random(in: 0..<120) == 0) || Int.random(in: 0..<900) == 0 {
                let s = world.screens[Int.random(in: 0..<world.screens.count)].visible.insetBy(dx: 40, dy: 40)
                guard s.width > 0, s.height > 0 else { continue }
                x.roam = CGPoint(x: CGFloat.random(in: s.minX...s.maxX), y: CGFloat.random(in: s.minY...s.maxY))
            }
        }
    }

    /// A big swarm is squeezed so it never gets much wider than all your displays together.
    private var swarmSquash: CGFloat {
        let natural = 30 * play.scale * CGFloat(Double(wantExtras + 1).squareRoot())
        let area = world.screens.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        return area > 0 ? min(1, (area / .pi).squareRoot() * 1.15 / natural) : 1
    }

    private func tickExtras() {
        growExtras()
        updateRoaming()
        for (i, x) in extras.enumerated() {
            var w = world
            w.cursor = target(of: i)
            x.play.tick10(world: w)
        }
        crowd?.behavior = settings.catBehavior
        crowd?.leader = extras.last?.play.cat.position ?? play.cat.position
        crowd?.tick(cursor: world.cursor, screens: world.screens,
                    covered: settings.hideInFullScreen ? world.fullScreenDisplays : [])
    }

    private func wire(extra x: ExtraCat, index i: Int) {
        let v = x.window.mouseView
        v.onDown = { [weak self, weak x] p, t in
            guard let self, let x else { return }
            draggingExtra = extras.firstIndex { $0 === x }
            x.play.mouseDown(on: .cat, at: p, time: t)
        }
        v.onDrag = { [weak self, weak x] p, t in
            x?.play.mouseDragged(to: p, time: t)
            self?.startPhysicsIfNeeded()
            self?.render()
        }
        v.onUp = { [weak self, weak x] p, t, clicks in
            guard let self, let x else { return }
            x.play.mouseUp(at: p, time: t, clickCount: clicks)
            draggingExtra = nil
            handleEvents()
            startPhysicsIfNeeded()
            render()
            updateClickThrough()
        }
        v.onRightClick = { [weak self, weak x] in
            guard let self, let x else { return }
            x.play.rightClick(.cat)
            if !x.play.isDragging { draggingExtra = nil }
            startPhysicsIfNeeded()
            render()
        }
    }

    // MARK: - Toys: yarn, laser, catnip

    @objc func toggleYarn() {
        if play.yarn.state == .hidden {
            play.placeYarn(at: dropPoint(offset: 60), falling: true)
            settings.yarnOut = true
        } else {
            play.removeYarn()
            settings.yarnOut = false
        }
        startPhysicsIfNeeded()
        render()
    }

    @objc func toggleLaser() {
        laserOn.toggle()
        play.laser = laserOn
        if laserOn { laserWindow.place(NSEvent.mouseLocation) }
        render()
    }

    @objc func giveCatnip() {
        withPlay { $0.giveCatnip() }
        for x in extras { x.play.giveCatnip() }
        handleEvents()
    }

    // MARK: - Coats and hats

    @objc func paintCoat() {
        let painter = CoatPainter(base: classic, start: settings.paintedSkin)
        painter.onApply = { [weak self] skin in
            guard let self else { return }
            settings.paintedSkin = skin
            settings.skin = Skin.paintedID
            reloadSprites()
        }
        coatPainter = painter
        painter.present()
    }

    /// The hat for today: chosen, or (Seasonal) a witch hat in late October, a Santa hat in
    /// December, a party hat around New Year.
    private func currentHat() -> Art? {
        switch settings.hat {
        case "santa": return PixelArt.santaHat
        case "witch": return PixelArt.witchHat
        case "party": return PixelArt.partyHat
        case "none": return nil
        default:
            let c = Calendar.current.dateComponents([.month, .day], from: Date())
            switch (c.month ?? 0, c.day ?? 0) {
            case (10, 15...31): return PixelArt.witchHat
            case (12, 31), (1, 1...2): return PixelArt.partyHat
            case (12, _): return PixelArt.santaHat
            default: return nil
            }
        }
    }

    func applyHat() {
        let hat = currentHat()
        catWindow.rig.setHat(hat)
        for x in extras { x.window.rig.setHat(hat) }
        render()
    }

    private func hatAnchor(_ pose: CatPose, _ sheet: SpriteSheet) -> CGPoint? {
        catWindow.rig.hasHat ? sheet.headAnchor(pose.sprite, frame: pose.frame) : nil
    }


    // MARK: - Sounds, stats, reacting to your Mac

    @objc func toggleSound() {
        settings.sound.toggle()
        sounds.enabled = settings.sound
        if settings.sound { sounds.play(.meow) }
    }

    @objc func toggleReacts() {
        settings.reacts.toggle()
        updateReactions()
    }

    /// Once a second: are you away (no input for 2 minutes)? Is it late at night?
    func updateReactions() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        let nowAway = settings.reacts && idle > 120
        let hour = Calendar.current.component(.hour, from: Date())
        let night = settings.reacts && (hour >= 23 || hour < 6)
        if night != play.sleepy {                         // late night: a bit slower, more naps
            play.sleepy = night
            applySettings()
        }
        guard nowAway != away else { return }
        away = nowAway
        applySettings()                                   // away: everyone naps in place
        if !away {                                        // you're back: big stretch
            play.stretchAwake()
            for x in extras { x.play.stretchAwake() }
            handleEvents()
        }
    }

    // MARK: - Dropping into the Touch Bar

    private var builtInScreen: NSScreen? {
        NSScreen.screens.first {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// Throw it down hard onto the floor of the MacBook's own screen and it falls through
    /// into the Touch Bar below. Only on Macs with a Touch Bar.
    static let touchBarDropImpact: CGFloat = 1800      // speed when it hits the floor (pt/s)
    static let touchBarDropThrow: CGFloat = 900        // and it must have been thrown downward

    static func slamsIntoTouchBar(impact: CGFloat, thrown: CGVector) -> Bool {
        impact >= touchBarDropImpact && thrown.dy <= -touchBarDropThrow
    }

    private var droppingIntoTouchBar = false

    private func maybeDropIntoTouchBar(impact: CGFloat, onWindow: Int?, at p: CGPoint) {
        guard settings.slamToTouchBar, TouchBarCat.isSupported, touchBar == nil, !droppingIntoTouchBar, onWindow == nil,
              Self.slamsIntoTouchBar(impact: impact, thrown: play.lastThrow),
              let screen = builtInScreen, p.x >= screen.frame.minX, p.x <= screen.frame.maxX,
              p.y >= screen.frame.minY, p.y <= screen.frame.minY + screen.frame.height / 2
        else { return }
        droppingIntoTouchBar = true
        let along = (p.x - screen.frame.minX) / screen.frame.width
        stats.bump(.touchBarTrips)
        sounds.play(.mrrp)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            droppingIntoTouchBar = false
            setHome(touchBar: true)
            touchBar?.arrive(along: along)
        }
    }

    // MARK: - Toolbox

    @objc func toggleToolbox() {
        if let t = toolbox {
            t.hide()
            toolbox = nil
            withPlay { $0.releaseCaptured(); $0.gravityMode = false }
            magnifyCat(false)
            paintedColor = nil
            reloadSprites()
        } else {
            let t = ToolboxController(host: self)
            toolbox = t
            t.show()
            withPlay { $0.gravityMode = true }   // Neko now falls, and walks on what you draw
            // Drawings sit under the cat and its toys.
            for w in [boxWindow as NSWindow, boneWindow, catWindow] where w.isVisible { w.orderFrontRegardless() }
            t.toolbar.orderFrontRegardless()
        }
        updateClickThrough()
    }
}

extension AppDelegate: ToolboxHost {
    var catPlay: Playground { play }

    var catFillColor: RGBA {
        paintedColor ?? (Skin.all.first { $0.id == settings.skin }?.fill ?? RGBA(r: 255, g: 255, b: 255))
    }

    func paintCat(_ c: RGBA) {
        paintedColor = c
        reloadSprites()
    }

    /// Magnifier: huge for 10 seconds (3× the normal size at 1×, 2× otherwise).
    func magnifyCat(_ giant: Bool) {
        shrinkWork?.cancel()
        let base = settings.size.rawValue
        let k: CGFloat = giant ? (base == 1 ? 3 : 2) : 1
        guard play.catSize != k else { return }
        play.setCatSize(k)
        catWindow.setScale(Int(CGFloat(base) * k))
        if giant {
            let work = DispatchWorkItem { [weak self] in self?.magnifyCat(false) }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }
        handleEvents()
        render()
    }

    func withPlay(_ f: (inout Playground) -> Void) {
        f(&play)
        handleEvents()
        startPhysicsIfNeeded()
        render()
    }

    func toolboxToolChanged() {
        updateClickThrough()
    }
}

/// One of the extra cats: its own playground, window and coat.
final class ExtraCat {
    var play: Playground
    let window = CatWindow()
    var sprites: SpriteSheet
    /// Free roam: where it's wandering to.
    var roam: CGPoint?

    init(play: Playground, sprites: SpriteSheet) {
        self.play = play
        self.sprites = sprites
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
