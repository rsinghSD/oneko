import CoreGraphics
import Foundation

struct RGBA: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// "RRGGBB".
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
}

/// A small piece of pixel art: an image plus its opacity mask for hit testing.
struct Art {
    let image: CGImage
    let width: Int
    let height: Int
    private let mask: [Bool]

    init(width: Int, height: Int, pixels: [RGBA?]) {
        self.width = width
        self.height = height
        mask = pixels.map { ($0?.a ?? 0) > 0 }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            guard let p else { continue }
            let a = UInt16(p.a)   // premultiply
            bytes[i * 4] = UInt8(UInt16(p.r) * a / 255)
            bytes[i * 4 + 1] = UInt8(UInt16(p.g) * a / 255)
            bytes[i * 4 + 2] = UInt8(UInt16(p.b) * a / 255)
            bytes[i * 4 + 3] = p.a
        }
        image = PixelArt.makeImage(bytes, width: width, height: height)!
    }

    /// First row with any painted pixel (for placing things on top of the art).
    var topRow: Int { (0..<height).first { y in (0..<width).contains { isOpaque(x: $0, y: y) } } ?? 0 }

    /// x, y in art pixels from the top-left.
    func isOpaque(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return mask[y * width + x]
    }
}

enum PixelArt {
    static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = bytes
        return copy.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    static func fromRows(_ rows: [String], palette: [Character: RGBA]) -> Art {
        let w = rows.map(\.count).max() ?? 0
        var px: [RGBA?] = []
        for row in rows {
            let chars = Array(row)
            for x in 0..<w { px.append(x < chars.count ? palette[chars[x]] : nil) }
        }
        return Art(width: w, height: rows.count, pixels: px)
    }

    // MARK: - Overlays

    /// 💢 — the manga anger mark, for yeeted / bonked cats.
    static let anger = fromRows([
        "   R     R   ",
        "   RR   RR   ",
        "    R   R    ",
        "RR  R   R  RR",
        " RRRR   RRRR ",
        "             ",
        "             ",
        "             ",
        " RRRR   RRRR ",
        "RR  R   R  RR",
        "    R   R    ",
        "   RR   RR   ",
        "   R     R   ",
    ], palette: ["R": RGBA(r: 232, g: 44, b: 56)])

    /// A little wooden clothespin, for things clipped in mid-air.
    static let clip = fromRows([
        "  K K  ",
        " KwKwK ",
        " KwKwK ",
        " KwKwK ",
        "KKKKKKK",
        "KyyyyyK",
        "KKKKKKK",
        " KwKwK ",
        " KwKwK ",
        "  KwK  ",
        "   K   ",
    ], palette: ["K": RGBA(r: 92, g: 60, b: 30), "w": RGBA(r: 226, g: 180, b: 122), "y": RGBA(r: 196, g: 198, b: 208)])

    /// A ball of yarn: rolls, bounces, and gets batted around.
    static let yarn = fromRows([
        "    ####    ",
        "  ##oo/o##  ",
        " #oo/oo/oo# ",
        " #o/oo/oo/# ",
        "#oo/oo/oo/o#",
        "#o/oo/oo/oo#",
        "#/oo/oo/oo/#",
        "#oo/oo/oo/o#",
        " #/oo/oo/o# ",
        " #oo/oo/oo# ",
        "  ##o/oo##  ",
        "    ####  ##",
    ], palette: ["#": RGBA(r: 140, g: 30, b: 52), "o": RGBA(r: 226, g: 82, b: 104), "/": RGBA(r: 250, g: 172, b: 184)])

    /// The laser pointer's dot.
    static let laserDot = fromRows([
        " rRRr ",
        "rRWWRr",
        "RWWWWR",
        "RWWWWR",
        "rRWWRr",
        " rRRr ",
    ], palette: ["r": RGBA(r: 255, g: 40, b: 40, a: 110), "R": RGBA(r: 255, g: 30, b: 30), "W": RGBA(r: 255, g: 190, b: 190)])

    // MARK: - Hats (bottom-centre sits on top of the head)

    static let santaHat = fromRows([
        "         ww ",
        "        wwww",
        "       RRww ",
        "      RRRR  ",
        "     RRRRR  ",
        "    RRRRRR  ",
        "   RRRRRRRR ",
        "  WWWWWWWWWW",
        "  WWWWWWWWWW",
    ], palette: ["R": RGBA(r: 214, g: 38, b: 46), "w": RGBA(r: 250, g: 250, b: 250), "W": RGBA(r: 236, g: 236, b: 242)])

    static let witchHat = fromRows([
        "     KK     ",
        "    KPPK    ",
        "    KPPK    ",
        "   KPPPPK   ",
        "   KPPPPK   ",
        "  KYYYYYYK  ",
        "  KPPPPPPK  ",
        "KKKKKKKKKKKK",
        "KKKKKKKKKKKK",
    ], palette: ["K": RGBA(r: 42, g: 20, b: 64), "P": RGBA(r: 112, g: 52, b: 164), "Y": RGBA(r: 242, g: 190, b: 40)])

    static let partyHat = fromRows([
        "     yy     ",
        "     yy     ",
        "     BB     ",
        "    BPPB    ",
        "    PBBP    ",
        "   BPPPPB   ",
        "   PBBBBP   ",
        "  BPPPPPPB  ",
        "  PBBBBBBP  ",
    ], palette: ["B": RGBA(r: 60, g: 140, b: 232), "P": RGBA(r: 240, g: 90, b: 170), "y": RGBA(r: 250, g: 214, b: 50)])

    static let heart = fromRows([
        " PP PP ",
        "PwPPPPP",
        "PPPPPPP",
        " PPPPP ",
        "  PPP  ",
        "   P   ",
    ], palette: ["P": RGBA(r: 255, g: 84, b: 132), "w": RGBA(r: 255, g: 214, b: 226)])

    static let bone = fromRows([
        " ##          ## ",
        "#oo#        #oo#",
        "#ooo########ooo#",
        " #oooooooooooo# ",
        "#ooo########ooo#",
        "#oo#        #oo#",
        " ##          ## ",
    ], palette: ["#": RGBA(r: 0, g: 0, b: 0), "o": RGBA(r: 255, g: 255, b: 255)])

    // MARK: - Food bowl

    private static let bowlPalette: [Character: RGBA] = [
        "#": RGBA(r: 30, g: 60, b: 110), "b": RGBA(r: 70, g: 130, b: 220), "l": RGBA(r: 140, g: 190, b: 250),
        "f": RGBA(r: 176, g: 108, b: 54), "d": RGBA(r: 120, g: 70, b: 32),
    ]
    /// A food bowl full of kibble...
    static let bowlFull = fromRows([
        "   ffdffdfffd   ",
        "  fdffffdfffdf  ",
        " ############## ",
        "#llllllllllllll#",
        "#bbbbbbbbbbbbbb#",
        " #bbbbbbbbbbbb# ",
        "  ############  ",
    ], palette: bowlPalette)
    /// ...and licked clean.
    static let bowlEmpty = fromRows([
        "                ",
        "                ",
        " ############## ",
        "#llllllllllllll#",
        "#bbbbbbbbbbbbbb#",
        " #bbbbbbbbbbbb# ",
        "  ############  ",
    ], palette: bowlPalette)

    // MARK: - Cardboard box (32×32, same grid as a cat sprite)

    private static let ink = RGBA(r: 74, g: 47, b: 24)
    private static let flap = RGBA(r: 232, g: 182, b: 122)
    private static let face = RGBA(r: 217, g: 160, b: 102)
    private static let shade = RGBA(r: 185, g: 132, b: 77)
    private static let inside = RGBA(r: 112, g: 74, b: 42)

    /// Drawn behind the cat: flaps and the dark inside.
    static let boxBack = Art(width: 32, height: 32, pixels: boxBackPixels)

    /// Drawn in front of the cat, so only its head pokes out.
    static let boxFront = Art(width: 32, height: 32, pixels: boxFrontPixels)

    /// Flaps folded shut, with a strip of tape.
    static let boxClosed: Art = {
        var c = Canvas(32, 32)
        c.shape([(2, 19), (31, 19), (28, 11), (5, 11)], fill: flap, outline: ink)   // lid
        for y in 12...18 { c.set(16, y, shade); c.set(17, y, shade) }               // tape
        var px = c.px
        for (i, p) in boxFrontPixels.enumerated() where p != nil { px[i] = p }
        return Art(width: 32, height: 32, pixels: px)
    }()

    /// The whole box, for when the cat isn't in it.
    static let box: Art = {
        var px = [RGBA?](repeating: nil, count: 32 * 32)
        for y in 0..<32 {
            for x in 0..<32 {
                px[y * 32 + x] = boxFront.isOpaque(x: x, y: y) ? boxFrontPixels[y * 32 + x]
                    : boxBackPixels[y * 32 + x]
            }
        }
        return Art(width: 32, height: 32, pixels: px)
    }()

    private static let boxBackPixels: [RGBA?] = {
        var c = Canvas(32, 32)
        c.shape([(6, 14), (26, 14), (28, 8), (8, 8)], fill: flap, outline: ink)       // back flap
        c.shape([(2, 19), (5, 14), (1, 8), (-1, 14)], fill: flap, outline: ink)      // left flap
        c.shape([(31, 19), (27, 14), (31, 8), (33, 14)], fill: flap, outline: ink)   // right flap
        c.shape([(2, 19), (5, 14), (27, 14), (31, 19)], fill: inside, outline: ink)  // opening
        return c.px
    }()

    private static let boxFrontPixels: [RGBA?] = {
        var c = Canvas(32, 32)
        c.shape([(2, 18), (31, 18), (31, 31), (2, 31)], fill: face, outline: ink)
        for x in 3...29 { c.set(x, 19, shade) }
        for x in 13...18 { c.set(x, 23, inside); c.set(x, 24, inside) }
        c.set(12, 23, ink); c.set(19, 23, ink); c.set(12, 24, ink); c.set(19, 24, ink)
        return c.px
    }()
}

/// Tiny rasteriser: filled polygons with a 1 px outline, top-left origin.
struct Canvas {
    let w: Int, h: Int
    var px: [RGBA?]

    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        px = Array(repeating: nil, count: w * h)
    }

    mutating func set(_ x: Int, _ y: Int, _ c: RGBA) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        px[y * w + x] = c
    }

    mutating func shape(_ poly: [(CGFloat, CGFloat)], fill: RGBA, outline: RGBA) {
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where Self.inside(CGFloat(x) + 0.5, CGFloat(y) + 0.5, poly) {
                mask[y * w + x] = true
            }
        }
        func m(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] }
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                let edge = !m(x - 1, y) || !m(x + 1, y) || !m(x, y - 1) || !m(x, y + 1)
                px[y * w + x] = edge ? outline : fill
            }
        }
    }

    var art: Art { Art(width: w, height: h, pixels: px) }

    private static func inside(_ x: CGFloat, _ y: CGFloat, _ poly: [(CGFloat, CGFloat)]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let (xi, yi) = poly[i], (xj, yj) = poly[j]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { result.toggle() }
            j = i
        }
        return result
    }
}
