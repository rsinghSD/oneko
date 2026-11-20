import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

guard let sprites = SpriteSheet.load() else {
    FileHandle.standardError.write("Oneko: could not load oneko.gif\n".data(using: .utf8)!)
    exit(1)
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
    let painted = [CoatPattern.tabby, .spots, .patches, .tuxedo, .socks].map {
        Skin(id: Skin.paintedID, title: "", outline: RGBA(r: 40, g: 30, b: 20),
             fill: $0 == .tuxedo ? RGBA(r: 30, g: 30, b: 36) : RGBA(r: 245, g: 161, b: 66),
             accent: $0 == .tuxedo || $0 == .socks ? RGBA(r: 250, g: 250, b: 250) : RGBA(r: 150, g: 80, b: 30), pattern: $0)
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

// Dev helper: `Oneko --export-settings dir` renders every Settings tab (light mode).
if let i = CommandLine.arguments.firstIndex(of: "--export-settings"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let delegate = AppDelegate(sprites: sprites)
    let pages: [SettingsPage] = [GeneralPage(), NapsPage(), ToysPage(), SoundsPage(), TouchBarPage(), StatsPage()]
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate(sprites: sprites)
app.delegate = delegate
app.run()
