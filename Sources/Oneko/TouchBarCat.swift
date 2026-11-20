import AppKit

/// Private DFRFoundation calls, the same ones Pock and MTMR use. Looked up at runtime so
/// a missing symbol just turns the feature off.
private enum DFR {
    static let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
    typealias SetPresence = @convention(c) (NSString, Bool) -> Void
    typealias ShowCloseBox = @convention(c) (Bool) -> Void
    static let setPresence: SetPresence? = symbol("DFRElementSetControlStripPresenceForIdentifier")
    static let showCloseBox: ShowCloseBox? = symbol("DFRSystemModalShowsCloseBoxWhenFrontMost")

    static func symbol<T>(_ name: String) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
}

/// Touch Bar mode: Neko lives on the Touch Bar instead of the desktop.
///
/// It's the same playground as the desktop, in a world as wide as the Touch Bar: gravity,
/// the cardboard box, the bone, yeeting and petting, all driven by touch. The "sky" goes
/// far above the 30 pt strip, so a flick up sends Neko off the top and it drops back in.
/// A neko button in the Control Strip brings the bar back if you close it.
final class TouchBarCat: NSObject, NSTouchBarDelegate {
    static let trayID = NSTouchBarItem.Identifier("local.oneko.touchbar.tray")
    static let catID = NSTouchBarItem.Identifier("local.oneko.touchbar.cat")

    private static let addTray = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTray = NSSelectorFromString("removeSystemTrayItem:")
    private static let present = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    private static let dismiss = NSSelectorFromString("dismissSystemModalTouchBar:")

    static var isSupported: Bool {
        DFR.setPresence != nil
            && (NSTouchBarItem.self as AnyObject).responds(to: addTray)
            && (NSTouchBar.self as AnyObject).responds(to: present)
    }

    /// Height of the pretend world above the bar (the part you can't see is "sky").
    private static let sky: CGFloat = 600

    var sprites: SpriteSheet { didSet { render() } }
    /// Called when something starts moving and needs the 60 fps clock.
    var onNeedsPhysics: (() -> Void)?
    /// A clearly upward flick: the cat leaves for the desktop. Gives where along the bar it
    /// left (0…1) and its launch velocity.
    var onYeetToDesktop: ((CGFloat, CGVector) -> Void)?
    /// Everything that happens on the bar (for sounds and stats).
    var onEvent: ((PlaygroundEvent) -> Void)?
    /// Off: flicks never send Neko to the desktop (it just bounces around the bar).
    var flickToDesktop = true

    /// Sideways flicks keep Neko on the bar (a little hop). It goes to the desktop only when
    /// the finger moved clearly upward, or the flick was very hard.
    static let desktopYeet: CGFloat = 1600          // a very hard flick, any direction (pt/s)
    static let upwardFlick: CGFloat = 120           // or this much upward finger speed (pt/s)
    static let hopLift: CGFloat = 300               // the little hop a sideways flick gets

    /// Upward finger speed when it let go.
    static func upwardSpeed(_ play: Playground) -> CGFloat {
        (play.catBody.vel.dy - play.throwLift) / Playground.throwBoost
    }

    /// Does this throw send Neko off the bar and up onto the desktop?
    static func goesToDesktop(_ play: Playground) -> Bool {
        play.mode == .flying && (upwardSpeed(play) >= upwardFlick || flickSpeed(play) >= desktopYeet)
    }

    /// How fast the finger was moving when it let go, from the launch velocity.
    static func flickSpeed(_ play: Playground) -> CGFloat {
        let v = play.catBody.vel
        return hypot(v.dx, v.dy - play.throwLift) / Playground.throwBoost
    }
    private(set) var play = Playground(position: CGPoint(x: 60, y: 13))

    private let icon: NSImage
    private let view = TouchBarCatView()
    private var trayItem: NSCustomTouchBarItem?
    private var world: World
    private var tapTarget: (x: CGFloat, until: Double)?

    // Touch tracking
    private var touchThing: Thing?
    private var touchStart = CGPoint.zero
    private var touchMoved = false
    private var longPress: DispatchWorkItem?
    private var longPressed = false
    private var lastTap: (x: CGFloat, t: Double)?

    private lazy var bar: NSTouchBar = {
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [Self.catID]
        return b
    }()

    init(sprites: SpriteSheet, icon: NSImage) {
        self.sprites = sprites
        self.icon = icon
        world = TouchBarCat.world(width: 1000, cursor: CGPoint(x: 60, y: 13))
        super.init()
        play.gravityMode = true          // it walks along the bar
        play.spotWindows = false
        play.spotMenuBar = false
        play.spotDock = false
        play.throwLift = Self.hopLift    // sideways flicks: a little hop along the bar
        view.onTouch = { [weak self] phase, p, t in self?.touch(phase, p, t) }
    }

    var isShowing: Bool { view.window != nil }
    var needsPhysics: Bool { isShowing && play.needsPhysics }

    /// The part of the strip you can actually see (the bar may clip a wide view).
    private var span: (minX: CGFloat, width: CGFloat) {
        let v = view.visibleRect
        if v.width > 100 { return (v.minX, v.width) }
        return (0, max(view.bounds.width, 200))
    }

    private static func world(minX: CGFloat = 0, width: CGFloat, cursor: CGPoint) -> World {
        let f = CGRect(x: minX, y: 0, width: width, height: sky)
        return World(screens: [ScreenInfo(frame: f, visible: f)], windows: [], cursor: cursor)
    }

    // MARK: - Showing on the Touch Bar

    func install() {
        guard Self.isSupported, trayItem == nil else { return }
        let item = NSCustomTouchBarItem(identifier: Self.trayID)
        item.view = NSButton(image: icon, target: self, action: #selector(trayTapped))
        _ = (NSTouchBarItem.self as AnyObject).perform(Self.addTray, with: item)
        DFR.setPresence?(Self.trayID.rawValue as NSString, true)
        trayItem = item
    }

    func uninstall() {
        guard let item = trayItem else { return }
        hide()
        DFR.setPresence?(Self.trayID.rawValue as NSString, false)
        if (NSTouchBarItem.self as AnyObject).responds(to: Self.removeTray) {
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.removeTray, with: item)
        }
        trayItem = nil
    }

    func show() {
        leaving = false
        DFR.showCloseBox?(true)
        _ = (NSTouchBar.self as AnyObject).perform(Self.present, with: bar, with: Self.trayID.rawValue as NSString)
        render()
    }

    func hide() {
        if (NSTouchBar.self as AnyObject).responds(to: Self.dismiss) {
            _ = (NSTouchBar.self as AnyObject).perform(Self.dismiss, with: bar)
        }
    }

    @objc private func trayTapped() {
        isShowing ? hide() : show()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.catID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }

    // MARK: - Toys

    var hasBox: Bool { play.box.state != .hidden }
    var hasBone: Bool { play.bone.state != .hidden }

    func setBox(_ on: Bool) {
        if on, !hasBox { play.placeBox(at: CGPoint(x: span.minX + span.width * 0.72, y: 60), falling: true) }
        if !on, hasBox { play.removeBox() }
        render()
        onNeedsPhysics?()
    }

    func setBone(_ on: Bool) {
        if on, !hasBone { play.placeBone(at: CGPoint(x: span.minX + span.width * 0.4, y: 60), falling: true) }
        if !on, hasBone { play.removeBone() }
        render()
        onNeedsPhysics?()
    }

    // MARK: - Clocks (driven by the app)

    /// 10 Hz. The cursor's position across all displays maps onto the bar; a tap on an
    /// empty part of the bar sends Neko there for a few seconds instead.
    func tick10(cursor: CGPoint, screens: [CGRect], speed: CGFloat, naps: Bool, paused: Bool) {
        guard isShowing else { return }
        let (minX, w) = span
        let union = screens.reduce(CGRect.null) { $0.union($1) }
        var x = minX + (union.width > 0 ? (cursor.x - union.minX) / union.width * w : w / 2)
        if let t = tapTarget {
            if CACurrentMediaTime() < t.until { x = t.x } else { tapTarget = nil }
        }
        play.cat.speed = speed
        play.cat.sleepEnabled = naps
        play.paused = paused
        world = Self.world(minX: minX, width: w, cursor: CGPoint(x: x, y: 13))
        play.keepInside(minX...(minX + w))     // nothing gets lost off the ends of the bar
        play.tick10(world: world)
        afterChange()
    }

    func physics(dt: CGFloat) {
        guard isShowing else { return }
        play.physics(dt: dt, world: world)
        // Got well above the top of the bar on its way up (say, flung by a box): off it goes.
        if flickToDesktop, !leaving, Self.isEscaping(play) {
            leaving = true
            let (minX, w) = span
            let along = max(0, min(1, (play.cat.position.x - minX) / w))
            let v = play.catBody.vel
            let up = CGVector(dx: v.dx * 0.6, dy: max(1500, v.dy * 1.4))
            DispatchQueue.main.async { [weak self] in self?.onYeetToDesktop?(along, up) }
            return
        }
        afterChange()
    }

    /// The bar is 30 pt tall; feet clearly above it while still rising counts. A sideways
    /// flick's hop never gets that high.
    static func isEscaping(_ play: Playground) -> Bool {
        guard play.mode == .flying, play.catBody.vel.dy > 0 else { return false }
        return play.cat.position.y - 16 + 3 > 30 + 12
    }

    /// Set once the cat is on its way to the desktop, so it only goes once.
    private var leaving = false

    private func afterChange() {
        for e in play.drainEvents() {
            if e == .heart { view.popHeart() }
            onEvent?(e)
        }
        render()
    }

    /// Slammed down through the bottom of the screen: drop in from above the bar.
    func arrive(along: CGFloat) {
        leaving = false
        let (minX, w) = span
        play.launch(at: CGPoint(x: minX + max(0.05, min(0.95, along)) * w, y: 160), velocity: CGVector(dx: 0, dy: -500))
        render()
        onNeedsPhysics?()
    }

    private func render() {
        guard isShowing else { return }
        view.render(play: play, sprites: sprites)
    }

    // MARK: - Touch

    /// Tap: pet (or a little toss for the bone). Double-tap: stay. Drag and flick: throw.
    /// Long-press: clip it in place (or open/close the box). Tap empty bar: "come here".
    private func touch(_ phase: NSTouch.Phase, _ p: CGPoint, _ t: Double) {
        switch phase {
        case .began:
            touchStart = p
            touchMoved = false
            longPressed = false
            guard let thing = thing(at: p) else {
                touchThing = nil
                tapTarget = (p.x, CACurrentMediaTime() + 4)
                play.groundChanged()                     // wake an idle walker
                onNeedsPhysics?()
                return
            }
            touchThing = thing
            play.mouseDown(on: thing, at: p, time: t)
            let work = DispatchWorkItem { [weak self] in self?.longPressFired() }
            longPress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        case .moved:
            guard touchThing != nil, !longPressed else { return }
            if hypot(p.x - touchStart.x, p.y - touchStart.y) > 6 {
                touchMoved = true
                longPress?.cancel()
            }
            play.mouseDragged(to: p, time: t)
            render()
            onNeedsPhysics?()
        case .ended, .cancelled:
            longPress?.cancel()
            guard touchThing != nil else { return }
            defer { touchThing = nil }
            if longPressed { return }
            var clicks = 1
            if !touchMoved {
                if let l = lastTap, t - l.t < 0.35, abs(l.x - p.x) < 24 { clicks = 2 }
                lastTap = (p.x, t)
            }
            play.mouseUp(at: p, time: t, clickCount: clicks)
            if flickToDesktop, touchThing == .cat, Self.goesToDesktop(play), !leaving {
                leaving = true
                // Flicked up (or very hard): off the Touch Bar and up onto the desktop, always
                // upward, keeping some of the sideways direction, 1.4× as fast as the flick.
                let (minX, w) = span
                let along = max(0, min(1, (play.cat.position.x - minX) / w))
                let speed = Self.flickSpeed(play) * 1.4
                let raw = play.catBody.vel.dx / Playground.throwBoost
                let v = CGVector(dx: raw * 0.6, dy: max(1500, speed))
                DispatchQueue.main.async { [weak self] in self?.onYeetToDesktop?(along, v) }
                return
            }
            afterChange()
            onNeedsPhysics?()
        default:
            break
        }
    }

    private func longPressFired() {
        guard let thing = touchThing, !touchMoved else { return }
        longPressed = true
        play.rightClick(thing)                           // clip / unclip / box flaps
        afterChange()
        onNeedsPhysics?()
    }

    private func thing(at p: CGPoint) -> Thing? {
        if play.catContains(p, slop: 6) {
            return play.inBox && play.boxClosed ? .box : .cat   // a shut-in cat comes with its box
        }
        if play.bone.isOut, abs(p.x - play.bone.body.pos.x) < 14, abs(p.y - play.bone.body.pos.y) < 22 { return .bone }
        if play.box.isOut, !play.inBox, abs(p.x - play.box.body.pos.x) < 18 { return .box }
        return nil
    }
}

/// The strip on the Touch Bar: the cat and its toys as layers, plus touch input.
final class TouchBarCatView: NSView {
    var onTouch: ((NSTouch.Phase, CGPoint, Double) -> Void)?
    private let cat = CatRig()
    private let bone = PropRig(art: PixelArt.bone)
    private let box = PropRig(art: PixelArt.box)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
        layer = CALayer()
        wantsLayer = true
        allowedTouchTypes = [.direct]
        layer?.masksToBounds = false
        for l in [box.layer, bone.layer, cat.layer] {   // box at the back, cat in front
            l.isHidden = true
            layer?.addSublayer(l)
        }
        cat.layer.isHidden = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 1000, height: 30) }

    func render(play: Playground, sprites: SpriteSheet) {
        let pose = play.catPose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.render(pose, image: sprites.image(for: pose.sprite, frame: pose.frame))
        cat.layer.position = CGPoint(x: pose.center.x.rounded(), y: pose.center.y.rounded())

        bone.layer.isHidden = !play.bone.isOut
        if play.bone.isOut {
            bone.render(play.bone.body)
            bone.setClipped(play.bone.state == .pinned)
            bone.layer.position = play.bone.body.pos
        }
        let showBox = play.box.isOut && !pose.inBox
        box.layer.isHidden = !showBox
        if showBox {
            box.setArt(play.boxClosed ? PixelArt.boxClosed : PixelArt.box)
            box.render(play.box.body)
            box.setClipped(play.box.state == .pinned)
            box.layer.position = play.box.body.pos
        }
        CATransaction.commit()
    }

    func popHeart() { cat.popHeart() }

    override func touchesBegan(with event: NSEvent) { send(.began, event) }
    override func touchesMoved(with event: NSEvent) { send(.moved, event) }
    override func touchesEnded(with event: NSEvent) { send(.ended, event) }
    override func touchesCancelled(with event: NSEvent) { send(.cancelled, event) }

    private func send(_ phase: NSTouch.Phase, _ event: NSEvent) {
        guard let t = event.touches(matching: phase, in: self).first else { return }
        onTouch?(phase, t.location(in: self), event.timestamp)
    }
}
