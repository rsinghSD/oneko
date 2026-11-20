import AppKit

/// Patterns for a painted coat, applied to the fill.
enum CoatPattern: String, CaseIterable {
    case solid, tabby, spots, patches, tuxedo, socks
    var title: String { rawValue.capitalized }

    /// Does this (cell-local, top-left origin) pixel get the accent colour?
    func accent(x: Int, y: Int) -> Bool {
        switch self {
        case .solid: return false
        case .tabby: return x % 5 < 2
        case .spots:
            let h = ((x / 4) &* 73856093) ^ ((y / 4) &* 19349663)
            return abs(h) % 5 == 0 && (x % 4 != 3) && (y % 4 != 3)
        case .patches: return sin(Double(x) * 0.45 + 1.3) * cos(Double(y) * 0.38) > 0.35
        case .tuxedo: return y >= 22 || (y >= 16 && abs(x - 16) < 4)
        case .socks: return y >= 26
        }
    }
}

/// Coat colours, made by recolouring the classic sheet's outline and fill.
struct Skin {
    let id: String
    let title: String
    let outline: RGBA
    let fill: RGBA
    var accent: RGBA? = nil
    var pattern: CoatPattern = .solid

    static let classicID = "classic"
    static let customID = "custom"
    static let paintedID = "painted"

    static let all: [Skin] = [
        Skin(id: classicID, title: "Classic", outline: RGBA(r: 0, g: 0, b: 0), fill: RGBA(r: 255, g: 255, b: 255)),
        Skin(id: "midnight", title: "Midnight", outline: RGBA(r: 236, g: 236, b: 242), fill: RGBA(r: 26, g: 26, b: 32)),
        Skin(id: "ginger", title: "Ginger", outline: RGBA(r: 92, g: 46, b: 14), fill: RGBA(r: 245, g: 161, b: 66)),
        Skin(id: "gray", title: "Gray", outline: RGBA(r: 40, g: 43, b: 48), fill: RGBA(r: 168, g: 173, b: 180)),
        Skin(id: "cream", title: "Cream", outline: RGBA(r: 107, g: 79, b: 42), fill: RGBA(r: 243, g: 224, b: 192)),
        Skin(id: "sakura", title: "Sakura", outline: RGBA(r: 122, g: 46, b: 74), fill: RGBA(r: 255, g: 198, b: 217)),
        Skin(id: "ghost", title: "Ghost", outline: RGBA(r: 120, g: 160, b: 220, a: 230), fill: RGBA(r: 255, g: 255, b: 255, a: 110)),
    ]
}

/// The 256×128 oneko sheet: 8×4 frames of 32×32.
final class SpriteSheet {
    static let cellSize = 32

    private let sheet: CGImage
    private let width: Int
    /// Premultiplied RGBA8, top row first.
    private let pixels: [UInt8]
    private var cache: [Int: CGImage] = [:]

    private init(sheet: CGImage, pixels: [UInt8], width: Int) {
        self.sheet = sheet
        self.pixels = pixels
        self.width = width
    }

    /// Loads a 256×128 PNG/GIF sheet in the classic layout; nil if missing or the wrong size.
    static func load(url: URL) -> SpriteSheet? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width == 256, cg.height == 128
        else { return nil }
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn: CGImage? = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return ctx.makeImage()
        }
        guard let rgba = drawn else { return nil }
        return SpriteSheet(sheet: rgba, pixels: buf, width: cg.width)
    }

    static func load() -> SpriteSheet? {
        let candidates = [
            Bundle.main.url(forResource: "oneko", withExtension: "gif"),
            URL(fileURLWithPath: "Resources/oneko.gif"),   // `swift run` from the package folder
        ]
        for case let url? in candidates {
            if let s = load(url: url) { return s }
        }
        return nil
    }

    /// Same sheet with the black outline and white fill swapped for a skin's colours.
    func recolored(_ skin: Skin) -> SpriteSheet {
        guard skin.id != Skin.classicID else { return self }
        var out = [UInt8](repeating: 0, count: pixels.count)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 127 {
            let ink = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 384
            let px = (i / 4) % width, py = (i / 4) / width
            let c = ink ? skin.outline
                : (skin.accent != nil && skin.pattern.accent(x: px % 32, y: py % 32) ? skin.accent! : skin.fill)
            let a = UInt16(c.a)
            out[i] = UInt8(UInt16(c.r) * a / 255)
            out[i + 1] = UInt8(UInt16(c.g) * a / 255)
            out[i + 2] = UInt8(UInt16(c.b) * a / 255)
            out[i + 3] = c.a
        }
        let img = PixelArt.makeImage(out, width: width, height: pixels.count / 4 / width) ?? sheet
        return SpriteSheet(sheet: img, pixels: out, width: width)
    }

    func image(col: Int, row: Int) -> CGImage? {
        let key = row * 8 + col
        if let hit = cache[key] { return hit }
        let s = Self.cellSize
        let img = sheet.cropping(to: CGRect(x: col * s, y: row * s, width: s, height: s))
        cache[key] = img
        return img
    }

    func image(for name: SpriteName, frame: Int) -> CGImage? {
        let c = name.cell(at: frame)
        return image(col: c.col, row: c.row)
    }

    /// Is pixel (x, y) of a frame (top-left origin, 0..<32) painted? Used to make only the
    /// cat itself clickable.
    func isOpaque(_ name: SpriteName, frame: Int, x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < Self.cellSize, y < Self.cellSize else { return false }
        let c = name.cell(at: frame)
        let px = c.col * Self.cellSize + x, py = c.row * Self.cellSize + y
        return pixels[(py * width + px) * 4 + 3] > 40
    }

    /// Where a hat goes on a frame: the top of the head, in cell pixels (top-left origin).
    func headAnchor(_ name: SpriteName, frame: Int) -> CGPoint {
        let c = name.cell(at: frame)
        let key = c.row * 8 + c.col
        if let a = anchors[key] { return a }
        var a: CGPoint
        if name == .sleeping {
            a = CGPoint(x: 20, y: 15)                    // curled up: skip the "Z z" above it
        } else {
            a = CGPoint(x: 16, y: 3)
            // Look only on the side the cat faces, so a raised tail doesn't get the hat.
            let dir = name.rawValue
            let cols: Range<Int> = dir.hasSuffix("E") ? 14..<32 : dir.hasSuffix("W") ? 0..<18 : 0..<32
            outer: for y in 0..<Self.cellSize {
                var xs: [Int] = []
                for x in cols where pixels[((c.row * 32 + y) * width + c.col * 32 + x) * 4 + 3] > 127 { xs.append(x) }
                if !xs.isEmpty {
                    a = CGPoint(x: CGFloat(xs.reduce(0, +)) / CGFloat(xs.count), y: CGFloat(y) + 1)
                    break outer
                }
            }
        }
        anchors[key] = a
        return a
    }
    private var anchors: [Int: CGPoint] = [:]

    /// True for the dark outline pixels of the sprite art.
    private func isInk(x: Int, y: Int) -> Bool {
        let i = (y * width + x) * 4
        return pixels[i + 3] > 127 && Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 384
    }

    /// The neko face, drawn pixel-for-pixel from the idle sprite as a template image so
    /// macOS tints it for light/dark menu bars (and the Touch Bar). One sprite pixel = one point.
    func menuBarIcon() -> NSImage {
        let origin = (x: 3 * 32 + 9, y: 3 * 32 + 3)   // head of the sitting cat: ears to chin
        let side = 15
        let icon = NSImage(size: NSSize(width: side, height: side))
        for scale in [1, 2] {
            let px = side * scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = NSSize(width: side, height: side)
            let data = rep.bitmapData!
            let stride = rep.bytesPerRow
            for y in 0..<px {
                for x in 0..<px {
                    let ink = isInk(x: origin.x + x / scale, y: origin.y + y / scale)
                    let i = y * stride + x * 4
                    data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
                    data[i + 3] = ink ? 255 : 0
                }
            }
            icon.addRepresentation(rep)
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Oneko"
        return icon
    }
}
