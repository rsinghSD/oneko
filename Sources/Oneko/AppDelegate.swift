import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let classic: SpriteSheet
    private var sprites: SpriteSheet
    let settings = Settings()
    private(set) var play = Playground(position: .zero)
    private let catWindow = CatWindow()
    /// One window per bone and per ball of yarn (up to 50 each).
    private var boneWindows: [PropWindow] = []
    private var yarnWindows: [PropWindow] = []
    private var bowlWindows: [PropWindow] = []
    /// The front of a big box (box 0), drawn in front of the cats in it.
    private var bigFront: PropWindow?
    /// Pairs of cats playing together (nil = the first cat, else an extra cat's index).
    private var playPairs: [(Int?, Int?)] = []
    /// Every cardboard box, shared by all the cats.
    private let toys = ToyPile()
    /// One window per real box (up to 50).
    private var boxWindows: [PropWindow] = []
    /// Boxes past 50: a GPU-drawn heap.
    private var heap: BoxHeap?
    private let laserWindow = OverlayPanel()
    private let laserDot = OverlayPanel.pixelLayer()
    private(set) var laserOn = false
    let sounds = SoundBox()
    let stats = Stats()
    let catStats = CatStats()
    private(set) lazy var updates = UpdateChecker(settings: settings)
    /// Rain, thunder, sun or snow (your real weather), snow or leaves (by the season), or as you chose.
    private var season: SeasonOverlay?
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
        play.toys = toys
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
        let version = WhatsNewWindow.currentVersion
        if !settings.seenWelcome {
            settings.seenWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWelcome() }
        } else if settings.shouldShowWhatsNew(current: version) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWhatsNew() }
        }
        settings.lastSeenVersion = version
        // A while after launch, so it never slows startup down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.updates.checkIfDue() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePositions()
        catStats.save()
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
        updatePlay()
        play.tick10(world: world)
        handleEvents()
        tickExtras()
        // Just dozed off (classic idle sleep, a nap spot, the box, staying): a sleepy sigh.
        let asleep = play.cat.sprite == .sleeping
        if asleep && !wasAsleep && !deepSleep { sounds.play(.sleep) }
        wasAsleep = asleep
        toolbox?.tick(now: CACurrentMediaTime())
        heap?.setCovered(settings.hideInFullScreen ? world.fullScreenDisplays : [])
        if tickCount % 50 == 0 { savePositions(); catStats.save() }
        if tickCount % 10 == 0 { updateSeason() }
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
        let dt = CGFloat(min(0.25, now - lastWindowRead))
        play.updateWindows(world, dt: dt)
        for e in extras { e.play.updateWindows(world, dt: dt) }
        lastWindowRead = now
    }

    /// 60 Hz, only while something is being thrown, carried, falling or juggled.
    private func startPhysicsIfNeeded() {
        let needed = touchBar.map { $0.needsPhysics }
            ?? (play.needsPhysics || juggling || extras.contains { $0.needsPhysics })
        guard physicsTimer == nil, needed else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.physicsStep() }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        physicsTimer = t
    }

    private static let debug = ProcessInfo.processInfo.environment["ONEKO_DEBUG"] != nil

    /// ONEKO_DEBUG: what the window work costs (WindowServer calls included, which the
    /// headless bench can't see), printed every 10 s.
    private struct WindowTiming {
        var render = 0.0, visibility = 0.0, clickThrough = 0.0
        var renders = 0, clicks = 0, restacks = 0, restacked = 0
        var since = CACurrentMediaTime()
    }
    private var timing = WindowTiming()

    private func reportTiming() {
        let now = CACurrentMediaTime(), t = timing, span = now - t.since
        guard span >= 10 else { return }
        let line = String(format: "windows, last %.0f s: render %.3f ms × %d (visibility %.3f ms of it), "
                          + "click-through %.3f ms × %d, %d restacks (%d windows), %.1f %% of a core\n",
                          span, t.render * 1000 / Double(max(1, t.renders)), t.renders,
                          t.visibility * 1000 / Double(max(1, t.renders)), t.clickThrough * 1000 / Double(max(1, t.clicks)),
                          t.clicks, t.restacks, t.restacked, (t.render + t.clickThrough) / span * 100)
        FileHandle.standardError.write(line.data(using: .utf8)!)
        timing = WindowTiming(since: now)
    }

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
        // Only the cats with something going on (thousands of idle cats cost nothing here).
        let squash = swarmSquash
        var w = world
        w.pointer = world.cursor   // bones come back to you, not to their spot
        var moved: [Int] = []
        var anyExtra = false
        for (i, e) in extras.enumerated() where e.needsPhysics || draggingExtra == i {
            w.cursor = target(of: i, squash: squash)
            e.play.physics(dt: 1.0 / 60, world: w)
            moved.append(i)
            anyExtra = anyExtra || e.needsPhysics
        }
        handleEvents(extras: moved)
        render(extras: moved)
        if !play.needsPhysics && !juggling && !anyExtra {
            physicsTimer?.invalidate()
            physicsTimer = nil
        }
    }

    /// `only`, or every extra cat (without building an array of every index, every tick).
    private func eachExtra(_ only: [Int]?, _ f: (Int) -> Void) {
        if let only { for i in only { f(i) } } else { for i in extras.indices { f(i) } }
    }

    /// `only`: just these extra cats (the rest had nothing happen this frame).
    private func handleEvents(extras only: [Int]? = nil) {
        for e in play.drainEvents() { react(to: e, window: catWindow, cat: nil) }
        eachExtra(only) { i in
            let x = extras[i]
            for e in x.play.drainEvents() { react(to: e, window: x.window, cat: i) }
        }
    }

    /// Hearts, sounds and stats for whatever just happened. `cat`: which extra cat (nil: the
    /// first cat, or one on the Touch Bar).
    private func react(to e: PlaygroundEvent, window: CatWindow?, cat: Int?) {
        let id = window == nil ? 0 : (cat.map { $0 + 1 } ?? 0)   // whose stats (the bar counts as the first cat)
        switch e {
        case .heart: catStats.bump(.pets, cat: id)
        case .thrown(let speed) where speed > 600: catStats.bump(.yeets, cat: id)
        case .boxHop: catStats.bump(.naps, cat: id)
        case .fetched: catStats.bump(.fetches, cat: id)
        case .ate: catStats.bump(.meals, cat: id)
        case .played: catStats.bump(.playdates, cat: id)
        default: break
        }
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
            if window != nil { maybeDropIntoTouchBar(impact: impact, onWindow: win, at: at, cat: cat) }
        case .fetched: stats.bump(.fetches)
        case .bonked: stats.bump(.windowBonks); sounds.play(.mrrp)
        case .dockYeet: stats.bump(.dockYeets); sounds.play(.meow)
        case .dockBonk: stats.bump(.dockYeets); sounds.play(.mrrp)
        case .boxHop: stats.bump(.boxNaps); sounds.play(.mrrp)
        case .batYarn: stats.bump(.yarnBats)
        case .woke: sounds.play(.meow)
        case .ate: stats.bump(.meals); sounds.play(.purr)
        case .played: stats.bump(.playdates); sounds.play(.mrrp)
        default: break
        }
    }

    // MARK: - Drawing

    /// `only`: draw just these extra cats (60 fps frames redraw only the ones that moved; the
    /// 10 Hz tick draws everyone).
    private func render(extras only: [Int]? = nil) {
        guard touchBar == nil else { return }   // the desktop cat is away on the Touch Bar
        let t0 = Self.debug ? CACurrentMediaTime() : 0
        defer { if Self.debug { timing.render += CACurrentMediaTime() - t0; timing.renders += 1; reportTiming() } }
        let pose = play.catPose
        catWindow.render(pose, image: sprites.image(for: pose.sprite, frame: pose.frame), hatAnchor: hatAnchor(pose, sprites))
        eachExtra(only) { i in
            let x = extras[i]
            let p = x.pose
            x.window.render(p, image: x.sprites.image(for: p.sprite, frame: p.frame), hatAnchor: hatAnchor(p, x.sprites))
        }
        if laserOn { laserWindow.place(NSEvent.mouseLocation) }
        syncToyWindows()
        for (w, y) in zip(yarnWindows, toys.yarns) where y.prop.isOut {
            w.setClipped(y.prop.state == .pinned)
            w.render(y.prop.body)
        }
        for (w, b) in zip(boneWindows, toys.bones) where b.prop.isOut {
            w.setClipped(b.prop.state == .pinned)
            w.render(b.prop.body)
        }
        for (w, b) in zip(bowlWindows, toys.bowls) where b.prop.isOut {
            w.setArt(b.food > 0 ? PixelArt.bowlFull : PixelArt.bowlEmpty)
            w.setClipped(b.prop.state == .pinned)
            w.render(b.prop.body)
        }
        if let f = bigFront, let b = toys.boxes.first, b.prop.isOut { f.render(b.prop.body) }
        for (w, b) in zip(boxWindows, toys.boxes) where b.prop.isOut && (b.big || !b.occupied) {
            if !b.big { w.setArt(b.closed ? PixelArt.boxClosed : PixelArt.box) }
            w.setClipped(b.prop.state == .pinned)
            w.render(b.prop.body)
        }
        updateVisibility(pose, extras: only)
    }

    /// A window that was just clicked: the click may have brought it to the front of its level,
    /// so the next `updateVisibility` puts it back in its place (it only moves windows that
    /// are appearing, and this one already shows).
    private var reseat: NSWindow?

    private func updateVisibility(_ pose: CatPose, extras only: [Int]? = nil) {
        let t0 = Self.debug ? CACurrentMediaTime() : 0
        defer { if Self.debug { timing.visibility += CACurrentMediaTime() - t0 } }
        let covered = settings.hideInFullScreen ? world.fullScreenDisplays : []
        func hiddenAt(_ p: CGPoint) -> Bool { covered.contains { $0.contains(p) } }

        let wantCat = !noCat && (!hiddenAt(pose.center) || dragging == .cat)
        // A box with a cat in it is drawn by that cat's window.
        var order: [(NSWindow, Bool)] = zip(boxWindows, toys.boxes).map { w, b in
            (w, b.prop.isOut && (b.big || !b.occupied) && !hiddenAt(b.prop.body.pos))
        }
        order += zip(boneWindows, toys.bones).map { ($0, $1.prop.isOut && !hiddenAt($1.prop.body.pos)) }
        order += zip(yarnWindows, toys.yarns).map { ($0, $1.prop.isOut && !hiddenAt($1.prop.body.pos)) }
        order += zip(bowlWindows, toys.bowls).map { ($0, $1.prop.isOut && !hiddenAt($1.prop.body.pos)) }
        let toyCount = order.count
        eachExtra(only) { i in
            let x = extras[i]
            order.append((x.window, !hiddenAt(x.play.cat.position) || draggingExtra == i))
        }
        order.append((catWindow, wantCat))
        if let f = bigFront, let b = toys.boxes.first {   // in front of the cats sitting in it
            order.append((f, b.prop.isOut && !hiddenAt(b.prop.body.pos)))
        }
        order.append((laserWindow, laserOn))
        let again = reseat
        reseat = nil
        func place(_ w: NSWindow, _ want: Bool) -> Bool { want && (!w.isVisible || w === again) }
        var appearing = false
        for (w, want) in order {
            if place(w, want) { appearing = true } else if !want && w.isVisible { w.orderOut(nil) }
        }
        guard appearing else { return }
        // Back to front: toys, the extra cats, the first cat, the big box's front, the laser dot.
        // Only the windows that are appearing move, each to just under its nearest visible
        // neighbour above it in that order (one WindowServer call each, not one per window).
        // On a frame that only looked at some extra cats, the others still count as neighbours,
        // so a toy that pops out goes under every cat, not just the ones that moved.
        if let only {
            let tail = order[(toyCount + only.count)...]
            var full = Array(order[..<toyCount])
            full.reserveCapacity(toyCount + extras.count + tail.count)
            for x in extras { full.append((x.window, false)) }
            for (k, i) in only.enumerated() { full[toyCount + i].1 = order[toyCount + k].1 }
            full += tail
            order = full
        }
        var above: NSWindow?, placed = 0
        for (w, want) in order.reversed() {
            if place(w, want) {
                // A neighbour on another level (the laser dot) doesn't stack with this one.
                if let a = above, a.level == w.level {
                    w.order(.below, relativeTo: a.windowNumber)
                } else {
                    w.orderFrontRegardless()
                }
                placed += 1
            }
            if w.isVisible { above = w }
        }
        if Self.debug { timing.restacks += 1; timing.restacked += placed }
    }

    // MARK: - Mouse

    private func wireMouse() {
        let pairs: [(OverlayPanel, Thing)] = [(catWindow, .cat)]
        for (window, thing) in pairs {
            window.mouseView.onDown = { [weak self] p, t in
                guard let self else { return }
                // A cat shut in a box: grabbing it grabs the box (with the cat inside).
                let target: Thing = thing == .cat && play.inBox && play.boxClosed ? .box : thing
                dragging = target
                play.mouseDown(on: target, at: p, time: t)
            }
            window.mouseView.onOptionClick = { [weak self] in self?.renameCat(0) }
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
                reseat = window
                render()
                updateClickThrough()
            }
        }
        if !deepSleep { installMouseMonitors() }
    }

    /// One window per real box, bone and ball of yarn, made (and wired up) as they're added.
    private func syncToyWindows() {
        sync(&boxWindows, count: toys.boxes.count, art: PixelArt.box, thing: .box)
        sync(&boneWindows, count: toys.bones.count, art: PixelArt.bone, thing: .bone)
        sync(&yarnWindows, count: toys.yarns.count, art: PixelArt.yarn, thing: .yarn)
        sync(&bowlWindows, count: toys.bowls.count, art: PixelArt.bowlFull, thing: .bowl)
        syncBigBox()
    }

    /// A big box is two windows at twice the size: its back behind the cats in it, its front
    /// in front of them.
    private func syncBigBox() {
        let big = toys.boxes.first?.big ?? false
        let k = settings.size.rawValue * 2
        if big, let back = boxWindows.first {
            if back.art.image !== PixelArt.boxBack.image || back.rig.scale != CGFloat(k) {
                back.setArt(PixelArt.boxBack)
                back.setScale(k)
            }
            if bigFront == nil {
                let f = PropWindow(art: PixelArt.boxFront)
                f.setScale(k)
                wire(f, thing: .box, index: 0)
                bigFront = f
            } else if bigFront!.rig.scale != CGFloat(k) {
                bigFront!.setScale(k)
            }
        } else if let f = bigFront {
            f.orderOut(nil)
            bigFront = nil
            boxWindows.first?.setArt(PixelArt.box)
            boxWindows.first?.setScale(settings.size.rawValue)
        }
    }

    /// Mouse handling for a toy window: drag and throw it, click it, right-click it.
    private func wire(_ w: PropWindow, thing: Thing, index i: Int) {
        w.mouseView.onDown = { [weak self] p, t in
            guard let self else { return }
            dragging = thing
            play.mouseDown(on: thing, at: p, time: t, index: i)
        }
        w.mouseView.onRightClick = { [weak self] in
            guard let self else { return }
            play.rightClick(thing, index: i)
            if !play.isDragging { dragging = nil }
            startPhysicsIfNeeded()
            render()
            updateClickThrough()
        }
        w.mouseView.onDrag = { [weak self] p, t in
            guard let self else { return }
            play.mouseDragged(to: p, time: t)
            startPhysicsIfNeeded()
            render()
        }
        w.mouseView.onUp = { [weak self] p, t, clicks in
            guard let self else { return }
            play.mouseUp(at: p, time: t, clickCount: clicks)
            dragging = nil
            handleEvents()
            startPhysicsIfNeeded()
            reseat = w
            render()
            updateClickThrough()
        }
    }

    private func sync(_ windows: inout [PropWindow], count: Int, art: Art, thing: Thing) {
        while windows.count > count { windows.removeLast().orderOut(nil) }
        while windows.count < count {
            let i = windows.count
            let w = PropWindow(art: art)
            w.setScale(settings.size.rawValue)
            wire(w, thing: thing, index: i)
            windows.append(w)
        }
    }

    /// Every toy window, back to front.
    private var toyWindows: [PropWindow] {
        boxWindows + boneWindows + yarnWindows + bowlWindows + (bigFront.map { [$0] } ?? [])
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
        let t0 = Self.debug ? CACurrentMediaTime() : 0
        defer { if Self.debug { timing.clickThrough += CACurrentMediaTime() - t0; timing.clicks += 1 } }
        guard dragging == nil, draggingExtra == nil, !deepSleep else { hideHint(); return }
        if laserOn { laserWindow.place(NSEvent.mouseLocation) }
        if let t = toolbox, t.tool != .pointer {   // a Paint tool is active: the canvas gets every click
            let all: [NSWindow] = [catWindow] + toyWindows + extras.map(\.window)
            for w in all where !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
            hideHint()
            return
        }
        let p = NSEvent.mouseLocation
        // Cats napping in the big box poke their heads out over its front: on a head, you get
        // the cat (to lift it out); on the front, the box (with everyone in it).
        let onBigFront = bigFront.map { f in f.isVisible && (toys.boxes.first.map { f.hit(p, center: $0.prop.body.pos) } ?? false) } ?? false
        var hit = thing(at: p)
        if hit == .cat, play.inBigBox, onBigFront { hit = nil }
        let bigBoxExtra = hit == nil && !onBigFront ? extras.firstIndex { x in
            x.inBigBox && catHit(p, x.pose, x.sprites, x.catScale, x.window)
        } : nil
        // The toy under the pointer: yarn, then bones (small, so a little slop), then boxes.
        func under(_ ws: [PropWindow], _ props: [Prop], slop: Int) -> PropWindow? {
            Array(zip(ws, props)).last { w, pr in w.isVisible && w.hit(p, center: pr.body.pos, slop: slop) }?.0
        }
        let hitToy = hit != nil || bigBoxExtra != nil ? nil
            : under(yarnWindows, toys.yarns.map(\.prop), slop: 2) ?? under(boneWindows, toys.bones.map(\.prop), slop: 2)
                ?? under(bowlWindows, toys.bowls.map(\.prop), slop: 2)
                ?? under(bigFront.map { [$0] } ?? [], toys.boxes.prefix(1).map(\.prop), slop: 0)
                ?? under(boxWindows, toys.boxes.map(\.prop), slop: 0)
        // (Runs on every mouse move: rule out the cats nowhere near the pointer before working
        // out their pose. `catHit` checks the same box around the pose's centre, the cat's position.)
        let hitExtra = bigBoxExtra ?? (hit == nil && hitToy == nil ? extras.firstIndex { x in
            let c = x.play.cat.position, s = x.catScale
            guard abs(p.x - c.x) < 17 * s, abs(p.y - c.y) < 17 * s else { return false }
            return catHit(p, x.pose, x.sprites, s, x.window)
        } : nil)
        let catIgnore = hit != .cat
        if catWindow.ignoresMouseEvents != catIgnore { catWindow.ignoresMouseEvents = catIgnore }   // each set is a WindowServer call
        for w in toyWindows {
            let ignore = w !== hitToy
            if w.ignoresMouseEvents != ignore { w.ignoresMouseEvents = ignore }
        }
        for (i, x) in extras.enumerated() {
            let ignore = hitExtra != i
            if x.window.ignoresMouseEvents != ignore { x.window.ignoresMouseEvents = ignore }
        }
        // Hovering over a cat: its name and stats (and, if it's asleep, how to wake it).
        var hovered: (id: Int, p: Playground)?
        if hit == .cat { hovered = (0, play) }
        if let i = hitExtra { hovered = (i + 1, extras[i].play) }
        if let (id, p) = hovered {
            let now = CACurrentMediaTime()
            if hoverSince == nil || hoverID != id { hoverSince = now; hoverID = id }
            if now - hoverSince! > 0.4 {
                var text = CatNames.name(id, custom: settings.catNames)
                let s = catStats.summary(cat: id)
                if !s.isEmpty { text += " · " + s }
                if p.isSleeping { text += " · double-click to wake" }
                hintWindow.setText(text)
                hintWindow.show(above: CGPoint(x: p.catPose.center.x, y: p.catPose.center.y + 14 * p.catScale))
            }
        } else {
            hideHint()
        }
    }

    private var hoverID: Int?

    private func hideHint() {
        hoverSince = nil
        hoverID = nil
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
            for w in toyWindows { w.setScale(scale) }
            syncBigBox()
            for x in extras { x.play.setScale(scale); x.window.setScale(scale) }
            layOutHeap()
        }
        let night = settings.reacts && play.sleepy
        play.cat.speed = CGFloat(settings.speed.rawValue) * (night ? 0.75 : 1)
        play.cat.sleepEnabled = settings.naps
        play.spotWindows = settings.naps && settings.spotWindows
        play.spotMenuBar = settings.naps && settings.spotMenuBar
        play.spotDock = settings.naps && settings.spotDock
        play.dockBonk = settings.dockBonk
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
            x.play.dockBonk = settings.dockBonk
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
        let saved = settings.boxPositions
        for i in 0..<settings.realBoxCount {
            if let p = saved[safe: i], world.screen(containing: p) != nil {
                play.placeBox(at: p, falling: false, index: i)
            } else {
                play.placeBox(at: boxDropPoint(i), falling: true, index: i)
            }
        }
        layOutHeap()
        let bones = settings.bonePositions
        for i in 0..<settings.boneCount {
            if let p = bones[safe: i], world.screen(containing: p) != nil {
                play.placeBone(at: p, falling: false, index: i)
            } else {
                play.placeBone(at: toyDropPoint(i, offset: -80), falling: true, index: i)
            }
        }
        for i in 0..<settings.yarnCount { play.placeYarn(at: toyDropPoint(i, offset: 60), falling: true, index: i) }
        let bowls = settings.bowlPositions
        for i in 0..<settings.bowlCount {
            if let p = bowls[safe: i], world.screen(containing: p) != nil {
                play.placeBowl(at: p, falling: false, index: i)
            } else {
                play.placeBowl(at: toyDropPoint(i, offset: -160), falling: true, index: i)
            }
        }
        startPhysicsIfNeeded()
    }

    /// Next to the cursor; new toys fall from here.
    private func dropPoint(offset: CGFloat) -> CGPoint {
        let c = NSEvent.mouseLocation
        let p = CGPoint(x: c.x + offset, y: c.y)
        return world.screen(containing: p) != nil ? p : c
    }

    /// Where new box `i` drops in: a row (then rows) beside the cursor.
    private func boxDropPoint(_ i: Int) -> CGPoint {
        let s = play.scale
        let p = dropPoint(offset: 120 + CGFloat(i % 10) * 34 * s)
        return CGPoint(x: p.x, y: p.y + CGFloat(i / 10) * 40 * s)
    }

    /// Where new bone or ball of yarn `i` drops in: a row beside the cursor.
    private func toyDropPoint(_ i: Int, offset: CGFloat) -> CGPoint {
        let s = play.scale
        let p = dropPoint(offset: offset + CGFloat(i % 10) * 22 * s * (offset < 0 ? -1 : 1))
        return CGPoint(x: p.x, y: p.y + CGFloat(i / 10) * 24 * s)
    }

    /// Settings' bone and yarn counts onto the desktop.
    func applyToyCounts() {
        guard touchBar == nil else { touchBar?.setBone(settings.boneOut); return }
        if toys.bones.count > settings.boneCount {
            play.removeBones(keeping: settings.boneCount)
            for x in extras { x.play.removeBones(keeping: settings.boneCount) }
        }
        for i in toys.bones.count..<max(toys.bones.count, settings.boneCount) {
            play.placeBone(at: toyDropPoint(i, offset: -80), falling: true, index: i)
        }
        if toys.yarns.count > settings.yarnCount {
            play.removeYarns(keeping: settings.yarnCount)
            for x in extras { x.play.removeYarns(keeping: settings.yarnCount) }
        }
        for i in toys.yarns.count..<max(toys.yarns.count, settings.yarnCount) {
            play.placeYarn(at: toyDropPoint(i, offset: 60), falling: true, index: i)
        }
        if toys.bowls.count > settings.bowlCount {
            play.removeBowls(keeping: settings.bowlCount)
            for x in extras { x.play.removeBowls(keeping: settings.bowlCount) }
        }
        for i in toys.bowls.count..<max(toys.bowls.count, settings.bowlCount) {
            play.placeBowl(at: toyDropPoint(i, offset: -160), falling: true, index: i)
        }
        startPhysicsIfNeeded()
        render()
    }

    /// Settings' box count onto the desktop: real boxes first, then the heap.
    func applyBoxCount() {
        guard touchBar == nil else { touchBar?.setBox(settings.boxOut); return }
        let real = settings.realBoxCount
        if toys.boxes.count > real {
            play.removeBoxes(keeping: real)
            for x in extras { x.play.removeBoxes(keeping: real) }
        }
        for i in toys.boxes.count..<max(toys.boxes.count, real) { play.placeBox(at: boxDropPoint(i), falling: true, index: i) }
        toys.setBig(0, settings.bigBox)
        layOutHeap()
        startPhysicsIfNeeded()
        render()
    }

    /// (Re)build the GPU heap for every box past the first 50.
    private func layOutHeap() {
        let n = touchBar == nil ? settings.heapBoxCount : 0
        if n == 0 {
            heap?.stop()
            heap = nil
            toys.heap = []
            toys.heapNappers = [:]
            crowd?.setHeap([])
            return
        }
        let screens = NSScreen.screens.map(\.frame)
        let positions = BoxHeap.layout(count: n, screens: screens, scale: CGFloat(settings.size.rawValue))
        if positions.count < toys.heap.count { toys.heapNappers = toys.heapNappers.filter { $0.key < positions.count } }
        toys.heap = positions
        crowd?.setHeap(positions)
        let h = heap ?? BoxHeap()
        heap = h
        h.show(positions, scale: CGFloat(settings.size.rawValue), screens: screens)
    }

    private func savePositions() {
        settings.lastPosition = play.cat.position
        if !toys.boxes.isEmpty, touchBar == nil {
            let old = settings.boxPositions
            settings.boxPositions = toys.boxes.enumerated().map { i, b in
                b.prop.isResting || b.prop.state == .pinned ? b.prop.body.pos : (old[safe: i] ?? b.prop.body.pos)
            }
        }
        if !toys.bowls.isEmpty, touchBar == nil {
            let old = settings.bowlPositions
            settings.bowlPositions = toys.bowls.enumerated().map { i, b in
                b.prop.isResting || b.prop.state == .pinned ? b.prop.body.pos : (old[safe: i] ?? b.prop.body.pos)
            }
        }
        if !toys.bones.isEmpty, touchBar == nil {
            let old = settings.bonePositions
            settings.bonePositions = toys.bones.enumerated().map { i, b in
                b.prop.isResting || b.prop.state == .pinned ? b.prop.body.pos : (old[safe: i] ?? b.prop.body.pos)
            }
        }
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
            for w in [catWindow as NSWindow, laserWindow, hintWindow] + toyWindows + extras.map(\.window) {
                w.orderOut(nil)
            }
            crowd?.setVisible(false)
            heap?.setVisible(false)
            let tb = touchBar ?? TouchBarCat(sprites: sprites, icon: classic.menuBarIcon())
            tb.setCats(min(settings.catCount, TouchBarCat.maxCats), sheets: (0..<TouchBarCat.maxCats).map(extraSheet),
                       behavior: settings.catBehavior)
            tb.onNeedsPhysics = { [weak self] in self?.startPhysicsIfNeeded() }
            tb.onYeetToDesktop = { [weak self] along, v, cat in self?.yeetFromTouchBar(along: along, velocity: v, cat: cat) }
            tb.onEvent = { [weak self] e in self?.react(to: e, window: nil, cat: nil) }
            tb.flickToDesktop = settings.flickToDesktop
            touchBar = tb
            tb.install()
            tb.show()
            if settings.boxCount == 0 { settings.boxCount = 1 }   // the box always lives on the Touch Bar
            tb.setBox(true)
            tb.setBone(settings.boneOut)
            setLogicRate(0.1)
        } else {
            touchBar?.uninstall()
            touchBar = nil
            // Bring the desktop toys in line with what you chose while it was away.
            applyBoxCount()
            heap?.setVisible(true)
            applyToyCounts()
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
            self?.layOutHeap()      // the heap sits in each display's corner
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

        let toyMenu = NSMenu()
        let boxTitle = settings.boxCount > 1 && touchBar == nil ? "Cardboard Boxes (\(settings.boxCount.formatted()))" : "Cardboard Box"
        toyMenu.addItem(item(boxTitle, #selector(toggleBox), checked: touchBar?.hasBox ?? settings.boxOut))
        let boneTitle = settings.boneCount > 1 && touchBar == nil ? "Bones (\(settings.boneCount))" : "Bone"
        toyMenu.addItem(item(boneTitle, #selector(toggleBone), checked: touchBar?.hasBone ?? settings.boneOut))
        let yarnTitle = settings.yarnCount > 1 ? "Balls of Yarn (\(settings.yarnCount))" : "Ball of Yarn"
        toyMenu.addItem(item(yarnTitle, #selector(toggleYarn), checked: settings.yarnOut, enabled: touchBar == nil))
        toyMenu.addItem(item("Food Bowl", #selector(toggleBowl), checked: settings.bowlCount > 0, enabled: touchBar == nil))
        toyMenu.addItem(item("Laser Pointer", #selector(toggleLaser), checked: laserOn, enabled: touchBar == nil))
        toyMenu.addItem(.separator())
        toyMenu.addItem(item("Give Catnip", #selector(giveCatnip), enabled: touchBar == nil))
        menu.addItem(submenu("Toys", toyMenu))
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
        menu.addItem(item("What's New…", #selector(showWhatsNew)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
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
    @objc func toggleDockBonk() { settings.dockBonk.toggle(); applySettings() }
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

    /// Boxes on (as many as last time) or off.
    @objc func toggleBox() {
        let on = !(touchBar?.hasBox ?? settings.boxOut)
        setBoxCount(on ? settings.lastBoxCount : 0)
    }

    func setBoxCount(_ n: Int) {
        settings.boxCount = n
        applyBoxCount()
    }

    /// Bones on (as many as last time) or off.
    @objc func toggleBone() {
        let on = !(touchBar?.hasBone ?? settings.boneOut)
        setBoneCount(on ? settings.lastBoneCount : 0)
    }

    func setBoneCount(_ n: Int) {
        settings.boneCount = n
        applyToyCounts()
    }

    @objc func toggleBigBox() {
        settings.bigBox.toggle()
        applyBoxCount()
    }

    @objc func toggleBowl() { setBowlCount(settings.bowlCount > 0 ? 0 : 1) }

    func setBowlCount(_ n: Int) {
        settings.bowlCount = n
        applyToyCounts()
    }

    func setYarnCount(_ n: Int) {
        settings.yarnCount = n
        applyToyCounts()
    }

    /// Flicked hard off the Touch Bar: Neko moves to the desktop, flying up out of the bottom
    /// of the built-in display (right above the Touch Bar). `v` is already scaled.
    /// `cat`: which of the bar's extra cats it was (nil: the first cat); the same cat flies up.
    private func yeetFromTouchBar(along: CGFloat, velocity v: CGVector, cat: Int?) {
        setHome(touchBar: false)
        stats.bump(.touchBarTrips)
        sounds.play(.meow)
        let screen = builtInScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame, vis = screen.visibleFrame
        let start = CGPoint(x: f.minX + along * f.width, y: vis.minY + 20)
        world = WorldReader.read()
        if let i = cat, let x = extras[safe: i] {
            x.play.launch(at: start, velocity: v)
            x.window.orderFrontRegardless()
            handleEvents()
            startPhysicsIfNeeded()
            render()
        } else {
            withPlay { $0.launch(at: start, velocity: v) }
            catWindow.orderFrontRegardless()
        }
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

    @objc func checkForUpdates() { updates.check(userAsked: true) }

    private var whatsNewWindow: WhatsNewWindow?

    @objc func showWhatsNew() {
        let w = whatsNewWindow ?? WhatsNewWindow(icon: classic.image(for: .idle, frame: 0))
        whatsNewWindow = w
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
            x.play.leaveBoxes()
            x.window.orderOut(nil)
        }
        growExtras()
        let crowdCount = settings.crowdCatCount
        if crowdCount > 0 {
            let c = crowd ?? CrowdController()
            crowd = c
            c.setCoats(crowdSheets())
            c.setHeap(toys.heap)
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
            p.toys = toys                 // every cat shares the boxes
            p.catID = i + 1
            p.ownsToys = false             // the first cat's playground moves them
            p.dockBonk = settings.dockBonk
            p.laser = laserOn
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

    /// What extra cat `i` runs after. `squash`: `swarmSquash`, worked out once per tick.
    private func target(of i: Int, squash: CGFloat) -> CGPoint {
        if laserOn {   // everyone piles onto the dot
            let o = Self.swarmOffset(i, scale: play.scale)
            return CGPoint(x: world.cursor.x + o.dx * 0.35, y: world.cursor.y + o.dy * 0.35)
        }
        switch settings.catBehavior {
        case .conga:
            return i == 0 ? play.cat.position : extras[i - 1].play.cat.position
        case .swarm:
            let o = Self.swarmOffset(i, scale: play.scale)
            return CGPoint(x: world.cursor.x + o.dx * squash, y: world.cursor.y + o.dy * squash)
        case .roam:
            return extras[i].roam ?? extras[i].play.cat.position
        }
    }

    // MARK: - Cats playing together

    private func isPlaying(_ c: Int?) -> Bool {
        guard let i = c else { return play.isPlaying }
        return extras[safe: i]?.isPlaying ?? false
    }

    private func catPosition(_ c: Int?) -> CGPoint {
        c.map { extras[$0].play.cat.position } ?? play.cat.position
    }

    private func withCat(_ c: Int?, _ f: (inout Playground) -> Void) {
        if let i = c { f(&extras[i].play) } else { f(&play) }
    }

    /// Keep playing pairs facing each other; every 2 s, pair up idle cats sitting together.
    private func updatePlay() {
        playPairs.removeAll { a, b in
            (a.map { $0 >= extras.count } ?? false) || (b.map { $0 >= extras.count } ?? false) || !isPlaying(a) || !isPlaying(b)
        }
        for (a, b) in playPairs {
            let pa = catPosition(a), pb = catPosition(b)
            withCat(a) { $0.partner = pb }
            withCat(b) { $0.partner = pa }
        }
        guard settings.catsPlay, tickCount % 20 == 0, !extras.isEmpty else { return }
        let slots: [Int?] = (noCat ? [] : [nil]) + extras.indices.map { Optional($0) }
        var positions: [CGPoint] = []
        var free: [Bool] = []
        positions.reserveCapacity(slots.count)
        free.reserveCapacity(slots.count)
        for c in slots {
            positions.append(catPosition(c))
            free.append(c.map { extras[$0].canPlay } ?? play.canPlay)
        }
        for (i, j) in PlayMatcher.pairs(positions, free: free, radius: 50 * play.scale, chance: { Dice.roll($0) }) {
            let kind = PlayKind.allCases.randomElement()!
            let a = slots[i], b = slots[j]
            withCat(a) { $0.startPlay(kind, with: positions[j], leader: true) }
            withCat(b) { $0.startPlay(kind, with: positions[i], leader: false) }
            playPairs.append((a, b))
        }
    }

    // MARK: - Weather

    /// The weather (or none), on every display that isn't running something full screen.
    func updateSeason() {
        if settings.weather == "live", touchBar == nil, !deepSleep { LiveWeather.shared.refreshIfDue() }
        guard touchBar == nil, !deepSleep, let w = SeasonOverlay.weather(settings.weather, live: LiveWeather.shared.current) else {
            season?.stop()
            season = nil
            return
        }
        if season?.current != w {
            season?.stop()
            season = SeasonOverlay(w, thunder: { [weak self] in self?.sounds.play(.thunder) })
        }
        season?.update(screens: world.screenFrames, hidden: settings.hideInFullScreen ? world.fullScreenDisplays : [])
    }

    /// Free roam: every now and then each cat picks somewhere new to wander to.
    private func updateRoaming() {
        guard settings.catBehavior == .roam, !world.screens.isEmpty else { return }
        for x in extras {
            let there = x.roam.map { hypot($0.x - x.play.cat.position.x, $0.y - x.play.cat.position.y) < x.play.cat.stopDistance + 4 } ?? true
            if x.roam == nil || (there && Dice.roll(120) == 0) || Dice.roll(900) == 0 {   // (every cat, every tick)
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
        let squash = swarmSquash
        var w = world
        w.pointer = world.cursor   // bones come back to you, not to their spot
        for (i, x) in extras.enumerated() {
            w.cursor = target(of: i, squash: squash)
            x.play.tick10(world: w)
        }
        crowd?.behavior = settings.catBehavior
        crowd?.leader = extras.last?.play.cat.position ?? play.cat.position
        crowd?.tick(cursor: world.cursor, screens: world.screens,
                    covered: settings.hideInFullScreen ? world.fullScreenDisplays : [])
    }

    /// ⌥-click a cat: give it a name of your own (empty: its own name back). `id` 0 is the
    /// first cat, then the extra cats in order.
    func renameCat(_ id: Int) {
        hideHint()
        let alert = NSAlert()
        alert.messageText = "Rename \(CatNames.name(id, custom: settings.catNames))"
        alert.informativeText = "Leave it empty to go back to \(CatNames.name(id))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = settings.catNames[String(id)] ?? ""
        field.placeholderString = CatNames.name(id)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var names = settings.catNames
        let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        names[String(id)] = n.isEmpty ? nil : String(n.prefix(40))
        settings.catNames = names
        settingsWindow?.refresh()
    }

    private func wire(extra x: ExtraCat, index i: Int) {
        let v = x.window.mouseView
        v.onOptionClick = { [weak self, weak x] in
            guard let self, let x, let i = extras.firstIndex(where: { $0 === x }) else { return }
            renameCat(i + 1)
        }
        v.onDown = { [weak self, weak x] p, t in
            guard let self, let x else { return }
            draggingExtra = extras.firstIndex { $0 === x }
            // Shut in a box: grabbing the cat grabs the box (with the cat inside).
            x.play.mouseDown(on: x.play.inBox && x.play.boxClosed ? .box : .cat, at: p, time: t)
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
            reseat = x.window
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
        setYarnCount(settings.yarnOut ? 0 : settings.lastYarnCount)
    }

    @objc func toggleLaser() {
        laserOn.toggle()
        play.laser = laserOn
        for x in extras { x.play.laser = laserOn }   // every cat goes after the dot
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

    /// Any cat can be slammed through: `cat` is which extra (nil: the first cat), and the
    /// same cat drops onto the bar (if the bar has that many cats).
    private func maybeDropIntoTouchBar(impact: CGFloat, onWindow: Int?, at p: CGPoint, cat: Int?) {
        let thrown = cat.flatMap { extras[safe: $0]?.play.lastThrow } ?? play.lastThrow
        guard settings.slamToTouchBar, TouchBarCat.isSupported, touchBar == nil, !droppingIntoTouchBar, onWindow == nil,
              Self.slamsIntoTouchBar(impact: impact, thrown: thrown),
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
            touchBar?.arrive(along: along, cat: cat)
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
            for w in toyWindows + [catWindow] where w.isVisible { w.orderFrontRegardless() }
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

    // Read-only looks at `play`, for the loops over every cat. `x.play.catPose` would copy the
    // whole playground (a big struct) first; these read it in place (see `Playground.pose`).
    var pose: CatPose { Playground.pose(&play) }
    var needsPhysics: Bool { Playground.needsPhysics(&play) }
    var catScale: CGFloat { Playground.catScale(&play) }
    var canPlay: Bool { Playground.canPlay(&play) }
    var isPlaying: Bool { Playground.isPlaying(&play) }
    var inBigBox: Bool { Playground.inBigBox(&play) }
}
