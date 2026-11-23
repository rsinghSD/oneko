import AppKit

if CommandLine.arguments.contains("--bench") {
    Bench.run()
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

// `Oneko --diagnose`: what Oneko sees of your displays and the Dock (for bug reports).
if CommandLine.arguments.contains("--diagnose") {
    _ = NSApplication.shared
    let p = WorldReader.dockPrefs()
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    print("Oneko \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Dock settings: edge \(p.edge), autohide \(p.autohide), tile \(Int(p.tile)) pt, delay \(p.delay) s")
    print("Dock contents: \(p.icons) icons, \(p.separators) separators -> about \(Int(WorldReader.dockLength(p))) pt long")
    print("Exact Dock size (Accessibility): \(WorldReader.exactDockAllowed ? "allowed" : "not allowed")"
          + (WorldReader.exactDockFrame().map { ", list frame \($0)" } ?? ""))
    let world = WorldReader.read()
    for (s, info) in zip(NSScreen.screens, world.screens) {
        let strip = WorldReader.dockStrip(frame: s.frame, visible: s.visibleFrame, cursor: world.cursor)
        print("Display \"\(s.localizedName)\"")
        print("  frame \(s.frame), visible \(s.visibleFrame)")
        print("  space kept for the Dock: \(strip.map { "\($0)" } ?? "none")")
        print("  Dock Oneko uses: \(info.dock.map { "\($0)" } ?? "none")")
    }
    exit(0)
}

guard let sprites = SpriteSheet.load() else {
    FileHandle.standardError.write("Oneko: could not load oneko.gif\n".data(using: .utf8)!)
    exit(1)
}

// Dev helper: `Oneko --crowd-png out.png` renders 6,000 crowd cats offscreen (real GPU code).
if let i = CommandLine.arguments.firstIndex(of: "--crowd-png"), i + 1 < CommandLine.arguments.count {
    let crowd = CrowdController()
    let screen = CGRect(x: 0, y: 0, width: 1146, height: 480)   // ultrawide-shaped
    let withHeap = CommandLine.arguments.contains("--with-heap")
    let heapBoxes = withHeap ? BoxHeap.layout(count: 120, screens: [screen], scale: 1) : []
    crowd.setHeap(heapBoxes)
    if crowd.selfCheck(count: 6000, sheets: (0..<12).map { sprites.recolored(Skin.random(seed: $0)) } + [sprites],
                       ticks: 120, cursor: CGPoint(x: 573, y: 240), screen: screen) != nil,
       let snap = crowd.lastSnapshot {
        var rgba = snap.pixels
        if withHeap, let under = BoxHeap().snapshot(heapBoxes, scale: 1, frame: screen) {   // heap window under the crowd
            for p in stride(from: 0, to: rgba.count, by: 4) where rgba[p + 3] == 0 {
                for k in 0..<4 { rgba[p + k] = under[p + k] }
            }
        }
        for p in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(p, p + 2) }   // BGRA -> RGBA
        if let img = PixelArt.makeImage(rgba, width: snap.width, height: snap.height) {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}

// Dev helper: `Oneko --heap-png out.png [count]` draws a box heap offscreen (real GPU code).
if let i = CommandLine.arguments.firstIndex(of: "--heap-png"), i + 1 < CommandLine.arguments.count {
    let n = CommandLine.arguments.count > i + 2 ? Int(CommandLine.arguments[i + 2]) ?? 300 : 300
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    if var px = BoxHeap().snapshot(BoxHeap.layout(count: n, screens: [screen], scale: 1), scale: 1, frame: screen) {
        for p in stride(from: 0, to: px.count, by: 4) { px.swapAt(p, p + 2) }   // BGRA -> RGBA
        if let img = PixelArt.makeImage(px, width: 1440, height: 900) {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}

// Dev helper: `Oneko --export-icon out.png` writes the menu bar icon (2×) for inspection.
if let i = CommandLine.arguments.firstIndex(of: "--export-icon"), i + 1 < CommandLine.arguments.count {
    let icon = sprites.menuBarIcon()
    let rep = icon.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
    try? rep?.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// Dev helper: `Oneko --export-art out.png` draws the toys, overlays and coats, 6× size.
if let i = CommandLine.arguments.firstIndex(of: "--export-art"), i + 1 < CommandLine.arguments.count {
    let z = 6
    let ctx = CGContext(data: nil, width: 330 * z, height: 72 * z, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.setFillColor(CGColor(red: 0.55, green: 0.7, blue: 0.85, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 330 * z, height: 72 * z))
    func draw(_ img: CGImage?, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard let img else { return }
        ctx.draw(img, in: CGRect(x: x * z, y: y * z, width: w * z, height: h * z))
    }
    // Row 1: box, cat in box (back, sleeping cat, front), anger, heart, bone
    draw(PixelArt.box.image, 2, 38, 32, 32)
    draw(PixelArt.boxBack.image, 38, 38, 32, 32)
    draw(sprites.image(for: .sleeping, frame: 0), 38, 42, 32, 32)
    draw(PixelArt.boxFront.image, 38, 38, 32, 32)
    draw(sprites.image(for: .idle, frame: 0), 74, 38, 32, 32)
    draw(PixelArt.anger.image, 74 + 21, 38 + 23, 13, 13)
    draw(PixelArt.clip.image, 74 + 16 + 1 - 3, 38 + 16 + 16 - 5, 7, 11)   // clipped cat (y-up: centre + 0.5S)
    draw(PixelArt.boxClosed.image, 150, 30, 32, 32)
    draw(PixelArt.clip.image, 150 + 16 - 3, 30 + 16 + 8 + 3 - 5, 7, 11)       // clipped box
    draw(PixelArt.heart.image, 112, 50, 7, 6)
    draw(PixelArt.bone.image, 124, 50, 16, 7)
    draw(PixelArt.eating.image, 144, 50, PixelArt.eating.width, PixelArt.eating.height)
    // Hats on cats (using the head anchor), yarn, laser dot.
    for (i, hat) in [PixelArt.santaHat, PixelArt.witchHat, PixelArt.partyHat].enumerated() {
        let x0 = 150 + i * 40, y0 = 38
        let pose: SpriteName = i == 1 ? .E : .idle
        draw(sprites.image(for: pose, frame: 0), x0, y0, 32, 32)
        let a = sprites.headAnchor(pose, frame: 0)
        draw(hat.image, x0 + Int(a.x) - hat.width / 2, y0 + 32 - Int(a.y) - 2, hat.width, hat.height)
    }
    draw(PixelArt.yarn.image, 280, 44, 12, 12)
    draw(PixelArt.laserDot.image, 300, 48, 6, 6)
    // Row 2: every coat
    let painted = [CoatPattern.tabby, .patches, .tortie, .point, .galaxy].map { p -> Skin in
        let (o, f, a, a2) = p.suggested
        return Skin(id: Skin.paintedID, title: "", outline: o, fill: f, accent: a, pattern: p, accent2: a2)
    }
    for (n, skin) in (Skin.all + painted).enumerated() {
        draw(sprites.recolored(skin).image(for: .idle, frame: 0), 2 + n * 27, 2, 32, 32)
    }
    let out = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])
    try? out?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// Dev helper: `Oneko --export-toolbar out.png` renders the Toolbox panel.
if let i = CommandLine.arguments.firstIndex(of: "--export-toolbar"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let bar = ToolbarPanel()
    bar.setTool(.pencil)
    bar.setColor(RGBA(r: 255, g: 0, b: 0))
    if let v = bar.contentView {
        v.layoutSubtreeIfNeeded()
        let container = NSView(frame: v.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? out.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }
        print("toolbar content size:", v.bounds.size)
    }
    exit(0)
}

// Dev helper: `Oneko --export-about out.png` renders the About window.
if let i = CommandLine.arguments.firstIndex(of: "--export-about"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let w = AboutWindow(icon: sprites.image(for: .idle, frame: 0))
    if let v = w.contentView {
        v.layoutSubtreeIfNeeded()
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? out.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }
        print("about size:", v.bounds.size)
    }
    exit(0)
}

// Dev helper: `Oneko --export-coats dir` renders every coat pattern in a few poses
// (coats.png) and the coat painter (painter.png, light mode).
if let i = CommandLine.arguments.firstIndex(of: "--export-coats"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[i + 1]
    let poses: [(SpriteName, Int)] = [(.idle, 0), (.E, 0), (.E, 1), (.S, 0), (.N, 0), (.sleeping, 0), (.alert, 0), (.scratchSelf, 0)]
    let z = 4, rows = CoatPattern.allCases
    let ctx = CGContext(data: nil, width: poses.count * 34 * z, height: rows.count * 34 * z, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (r, p) in rows.enumerated() {
        let (o, f, a, a2) = p.suggested
        let sheet = sprites.recolored(Skin(id: Skin.paintedID, title: "", outline: o, fill: f, accent: a, pattern: p, accent2: a2,
                                           shade: p == .tabby || p == .spots))
        for (c, pose) in poses.enumerated() {
            guard let img = sheet.image(for: pose.0, frame: pose.1) else { continue }
            ctx.draw(img, in: CGRect(x: (c * 34 + 1) * z, y: ctx.height - (r + 1) * 34 * z + z, width: 32 * z, height: 32 * z))
        }
    }
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])
    try? png?.write(to: URL(fileURLWithPath: dir + "/coats.png"))

    NSApp.appearance = NSAppearance(named: .aqua)
    let delegate = AppDelegate(sprites: sprites)
    let (o, f, a, a2) = CoatPattern.patches.suggested
    let start = Skin(id: Skin.paintedID, title: "My Coat", outline: o, fill: f, accent: a, pattern: .patches, accent2: a2)
    let painter = CoatPainter(base: sprites, settings: delegate.settings, start: start)
    if let v = painter.contentView {
        v.layoutSubtreeIfNeeded()
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: v.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? out.write(to: URL(fileURLWithPath: dir + "/painter.png"))
            }
        }
        print("painter size:", v.bounds.size)
    }
    exit(0)
}

// Dev helper: `Oneko --export-settings dir` renders every Settings tab (light mode).
if let i = CommandLine.arguments.firstIndex(of: "--export-settings"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let delegate = AppDelegate(sprites: sprites)
    let pages: [SettingsPage] = [GeneralPage(), CatsPage(), NapsPage(), ToysPage(), SoundsPage(), TouchBarPage(), StatsPage()]
    for (n, p) in pages.enumerated() {
        p.app = delegate
        let v = p.view
        p.refresh()
        v.setFrameSize(v.fittingSize)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? out.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + "/settings_\(n)_\(p.title ?? "").png"))
        }
        print(p.title ?? "", v.bounds.size)
    }
    exit(0)
}

// Dev helper: `Oneko --export-iconset Dir.iconset` draws the app icon at every size:
// Neko peeking out of its box on a night-sky rounded square, pixel-sharp.
if let i = CommandLine.arguments.firstIndex(of: "--export-iconset"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func icon(_ px: Int) -> CGImage? {
        let s = CGFloat(px)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // macOS icon grid: the rounded square fills ~80% with room for its shadow.
        let body = CGRect(x: s * 0.098, y: s * 0.088, width: s * 0.804, height: s * 0.804)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.3, green: 0.25, blue: 0.7, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.47, green: 0.55, blue: 1.0, alpha: 1), CGColor(red: 0.27, green: 0.21, blue: 0.62, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        // A few pixel stars.
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        let star = max(1, (s * 0.018).rounded())
        for (fx, fy) in [(0.24, 0.78), (0.70, 0.83), (0.82, 0.66), (0.34, 0.64), (0.58, 0.72)] {
            ctx.fill(CGRect(x: (body.minX + body.width * fx).rounded(), y: (body.minY + body.height * fy).rounded(), width: star, height: star))
        }
        // The cat in its box: 32×32 pixel art, scaled up crisply.
        ctx.interpolationQuality = .none
        let art = (body.width * 0.78 / 32).rounded(.down) >= 1 ? (body.width * 0.78 / 32).rounded(.down) * 32 : body.width * 0.78
        let r = CGRect(x: (s - art) / 2, y: body.minY + body.height * 0.06, width: art, height: art)
        ctx.draw(PixelArt.boxBack.image, in: r)
        if let cat = sprites.image(for: .idle, frame: 0) {
            ctx.draw(cat, in: r.offsetBy(dx: -art * 2 / 32, dy: art * 7 / 32))   // tail tucked inside the box
        }
        ctx.draw(PixelArt.boxFront.image, in: r)
        ctx.restoreGState()
        return ctx.makeImage()
    }
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        if let img = icon(px), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
    exit(0)
}

// Dev helper: `Oneko --render-demo <dir>` renders the README demo video frames + audio.
if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    DemoRenderer(sprites: sprites, dir: CommandLine.arguments[i + 1])?.render()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate(sprites: sprites)
app.delegate = delegate
app.run()
