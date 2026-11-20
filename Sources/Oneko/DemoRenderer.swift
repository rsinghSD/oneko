import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders the README demo from the real engine onto a stylised macOS desktop:
/// `Oneko --render-demo <dir>` writes <dir>/frames/0000.png… (30 fps, 1280×720) and
/// <dir>/audio.wav (the cat's own sounds, in sync). ffmpeg then makes the MP4 and GIF.
final class DemoRenderer {
    static let width = 1280, height = 720
    static let fps = 30.0

    private let sprites: SpriteSheet
    private let dir: String
    private let ctx: CGContext
    private var frame = 0
    private var time: Double { Double(frame) / Self.fps }

    // The fake desktop (y-up points = pixels).
    private let screen = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                                    visible: CGRect(x: 0, y: 76, width: 1280, height: 618),
                                    dock: CGRect(x: 0, y: 0, width: 1280, height: 76))
    private var windows: [WindowInfo] = []
    private var cursor = CGPoint(x: 640, y: 400)
    private var mouseDown = false
    private var showCursor = true
    private var finger: CGPoint?                       // touch indicator on the Touch Bar

    private var play = Playground(position: .zero)
    private var hearts: [(pos: CGPoint, born: Double)] = []
    private var caption = ""
    private var captionSince = 0.0
    private var sounds: [(t: Double, kind: SoundBox.Kind)] = []
    private var lastSound: [SoundBox.Kind: Double] = [:]
    private var wasAsleep = false
    private var rng = UInt64(42)

    init?(sprites: SpriteSheet, dir: String) {
        self.sprites = sprites
        self.dir = dir
        guard let c = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx = c
        try? FileManager.default.createDirectory(atPath: dir + "/frames", withIntermediateDirectories: true)
    }

    // MARK: - The script

    func render() {
        windows = [
            WindowInfo(id: 1, pid: 1, frame: CGRect(x: 90, y: 300, width: 420, height: 260)),
            WindowInfo(id: 2, pid: 1, frame: CGRect(x: 780, y: 230, width: 400, height: 270)),
        ]

        // 1. Chasing the cursor.
        newPlay(at: CGPoint(x: 130, y: 610))
        say("Chases your cursor")
        run(5.0) { t in
            let u = min(t, 3.6)
            self.cursor = CGPoint(x: 640 + 430 * sin(0.95 * u), y: 390 + 160 * sin(1.8 * u + 0.5))
        }

        // 2. Pets.
        say("Pet it")
        let petFrom = cursor
        var clicked: Set<Int> = []
        run(2.6) { t in
            let target = self.play.cat.position
            let k = min(1, t / 0.5)
            self.cursor = CGPoint(x: petFrom.x + (target.x - petFrom.x) * k, y: petFrom.y + (target.y - petFrom.y) * k)
            for (i, at) in [0.8, 1.6].enumerated() where t >= at && !clicked.contains(i) {
                clicked.insert(i)
                self.play.mouseDown(on: .cat, at: self.cursor, time: t)
                self.play.mouseUp(at: self.cursor, time: t + 0.05, clickCount: 1)
            }
        }

        // 3. Grab, swing and yeet it onto a window.
        say("Yeet it")
        let grabAt = play.cat.position
        var grabbed = false, released = false
        run(4.2) { t in
            if !grabbed { grabbed = true; self.cursor = grabAt; self.mouseDown = true
                self.play.mouseDown(on: .cat, at: grabAt, time: t) }
            if t < 1.2 {                                        // swing it round
                let a = t / 1.2 * 4 * .pi
                self.cursor = CGPoint(x: grabAt.x + 45 * sin(a), y: grabAt.y + 45 * (1 - cos(a)))
                self.play.mouseDragged(to: self.cursor, time: t)
            } else if t < 1.4 {                                 // and fling it up and left
                let k = (t - 1.2) / 0.2
                self.cursor = CGPoint(x: grabAt.x - 300 * k, y: grabAt.y + 190 * k)
                self.play.mouseDragged(to: self.cursor, time: t)
            } else if !released {
                released = true
                self.mouseDown = false
                self.play.mouseUp(at: self.cursor, time: t)
            } else {
                self.cursor.x += 4                               // drift out of the way
            }
        }

        // 4. Juggle it with a window.
        newPlay(at: CGPoint(x: 300, y: 660))
        play.launch(at: CGPoint(x: 300, y: 660), velocity: CGVector(dx: 0, dy: -200))
        cursor = CGPoint(x: 640, y: 420)
        say("Juggle it with windows")
        var flicked = false
        run(4.0) { t in
            let bar = CGPoint(x: 160, y: self.windows[0].frame.maxY - 12)
            if t < 1.3 {
                let k = min(1, t / 1.0)
                self.cursor = CGPoint(x: 640 + (bar.x - 640) * k, y: 420 + (bar.y - 420) * k)
            } else if t < 1.42 {                                // flick the window up…
                self.mouseDown = true
                if !flicked { flicked = true }
                self.windows[0].frame.origin.y = 300 + 150 * CGFloat((t - 1.3) / 0.12)
                self.cursor = CGPoint(x: bar.x, y: self.windows[0].frame.maxY - 12)
            } else if t < 2.3 {                                 // …and back down
                self.mouseDown = t < 1.6
                self.windows[0].frame.origin.y = max(300, self.windows[0].frame.origin.y - 6)
                self.cursor = CGPoint(x: bar.x, y: self.windows[0].frame.maxY - 12)
            } else {
                self.mouseDown = false
            }
        }
        windows[0].frame.origin.y = 300

        // 5. Window bonk.
        newPlay(at: CGPoint(x: 560, y: 76 + 26))
        play.mouseDown(on: .cat, at: play.cat.position, time: 0)     // double-click: sit right there
        play.mouseUp(at: play.cat.position, time: 0.05, clickCount: 2)
        windows[1].frame = CGRect(x: 820, y: 86, width: 380, height: 240)
        cursor = CGPoint(x: 890, y: windows[1].frame.maxY - 12)
        say("Bonk it with a window")
        run(3.6) { t in
            if t > 0.35 && t < 0.6 {                             // drag the window into it
                self.mouseDown = true
                self.windows[1].frame.origin.x = 820 - 440 * CGFloat((t - 0.35) / 0.25)
            } else {
                self.mouseDown = false
            }
            self.cursor = CGPoint(x: self.windows[1].frame.minX + 70, y: self.windows[1].frame.maxY - 12)
        }
        windows[1].frame = CGRect(x: 780, y: 230, width: 400, height: 270)

        // 6. Box nap.
        newPlay(at: CGPoint(x: 420, y: 76 + 26))
        play.placeBox(at: CGPoint(x: 900, y: 76 + 30), falling: false)
        cursor = CGPoint(x: 470, y: 200)
        say("Naps in cardboard boxes")
        var held = false, dropped = false, shut = false
        run(4.8) { t in
            if t < 0.4 {
                let k = t / 0.4
                self.cursor = CGPoint(x: 470 + (self.play.cat.position.x - 470) * k,
                                      y: 200 + (self.play.cat.position.y + 4 - 200) * k)
            } else if t < 1.75 {
                if !held { held = true; self.mouseDown = true
                    self.play.mouseDown(on: .cat, at: self.cursor, time: t) }
                let k = min(1, (t - 0.4) / 1.0)
                let from = CGPoint(x: 420, y: 106), to = CGPoint(x: 900, y: 290)
                self.cursor = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k + 90 * sin(.pi * k))
                self.play.mouseDragged(to: self.cursor, time: t)       // pauses over the box at the end
            } else if !dropped {
                dropped = true
                self.mouseDown = false
                self.play.mouseUp(at: self.cursor, time: t)
            } else if t > 3.6 && !shut && self.play.inBox {
                shut = true
                self.play.rightClick(.cat)                      // close the flaps
            } else {
                self.cursor.x += 2
            }
        }

        // 7. Yarn.
        newPlay(at: CGPoint(x: 360, y: 76 + 26))
        cursor = CGPoint(x: 360, y: 230)
        play.placeYarn(at: CGPoint(x: 1150, y: 260), falling: true)
        play.yarn.body.vel = CGVector(dx: -620, dy: 0)
        say("Plays with yarn, a bone, a laser…")
        run(4.2) { _ in }

        // 8. Touch Bar.
        touchBarScene()

        // 9. End card.
        caption = ""
        for _ in 0..<Int(3.4 * Self.fps) { drawEndCard(); emit() }

        writeAudio()
    }

    // MARK: - Simulation

    private func newPlay(at p: CGPoint) {
        play = Playground(position: p)
        play.setScale(2)
        play.cat.speed = 15
        play.spotWindows = false; play.spotMenuBar = false; play.spotDock = false
        let seed = rng
        var g = SplitMix(seed: seed)
        play.random = { n in Int(g.next() % UInt64(max(n, 1))) }
        var g2 = SplitMix(seed: seed &+ 7)
        play.cat.random = { n in Int(g2.next() % UInt64(max(n, 1))) }
        rng &+= 1
        hearts.removeAll()
        wasAsleep = false
    }

    private var world: World {
        World(screens: [screen], windows: windows, cursor: cursor, mouseDown: mouseDown)
    }

    /// Run a scene for `seconds`, calling `step` each frame with the scene's time.
    private func run(_ seconds: Double, _ step: (Double) -> Void) {
        let n = Int(seconds * Self.fps)
        for i in 0..<n {
            let t = Double(i) / Self.fps
            step(t)
            simulate()
            drawDesktop()
            emit()
        }
    }

    private func simulate() {
        if frame % 3 == 0 {                                     // 10 Hz brain + windows
            play.updateWindows(world, dt: 0.1)
            play.tick10(world: world)
        }
        play.physics(dt: 1.0 / 60, world: world)
        play.physics(dt: 1.0 / 60, world: world)
        handle(play.drainEvents(), at: play.cat.position)
        let asleep = play.cat.sprite == .sleeping
        if asleep && !wasAsleep { sound(.sleep) }
        wasAsleep = asleep
    }

    private func handle(_ events: [PlaygroundEvent], at p: CGPoint) {
        for e in events {
            switch e {
            case .heart: hearts.append((CGPoint(x: p.x + CGFloat.random(in: -8...8), y: p.y + 26), time)); sound(.purr)
            case .thrown(let s) where s > 1500: sound(.mrrp)
            case .landed(let impact, _, _) where impact > 900: sound(.thud)
            case .boxHop, .bonked: sound(.mrrp)
            case .woke, .dockYeet: sound(.meow)
            default: break
            }
        }
    }

    private func sound(_ kind: SoundBox.Kind) {
        let gap: Double = kind == .purr ? 1.1 : kind == .sleep ? 4 : 0.25
        if let l = lastSound[kind], time - l < gap { return }
        lastSound[kind] = time
        sounds.append((time, kind))
    }

    private func say(_ text: String) {
        caption = text
        captionSince = time
    }

    // MARK: - Touch Bar scene

    private func touchBarScene() {
        say("Lives on your Touch Bar too")
        var tb = Playground(position: CGPoint(x: 80, y: 13))
        tb.gravityMode = true
        tb.spotWindows = false; tb.spotMenuBar = false; tb.spotDock = false
        tb.throwLift = TouchBarCat.hopLift
        tb.cat.speed = 7
        var g = SplitMix(seed: 99)
        tb.random = { n in Int(g.next() % UInt64(max(n, 1))) }
        var g2 = SplitMix(seed: 100)
        tb.cat.random = { n in Int(g2.next() % UInt64(max(n, 1))) }
        tb.placeBox(at: CGPoint(x: 470, y: 15), falling: false)
        let barW: CGFloat = 560
        let f = CGRect(x: 0, y: 0, width: barW, height: 600)
        var target: CGFloat = 330
        var flicked = false, released = false
        var escape: (pos: CGPoint, vel: CGVector, angle: CGFloat, since: Double)?   // pixels, on the screen
        tb.launch(at: CGPoint(x: 120, y: 160), velocity: CGVector(dx: 0, dy: -500))
        showCursor = false
        let n = Int(4.8 * Self.fps)
        for i in 0..<n {
            let t = Double(i) / Self.fps
            finger = nil
            if t > 1.0 && t < 1.25 { finger = CGPoint(x: 330, y: 15); target = 330 }      // tap: come here
            if t > 2.6 && !released {                                                       // flick it up
                let c = tb.cat.position
                if !flicked { flicked = true; tb.mouseDown(on: .cat, at: c, time: t) }
                let k = CGFloat((t - 2.6) / 0.15)
                let p = CGPoint(x: c.x + 30 * k, y: 13 + 16 * k)
                finger = p
                tb.mouseDragged(to: p, time: t)
                if k >= 1 { released = true; tb.mouseUp(at: p, time: t + 0.01) }
            }
            let w = World(screens: [ScreenInfo(frame: f, visible: f)], windows: [], cursor: CGPoint(x: target, y: 13))
            if frame % 3 == 0 { tb.tick10(world: w) }
            tb.physics(dt: 1.0 / 60, world: w)
            tb.physics(dt: 1.0 / 60, world: w)
            handle(tb.drainEvents(), at: tb.cat.position)
            // Once it's well above the bar it has left for the desktop: show it flying up the screen.
            if escape == nil, released, tb.cat.position.y > 40 {
                let p = px(tb.cat.position, CGPoint(x: 80, y: 152), 2)
                escape = (CGPoint(x: p.x, y: 300), CGVector(dx: 120, dy: 950), 0, t)
                sound(.meow)
            }
            if var e = escape {
                let dt = 1.0 / Self.fps
                e.vel.dy -= 1300 * dt
                e.pos.x += e.vel.dx * dt
                e.pos.y += e.vel.dy * dt
                e.angle += 9 * dt
                escape = e
            }
            drawTouchBar(tb, hideCat: escape != nil)
            if let e = escape, e.pos.y > 300 - 40 {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 140, y: 300, width: 1000, height: 400))     // inside the screen
                let sprite: SpriteName = e.vel.dy > 0 ? .N : .S
                drawImage(sprites.image(for: sprite, frame: frame / 3), center: e.pos, size: CGSize(width: 96, height: 96), angle: e.angle)
                ctx.restoreGState()
            }
            emit()
        }
        showCursor = true
        finger = nil
    }

    // MARK: - Drawing

    private func ns() { NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false) }

    private func drawDesktop() {
        drawWallpaper(CGRect(x: 0, y: 0, width: 1280, height: 720))
        for w in windows.reversed() { drawWindow(w.frame, title: w.id == 1 ? "Notes" : "Finder") }
        drawDock()
        drawMenuBar()
        drawProps(play, scale: 2, origin: .zero, unit: 1)
        drawCat(play, sheet: sprites, origin: .zero, unit: 1)
        drawHearts(origin: .zero, unit: 1)
        if showCursor { drawCursor(cursor) }
        drawCaption()
    }

    private func drawWallpaper(_ r: CGRect) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.42, green: 0.36, blue: 0.86, alpha: 1), CGColor(red: 0.86, green: 0.52, blue: 0.72, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
        ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.45, width: r.width * 0.6, height: r.width * 0.6))
        ctx.fillEllipse(in: CGRect(x: r.minX - r.width * 0.2, y: r.minY - r.width * 0.25, width: r.width * 0.55, height: r.width * 0.55))
        ctx.restoreGState()
    }

    private func drawWindow(_ f: CGRect, title: String) {
        let path = CGPath(roundedRect: f, cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.91, alpha: 1))
        ctx.fill(CGRect(x: f.minX, y: f.maxY - 30, width: f.width, height: 30))
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        ctx.fill(CGRect(x: f.minX, y: f.maxY - 31, width: f.width, height: 1))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: f.minX + 13 + CGFloat(i) * 20, y: f.maxY - 21, width: 12, height: 12))
        }
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        var y = f.maxY - 58
        var i = 0
        while y > f.minY + 18 {
            let w = f.width * [0.7, 0.55, 0.8, 0.4, 0.65][i % 5]
            ctx.fill(CGRect(x: f.minX + 22, y: y, width: w - 30, height: 9))
            y -= 24; i += 1
        }
        ctx.restoreGState()
        ns()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (title as NSString).draw(in: CGRect(x: f.minX, y: f.maxY - 23, width: f.width, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.3, alpha: 1),
            .paragraphStyle: style])
    }

    private func drawDock() {
        let r = CGRect(x: 330, y: 8, width: 620, height: 62)
        let path = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 0.28)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); ctx.setLineWidth(1); ctx.strokePath()
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.55, 1), (0.98, 0.35, 0.3), (0.3, 0.8, 0.45), (1, 0.75, 0.2),
                                                     (0.6, 0.4, 0.95), (0.95, 0.5, 0.8), (0.25, 0.75, 0.85), (0.45, 0.45, 0.5)]
        for (i, c) in colors.enumerated() {
            let x = r.minX + 16 + CGFloat(i) * 68
            let icon = CGRect(x: x, y: r.minY + 7, width: 48, height: 48)
            ctx.addPath(CGPath(roundedRect: icon, cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fillPath()
        }
        // Oneko itself, of course.
        let icon = CGRect(x: r.minX + 16 + 8 * 68, y: r.minY + 7, width: 48, height: 48)
        ctx.addPath(CGPath(roundedRect: icon, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.setFillColor(CGColor(red: 0.36, green: 0.36, blue: 0.82, alpha: 1)); ctx.fillPath()
        ctx.interpolationQuality = .none
        ctx.draw(PixelArt.box.image, in: icon.insetBy(dx: 4, dy: 4))
    }

    private func drawMenuBar() {
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.45))
        ctx.fill(CGRect(x: 0, y: 694, width: 1280, height: 26))
        ns()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.white]
        ("Oneko" as NSString).draw(at: CGPoint(x: 18, y: 699), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
        var x: CGFloat = 80
        for m in ["File", "Edit", "View", "Window", "Help"] {
            (m as NSString).draw(at: CGPoint(x: x, y: 699), withAttributes: attrs)
            x += (m as NSString).size(withAttributes: attrs).width + 22
        }
        ("Fri 9:41" as NSString).draw(at: CGPoint(x: 1196, y: 699), withAttributes: attrs)
        // The neko face in the menu bar.
        if let rep = sprites.menuBarIcon().representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
           let cg = rep.cgImage {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 1160, y: 699, width: 15, height: 15), mask: cg)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 1160, y: 699, width: 15, height: 15))
            ctx.restoreGState()
        }
    }

    /// World point → pixel.
    private func px(_ p: CGPoint, _ origin: CGPoint, _ unit: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + p.x * unit, y: origin.y + p.y * unit)
    }

    private func drawImage(_ img: CGImage?, center: CGPoint, size: CGSize, angle: CGFloat = 0) {
        guard let img else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.draw(img, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    private func drawProps(_ p: Playground, scale: CGFloat, origin: CGPoint, unit: CGFloat) {
        let s = scale * unit
        if p.box.isOut && !p.inBox {
            let art = p.boxClosed ? PixelArt.boxClosed : PixelArt.box
            drawImage(art.image, center: px(p.box.body.pos, origin, unit), size: CGSize(width: 32 * s, height: 32 * s), angle: p.box.body.angle)
        }
        if p.yarn.isOut {
            drawImage(PixelArt.yarn.image, center: px(p.yarn.body.pos, origin, unit), size: CGSize(width: 12 * s, height: 12 * s), angle: p.yarn.body.angle)
        }
        if p.bone.isOut {
            drawImage(PixelArt.bone.image, center: px(p.bone.body.pos, origin, unit), size: CGSize(width: 16 * s, height: 7 * s), angle: p.bone.body.angle)
        }
    }

    private func drawCat(_ p: Playground, sheet: SpriteSheet, origin: CGPoint, unit: CGFloat) {
        let pose = p.catPose
        let s = p.catScale * unit
        let size = 32 * s
        let c = px(pose.center, origin, unit)
        let shut = pose.inBox && pose.boxClosed
        if pose.inBox && !shut { drawImage(PixelArt.boxBack.image, center: c, size: CGSize(width: size, height: size)) }
        if !shut, let img = sheet.image(for: pose.sprite, frame: pose.frame) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: c.x, y: c.y + (pose.inBox ? 4 * s : 0))
            ctx.rotate(by: pose.angle)
            ctx.translateBy(x: 0, y: -(size / 2) * (1 - pose.squash))
            ctx.scaleBy(x: 1, y: pose.squash)
            ctx.setAlpha(pose.opacity)
            ctx.draw(img, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
            ctx.restoreGState()
        }
        if pose.inBox {
            drawImage((shut ? PixelArt.boxClosed : PixelArt.boxFront).image, center: c, size: CGSize(width: size, height: size), angle: pose.rattle)
        }
        if pose.carryingBone {
            drawImage(PixelArt.bone.image, center: CGPoint(x: c.x + 0.3 * size, y: c.y - 0.08 * size), size: CGSize(width: 16 * s, height: 7 * s))
        }
        if pose.angry {
            let k = 1 + 0.2 * CGFloat(sin(time * 9))
            drawImage(PixelArt.anger.image, center: CGPoint(x: c.x + 0.3 * size, y: c.y + 0.42 * size),
                      size: CGSize(width: 13 * s * k, height: 13 * s * k))
        }
    }

    private func drawHearts(origin: CGPoint, unit: CGFloat) {
        hearts.removeAll { time - $0.born > 0.9 }
        for h in hearts {
            let k = CGFloat((time - h.born) / 0.9)
            ctx.saveGState()
            ctx.setAlpha(1 - k)
            drawImage(PixelArt.heart.image, center: px(CGPoint(x: h.pos.x, y: h.pos.y + 30 * k), origin, unit), size: CGSize(width: 14, height: 12))
            ctx.restoreGState()
        }
    }

    private func drawCursor(_ p: CGPoint) {
        let pts: [CGPoint] = [(0, 0), (0, -23), (6, -17.5), (10, -26), (14, -24.4), (10, -16), (17, -16)].map { CGPoint(x: p.x + $0.0, y: p.y + $0.1) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addLines(between: pts); ctx.closePath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addLines(between: pts); ctx.closePath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.6)
        ctx.drawPath(using: .fillStroke)
        if mouseDown {                                        // a little click ring
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
        }
    }

    private func drawCaption() {
        guard !caption.isEmpty else { return }
        let a = CGFloat(min(1, (time - captionSince) / 0.25))
        ns()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white]
        let size = (caption as NSString).size(withAttributes: attrs)
        let r = CGRect(x: 640 - size.width / 2 - 22, y: 620, width: size.width + 44, height: size.height + 16)
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55)); ctx.fillPath()
        (caption as NSString).draw(at: CGPoint(x: r.minX + 22, y: r.minY + 8), withAttributes: attrs)
        ctx.restoreGState()
    }

    private func drawTouchBar(_ tb: Playground, hideCat: Bool = false) {
        // A MacBook: the screen above, the keyboard deck with the Touch Bar below.
        ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let screenR = CGRect(x: 140, y: 300, width: 1000, height: 400)
        drawWallpaper(screenR)
        ctx.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 270))
        let bar = CGRect(x: 80, y: 150, width: 1120, height: 64)
        ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: -6, dy: -6), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(bar)
        for row in 0..<2 {                                      // a hint of keys
            for k in 0..<14 {
                let key = CGRect(x: 80 + CGFloat(k) * 80, y: 70 - CGFloat(row) * 70, width: 72, height: 60)
                ctx.addPath(CGPath(roundedRect: key, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
            }
        }
        let origin = CGPoint(x: bar.minX, y: bar.minY + 2)
        drawProps(tb, scale: 1, origin: origin, unit: 2)
        if !hideCat { drawCat(tb, sheet: sprites, origin: origin, unit: 2) }
        drawHearts(origin: origin, unit: 2)
        if let f = finger {
            let p = px(f, origin, 2)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
        }
        drawCaption()
    }

    private func drawEndCard() {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.47, green: 0.55, blue: 1.0, alpha: 1), CGColor(red: 0.27, green: 0.21, blue: 0.62, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 720), end: CGPoint(x: 0, y: 0), options: [])
        let art = CGRect(x: 640 - 112, y: 390, width: 224, height: 224)
        ctx.interpolationQuality = .none
        ctx.draw(PixelArt.boxBack.image, in: art)
        if let cat = sprites.image(for: .idle, frame: 0) { ctx.draw(cat, in: art.offsetBy(dx: -14, dy: 49)) }
        ctx.draw(PixelArt.boxFront.image, in: art)
        ns()
        func center(_ s: String, _ y: CGFloat, _ font: NSFont, _ color: NSColor = .white) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let w = (s as NSString).size(withAttributes: attrs).width
            (s as NSString).draw(at: CGPoint(x: 640 - w / 2, y: y), withAttributes: attrs)
        }
        center("Oneko", 318, .systemFont(ofSize: 60, weight: .heavy))
        center("A desktop cat for your Mac", 278, .systemFont(ofSize: 24, weight: .medium), NSColor(white: 1, alpha: 0.85))
        let cmd = "brew install --cask oneko"
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white]
        let w = (cmd as NSString).size(withAttributes: mono).width
        let pill = CGRect(x: 640 - w / 2 - 20, y: 196, width: w + 40, height: 44)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35)); ctx.fillPath()
        (cmd as NSString).draw(at: CGPoint(x: pill.minX + 20, y: pill.minY + 10), withAttributes: mono)
        center("github.com/rsinghSD/oneko", 148, .systemFont(ofSize: 22, weight: .semibold), NSColor(white: 1, alpha: 0.9))
    }

    // MARK: - Output

    private func emit() {
        if let img = ctx.makeImage() {
            let url = URL(fileURLWithPath: String(format: "%@/frames/%04d.png", dir, frame)) as CFURL
            if let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        frame += 1
    }

    private func writeAudio() {
        let rate = Double(SoundBox.sampleRate)
        var mix = [Float](repeating: 0, count: Int(time * rate) + 1)
        for s in sounds {
            let start = Int(s.t * rate)
            let gain: Float = s.kind == .sleep ? 0.6 : 0.8
            for (i, v) in SoundBox.samples(s.kind).enumerated() where start + i < mix.count {
                mix[start + i] += v * gain
            }
        }
        for i in mix.indices { mix[i] = max(-1, min(1, mix[i])) }
        try? SoundBox.wavData(mix).write(to: URL(fileURLWithPath: dir + "/audio.wav"))
        print("frames: \(frame) (\(String(format: "%.1f", time)) s), sounds: \(sounds.count)")
    }
}

/// Small deterministic RNG so the demo renders the same every time.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
