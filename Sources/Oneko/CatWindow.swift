import AppKit

/// Forwards mouse events, in global coordinates, to closures.
final class MouseView: NSView {
    var onDown: ((CGPoint, TimeInterval) -> Void)?
    var onDrag: ((CGPoint, TimeInterval) -> Void)?
    var onUp: ((CGPoint, TimeInterval, Int) -> Void)?
    var onRightClick: (() -> Void)?
    /// ⌥-click (instead of a grab): rename the cat.
    var onOptionClick: (() -> Void)?
    /// This press was an ⌥-click: its drag and release aren't a grab either.
    private var optionPress = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        optionPress = e.modifierFlags.contains(.option) && onOptionClick != nil
        if optionPress { onOptionClick?(); return }
        onDown?(NSEvent.mouseLocation, e.timestamp)
    }
    override func mouseDragged(with e: NSEvent) { if !optionPress { onDrag?(NSEvent.mouseLocation, e.timestamp) } }
    override func mouseUp(with e: NSEvent) {
        if optionPress { optionPress = false; return }
        onUp?(NSEvent.mouseLocation, e.timestamp, e.clickCount)
    }
    override func rightMouseDown(with e: NSEvent) { onRightClick?() }
}

/// A transparent floating panel on every Space. Clicks pass through unless the app turns
/// them on while the pointer is over the art. Non-activating, so clicking it never steals
/// focus from the app you're using.
class OverlayPanel: NSPanel {
    let mouseView = MouseView()
    private(set) var side: CGFloat = 64

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        mouseView.wantsLayer = true
        contentView = mouseView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setSide(_ s: CGFloat) {
        side = s
        setContentSize(NSSize(width: s, height: s))
        artShift = .zero   // the subclass re-centres its art; the next `place` shifts it again
    }

    /// The layer with the art (a cat's or a toy's rig), centred in the panel. When it's set,
    /// `place` keeps the panel on one display and moves this layer instead.
    var artLayer: CALayer?
    private var artShift = CGPoint.zero

    /// Centre the art on `center` (global, y-up).
    ///
    /// The panel is twice the art's size (room to spin), so near the edge of a display it
    /// hangs over onto the next one. With a separate Space per display (macOS's default),
    /// a window only shows on one display, and macOS may pick the other one: the cat got
    /// clipped, vanished or jumped at the corner between two monitors. So the panel slides
    /// back inside the display under the art's centre, and the art moves the other way
    /// within it, staying exactly where it was.
    func place(_ center: CGPoint) {
        var o = NSPoint(x: (center.x - side / 2).rounded(), y: (center.y - side / 2).rounded())
        if let art = artLayer, Self.separateSpaces {
            let (origin, shift) = Self.fit(origin: o, side: side, center: center, displays: Self.displays)
            o = origin
            if shift != artShift {
                artShift = shift
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                art.position = CGPoint(x: side / 2 + shift.x, y: side / 2 + shift.y)
                CATransaction.commit()
            }
        }
        if frame.origin != o { setFrameOrigin(o) }
    }

    /// The panel origin inside the display that holds `center`, and how far the art has to
    /// move within the panel to stay put. Unchanged when no display holds it, or the panel
    /// doesn't fit.
    static func fit(origin o: CGPoint, side: CGFloat, center: CGPoint, displays: [CGRect]) -> (CGPoint, CGPoint) {
        guard let d = displays.first(where: { $0.contains(center) }), d.width >= side, d.height >= side
        else { return (o, .zero) }
        let x = min(max(o.x, d.minX), d.maxX - side), y = min(max(o.y, d.minY), d.maxY - side)
        return (CGPoint(x: x, y: y), CGPoint(x: o.x - x, y: o.y - y))
    }

    static let separateSpaces = NSScreen.screensHaveSeparateSpaces
    /// Display frames, kept current (read for every panel move, so not asked of AppKit each time).
    private static var displays: [CGRect] = {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            OverlayPanel.displays = NSScreen.screens.map(\.frame)
        }
        return NSScreen.screens.map(\.frame)
    }()

    static func pixelLayer() -> CALayer {
        let l = CALayer()
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsGravity = .resize
        l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                     "transform": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        return l
    }
}

/// The cat, plus the things drawn with it: the box it's napping in, the bone in its mouth,
/// the 💢 mark and hearts.
/// The cat and everything drawn with it (the box it's napping in, the bone in its mouth,
/// 💢, the clothespin, hearts) as one layer tree. Used by the desktop window and the Touch Bar.
final class CatRig {
    let layer = CALayer()
    private(set) var scale: CGFloat = 1
    var spriteSize: CGFloat { 32 * scale }
    var side: CGFloat { spriteSize * 2 }   // room to spin, and for the 💢 above its head
    private let boxBack = OverlayPanel.pixelLayer()
    private let sprite = OverlayPanel.pixelLayer()
    private let boxFront = OverlayPanel.pixelLayer()
    private let bone = OverlayPanel.pixelLayer()
    private let anger = OverlayPanel.pixelLayer()
    private let clip = OverlayPanel.pixelLayer()
    private let eat = OverlayPanel.pixelLayer()
    private var eatShown = false
    private let hat = OverlayPanel.pixelLayer()     // child of the sprite: tilts and spins with it
    private var hatArt: Art?
    private var angerShown = false
    private var lastPose: CatPose?
    private var lastImage: CGImage?
    private var lastAnchor: CGPoint?

    init() {
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]
        for l in [boxBack, sprite, boxFront, bone, anger, clip, eat] { layer.addSublayer(l) }
        anger.isHidden = true   // only while it's actually angry
        eat.isHidden = true
        eat.contents = PixelArt.eating.image
        clip.isHidden = true
        hat.isHidden = true
        sprite.addSublayer(hat)
        clip.contents = PixelArt.clip.image
        boxBack.contents = PixelArt.boxBack.image
        boxFront.contents = PixelArt.boxFront.image
        bone.contents = PixelArt.bone.image
        anger.contents = PixelArt.anger.image
        setScale(1)
    }

    var hasHat: Bool { hatArt != nil }

    /// A seasonal (or chosen) hat; nil for none.
    func setHat(_ art: Art?) {
        hatArt = art
        hat.contents = art?.image
        hat.isHidden = art == nil
        lastPose = nil
        if let a = art { hat.bounds = CGRect(x: 0, y: 0, width: CGFloat(a.width) * scale, height: CGFloat(a.height) * scale) }
    }

    func setScale(_ s: Int) {
        scale = CGFloat(s)
        lastPose = nil
        setHat(hatArt)
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let c = CGPoint(x: side / 2, y: side / 2)
        for l in [boxBack, sprite, boxFront] {
            l.bounds = CGRect(x: 0, y: 0, width: spriteSize, height: spriteSize)
            l.position = c
        }
        bone.bounds = CGRect(x: 0, y: 0, width: 16 * scale, height: 7 * scale)
        anger.bounds = CGRect(x: 0, y: 0, width: 13 * scale, height: 13 * scale)
        anger.position = CGPoint(x: c.x + 0.3 * spriteSize, y: c.y + 0.42 * spriteSize)
        clip.bounds = CGRect(x: 0, y: 0, width: 7 * scale, height: 11 * scale)
        clip.position = CGPoint(x: c.x + 0.03 * spriteSize, y: c.y + 0.5 * spriteSize)   // pinching the scruff
        eat.bounds = CGRect(x: 0, y: 0, width: CGFloat(PixelArt.eating.width) * scale, height: CGFloat(PixelArt.eating.height) * scale)
        eat.position = CGPoint(x: c.x - 0.28 * spriteSize, y: c.y + 0.5 * spriteSize)
    }

    /// Returns false when nothing changed (nothing was sent to the screen).
    @discardableResult
    func render(_ pose: CatPose, image: CGImage?, hatAnchor: CGPoint? = nil) -> Bool {
        if pose == lastPose && image === lastImage && hatAnchor == lastAnchor { return false }   // sitting still
        lastPose = pose
        lastImage = image
        lastAnchor = hatAnchor
        if let a = hatAnchor, let art = hatArt {
            // Anchor is in sprite pixels from the top-left; the hat's bottom sits on the head.
            hat.position = CGPoint(x: a.x * scale, y: spriteSize - a.y * scale + CGFloat(art.height) * scale / 2 - 2 * scale)
            hat.isHidden = false
        } else {
            hat.isHidden = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = image
        let lift = -(spriteSize / 2) * (1 - pose.squash)   // squash from the feet
        sprite.position = CGPoint(x: side / 2, y: side / 2 + (pose.inBox ? 4 * scale : 0))   // peek out of the box
        // (In a big box the box's own windows go behind and in front of the cat.)
        sprite.setAffineTransform(CGAffineTransform(rotationAngle: pose.angle)
            .translatedBy(x: 0, y: lift).scaledBy(x: 1, y: pose.squash))
        let shut = pose.inBox && pose.boxClosed
        boxBack.isHidden = !pose.inBox || shut
        boxFront.isHidden = !pose.inBox
        boxFront.contents = shut ? PixelArt.boxClosed.image : PixelArt.boxFront.image
        boxFront.setAffineTransform(CGAffineTransform(rotationAngle: pose.rattle))
        sprite.isHidden = shut
        sprite.opacity = Float(pose.opacity)   // fades as it's erased
        clip.isHidden = !pose.clipped

        bone.isHidden = !pose.carryingBone
        if pose.carryingBone {
            let dir = pose.sprite.rawValue
            let dx: CGFloat = dir.hasSuffix("E") ? 0.3 : dir.hasSuffix("W") ? -0.3 : 0
            bone.position = CGPoint(x: side / 2 + dx * spriteSize, y: side / 2 - 0.08 * spriteSize)
        }

        eat.isHidden = !pose.eating
        if pose.eating != eatShown {
            eatShown = pose.eating
            if pose.eating {
                // Nom, nom: the fish bobs up and down while it eats.
                let bob = CABasicAnimation(keyPath: "position.y")
                bob.fromValue = eat.position.y
                bob.toValue = eat.position.y + 3 * scale
                bob.duration = 0.3
                bob.autoreverses = true
                bob.repeatCount = .infinity
                eat.add(bob, forKey: "bob")
            } else {
                eat.removeAllAnimations()
            }
        }

        anger.isHidden = !pose.angry
        if pose.angry != angerShown {
            angerShown = pose.angry
            if pose.angry {
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 0.8
                pulse.toValue = 1.2
                pulse.duration = 0.35
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                anger.add(pulse, forKey: "pulse")
            } else {
                anger.removeAllAnimations()
            }
        }
        CATransaction.commit()
        return true
    }

    /// A heart that floats up from the cat's head and fades.
    func popHeart() {
        let h = OverlayPanel.pixelLayer()
        h.actions = nil
        h.contents = PixelArt.heart.image
        h.bounds = CGRect(x: 0, y: 0, width: 7 * scale, height: 6 * scale)
        let start = CGPoint(x: side / 2 + CGFloat.random(in: -0.15...0.15) * spriteSize,
                            y: side / 2 + 0.4 * spriteSize)
        h.position = start
        layer.addSublayer(h)
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = start.y
        rise.toValue = start.y + 0.45 * spriteSize
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [rise, fade]
        group.duration = 0.9
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { h.removeFromSuperlayer() }
        h.add(group, forKey: "pop")
        CATransaction.commit()
    }
}

/// The cat on the desktop: a click-through panel carrying a `CatRig`.
final class CatWindow: OverlayPanel {
    let rig = CatRig()

    override init() {
        super.init()
        mouseView.layer?.addSublayer(rig.layer)
        artLayer = rig.layer
        setScale(1)
    }

    func setScale(_ s: Int) {
        rig.setScale(s)
        setSide(rig.side)
        rig.layer.position = CGPoint(x: side / 2, y: side / 2)
    }

    func render(_ pose: CatPose, image: CGImage?, hatAnchor: CGPoint? = nil) {
        rig.render(pose, image: image, hatAnchor: hatAnchor)
        place(pose.center)
    }

    func popHeart() { rig.popHeart() }
}

/// A toy (bone or cardboard box) as a layer: the art, plus a clothespin when clipped.
final class PropRig {
    let layer = CALayer()
    private(set) var art: Art
    private let artLayer = OverlayPanel.pixelLayer()
    private let clip = OverlayPanel.pixelLayer()
    private(set) var scale: CGFloat = 1
    var side: CGFloat { max(CGFloat(art.width), CGFloat(art.height)) * scale * 1.5 }   // room to spin
    private var lastBody: (CGPoint, CGFloat)?

    init(art: Art) {
        self.art = art
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        artLayer.contents = art.image
        layer.addSublayer(artLayer)
        clip.contents = PixelArt.clip.image
        clip.isHidden = true
        layer.addSublayer(clip)
        setScale(1)
    }

    func setScale(_ s: Int) {
        scale = CGFloat(s)
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        artLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
        artLayer.position = CGPoint(x: side / 2, y: side / 2)
        placeClip()
    }

    private func placeClip() {
        let top = (CGFloat(art.height) / 2 - CGFloat(art.topRow)) * scale   // top edge of the art
        clip.bounds = CGRect(x: 0, y: 0, width: 7 * scale, height: 11 * scale)
        clip.position = CGPoint(x: side / 2, y: side / 2 + top + 3.5 * scale)
    }

    func setClipped(_ on: Bool) {
        if clip.isHidden == on { clip.isHidden = !on }
    }

    func setArt(_ a: Art) {
        guard a.image !== art.image else { return }
        art = a
        artLayer.contents = a.image
        lastBody = nil
        setScale(Int(scale))
    }

    /// Returns false when nothing moved.
    @discardableResult
    func render(_ body: Body) -> Bool {
        if let l = lastBody, l.0 == body.pos, l.1 == body.angle { return false }
        lastBody = (body.pos, body.angle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.setAffineTransform(CGAffineTransform(rotationAngle: body.angle))
        CATransaction.commit()
        return true
    }

    /// Is `p` on a painted pixel of the toy centred at `center`? Ignores rotation.
    func hit(_ p: CGPoint, center: CGPoint, slop: Int = 0) -> Bool {
        let x = Int(((p.x - center.x) / scale + CGFloat(art.width) / 2).rounded(.down))
        let y = Int(((center.y - p.y) / scale + CGFloat(art.height) / 2).rounded(.down))
        if slop == 0 { return art.isOpaque(x: x, y: y) }
        return x >= -slop && y >= -slop && x < art.width + slop && y < art.height + slop
    }
}

/// A toy on the desktop: a click-through panel carrying a `PropRig`.
final class PropWindow: OverlayPanel {
    let rig: PropRig
    var art: Art { rig.art }

    init(art: Art) {
        rig = PropRig(art: art)
        super.init()
        mouseView.layer?.addSublayer(rig.layer)
        artLayer = rig.layer
        setScale(1)
    }

    func setScale(_ s: Int) {
        rig.setScale(s)
        setSide(rig.side)
        rig.layer.position = CGPoint(x: side / 2, y: side / 2)
    }

    func setClipped(_ on: Bool) { rig.setClipped(on) }

    func setArt(_ a: Art) {
        // Called on every render for bowls and boxes: the same art again changes
        // nothing, so skip the resize (a WindowServer call) and the layer write.
        guard a.image !== rig.art.image else { return }
        rig.setArt(a)
        setSide(rig.side)
        rig.layer.position = CGPoint(x: side / 2, y: side / 2)
    }

    func render(_ body: Body) {
        rig.render(body)
        place(body.pos)
    }

    func hit(_ p: CGPoint, center: CGPoint, slop: Int = 0) -> Bool { rig.hit(p, center: center, slop: slop) }
}
