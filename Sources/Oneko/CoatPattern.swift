import Foundation

/// Patterns for a painted coat. Markings follow the cat's body in each frame (its outline,
/// its middle, its paws), so they stay put while it runs instead of sliding over it.
enum CoatPattern: String, CaseIterable {
    case solid, tabby, spots, patches, bicolor, tortie, tuxedo, socks, point, galaxy

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .tabby: return "Tabby"
        case .spots: return "Spotted"
        case .patches: return "Calico"
        case .bicolor: return "Bicolour"
        case .tortie: return "Tortoiseshell"
        case .tuxedo: return "Tuxedo"
        case .socks: return "Socks"
        case .point: return "Colourpoint"
        case .galaxy: return "Galaxy"
        }
    }

    var usesAccent: Bool { self != .solid }
    /// Calico's third colour (leave it off for a two-tone cat) and Galaxy's bright stars.
    var usesAccent2: Bool { self == .patches || self == .galaxy }
    var accent2Title: String { self == .galaxy ? "Bright Stars" : "Patches 2" }

    /// What the accent colour paints, for the painter's label.
    var accentTitle: String {
        switch self {
        case .solid: return "Accent"
        case .tabby: return "Stripes"
        case .spots: return "Spots"
        case .patches, .bicolor, .tortie: return "Patches"
        case .tuxedo: return "Bib & Paws"
        case .socks: return "Socks"
        case .point: return "Points"
        case .galaxy: return "Stars"
        }
    }

    /// Colours that show the pattern off, for the painter's Suggest button:
    /// (outline, fill, accent, accent 2).
    var suggested: (RGBA, RGBA, RGBA, RGBA?) {
        switch self {
        case .solid: return (RGBA(hex: "5C2E0E"), RGBA(hex: "F5A142"), RGBA(hex: "F5A142"), nil)
        case .tabby: return (RGBA(hex: "542C10"), RGBA(hex: "F09E4A"), RGBA(hex: "964618"), nil)
        case .spots: return (RGBA(hex: "46321A"), RGBA(hex: "ECCE96"), RGBA(hex: "503216"), nil)
        case .patches: return (RGBA(hex: "3C281E"), RGBA(hex: "FCF8F0"), RGBA(hex: "E88C34"), RGBA(hex: "302828"))
        case .bicolor: return (RGBA(hex: "8C8C9A"), RGBA(hex: "FAFAFA"), RGBA(hex: "2A2A30"), nil)
        case .tortie: return (RGBA(hex: "785A46"), RGBA(hex: "2E2420"), RGBA(hex: "CC6E2C"), nil)
        case .tuxedo: return (RGBA(hex: "9696A5"), RGBA(hex: "24242A"), RGBA(hex: "FAFAFA"), nil)
        case .socks: return (RGBA(hex: "542C10"), RGBA(hex: "F09E4A"), RGBA(hex: "FFFFFF"), nil)
        case .point: return (RGBA(hex: "3C281E"), RGBA(hex: "F6EAD4"), RGBA(hex: "5C4030"), nil)
        case .galaxy: return (RGBA(hex: "968CE6"), RGBA(hex: "1C183C"), RGBA(hex: "FFFFFF"), RGBA(hex: "FFD66E"))
        }
    }
}

/// What a body pixel gets painted with.
enum CoatMark: UInt8 { case fill, accent, accent2, shade }

/// One 32×32 frame of the cat, worked out once so patterns can follow its body: which
/// pixels are inside the outline, how far each is from the outline and from the middle,
/// and where tabby stripes grow in from the outline.
struct CoatBody {
    static let side = 32
    enum Kind: UInt8 { case clear, ink, fill }

    private let kind: [Kind]
    private var body = [Bool](repeating: false, count: side * side)
    /// Distance to the outline (1 = touching it), body pixels only.
    private var edge = [Int](repeating: 0, count: side * side)
    /// Distance from the middle of the cat, walking over the cat (ears, paws and tail are far).
    private var reach = [Int](repeating: 0, count: side * side)
    private var reachMax = 1
    private var stripe = [Bool](repeating: false, count: side * side)
    private var cx = 0.0, cy = 0.0
    private var top = 0, bottom = 0, left = 0, right = 0

    private static let around = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    init(kind: [Kind]) {
        let n = Self.side
        self.kind = kind
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < n && y < n }

        // Body: fill the outline doesn't let the outside reach (not the white under the "Z z").
        var outside = [Bool](repeating: false, count: n * n)
        var queue: [Int] = []
        for i in 0..<n {
            for (x, y) in [(i, 0), (i, n - 1), (0, i), (n - 1, i)] where kind[y * n + x] != .ink && !outside[y * n + x] {
                outside[y * n + x] = true
                queue.append(y * n + x)
            }
        }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for (dx, dy) in Self.around {
                let x = p % n + dx, y = p / n + dy
                guard inside(x, y), !outside[y * n + x], kind[y * n + x] != .ink else { continue }
                outside[y * n + x] = true
                queue.append(y * n + x)
            }
        }
        var pts: [Int] = []
        for i in 0..<(n * n) where kind[i] == .fill && !outside[i] {
            body[i] = true
            pts.append(i)
        }
        guard !pts.isEmpty else { return }
        cx = Double(pts.map { $0 % n }.reduce(0, +)) / Double(pts.count)
        cy = Double(pts.map { $0 / n }.reduce(0, +)) / Double(pts.count)
        top = pts.map { $0 / n }.min()!; bottom = pts.map { $0 / n }.max()!
        left = pts.map { $0 % n }.min()!; right = pts.map { $0 % n }.max()!

        func isInk(_ x: Int, _ y: Int) -> Bool { inside(x, y) && kind[y * n + x] == .ink }

        // Distance to the outline.
        queue = pts.filter { p in Self.around.contains { isInk(p % n + $0.0, p / n + $0.1) } }
        for p in queue { edge[p] = 1 }
        head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for (dx, dy) in Self.around {
                let x = p % n + dx, y = p / n + dy
                guard inside(x, y), body[y * n + x], edge[y * n + x] == 0 else { continue }
                edge[y * n + x] = edge[p] + 1
                queue.append(y * n + x)
            }
        }
        for p in pts where edge[p] == 0 { edge[p] = 1 }

        // Distance from the middle, walking over body and outline (inner lines split the body).
        let core = pts.min { a, b in
            pow(Double(a % n) - cx, 2) + pow(Double(a / n) - cy, 2) < pow(Double(b % n) - cx, 2) + pow(Double(b / n) - cy, 2)
        }!
        var seen = [Bool](repeating: false, count: n * n)
        seen[core] = true
        queue = [core]
        head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for (dx, dy) in Self.around {
                let x = p % n + dx, y = p / n + dy
                guard inside(x, y), !seen[y * n + x], body[y * n + x] || kind[y * n + x] == .ink else { continue }
                seen[y * n + x] = true
                reach[y * n + x] = reach[p] + 1
                queue.append(y * n + x)
            }
        }
        reachMax = max(1, pts.filter { seen[$0] }.map { reach[$0] }.max() ?? 1)
        for p in pts where !seen[p] { reach[p] = reachMax }

        // Tabby stripes: short strokes growing in from the outline on the back, head and
        // sides (not from the ground), every third pixel along it.
        var outer = [Bool](repeating: false, count: n * n)
        for i in 0..<(n * n) where kind[i] == .ink {
            outer[i] = Self.around.contains { dx, dy in
                let x = i % n + dx, y = i / n + dy
                return !inside(x, y) || (kind[y * n + x] != .ink && !body[y * n + x])
            }
        }
        let ox = Int(cx.rounded()), oy = Int(cy.rounded())
        for p in pts where edge[p] == 1 {
            let x = p % n, y = p / n
            for (dx, dy) in [(0, -1), (-1, 0), (1, 0)] where inside(x + dx, y + dy) && outer[(y + dy) * n + x + dx] {
                let along = dy != 0 ? x - ox : y - oy
                guard ((along % 3) + 3) % 3 == 0 else { continue }
                let length = Self.hash(x, y, 77) > 0.4 ? 3 : 2
                for k in 0..<length {
                    let sx = x - dx * k, sy = y - dy * k
                    guard inside(sx, sy), body[sy * n + sx] else { break }
                    stripe[sy * n + sx] = true
                }
            }
        }
    }

    func isBody(_ x: Int, _ y: Int) -> Bool { body[y * Self.side + x] }

    /// The mark for body pixel (x, y), top-left origin.
    func mark(_ pattern: CoatPattern, x: Int, y: Int, shade: Bool) -> CoatMark {
        let m = patternMark(pattern, x: x, y: y)
        if m == .fill, shade, edge[y * Self.side + x] == 1, isInk(x + 1, y) || isInk(x, y + 1) { return .shade }
        return m
    }

    private func isInk(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < Self.side && y < Self.side && kind[y * Self.side + x] == .ink
    }

    private func patternMark(_ pattern: CoatPattern, x: Int, y: Int) -> CoatMark {
        let n = Self.side, i = y * n + x
        let u = Double(x - left) / Double(max(1, right - left))
        let v = Double(y - top) / Double(max(1, bottom - top))
        // Body-relative coordinates, so noise patterns ride along with the cat.
        let bx = Double(x) - cx + 50, by = Double(y) - cy + 50
        switch pattern {
        case .solid:
            return .fill
        case .tabby:
            return stripe[i] ? .accent : .fill
        case .spots:
            guard edge[i] >= 2 else { return .fill }
            let rx = x - Int(cx.rounded()) + 40, ry = y - Int(cy.rounded()) + 40
            let gx = rx / 4, gy = ry / 4
            guard Self.hash(gx, gy, 3) >= 0.35 else { return .fill }
            let lx = rx - gx * 4 - Int(Self.hash(gx, gy, 1) * 2), ly = ry - gy * 4 - Int(Self.hash(gx, gy, 2) * 2)
            let hit = (0...1).contains(lx) && (0...1).contains(ly) && !(lx == 1 && ly == 1 && Self.hash(gx, gy, 4) < 0.5)
            return hit ? .accent : .fill
        case .patches, .bicolor:
            if v > 0.72 && abs(u - 0.5) < 0.3 { return .fill }                 // pale belly
            let a = Self.noise(bx, by, scale: 8, seed: 21)
            if pattern == .bicolor { return a > 0.52 ? .accent : .fill }
            if a > 0.62 { return .accent }
            return Self.noise(bx, by, scale: 8, seed: 33) > 0.64 ? .accent2 : .fill
        case .tortie:
            let t = Self.noise(bx, by, scale: 2.5, seed: 5) * 0.7 + Self.noise(bx, by, scale: 6, seed: 6) * 0.3
            return t > 0.56 || (t > 0.5 && (x + y) % 2 == 0) ? .accent : .fill
        case .tuxedo:
            let chest = v > 0.45 && abs(u - 0.5) < 0.12 + (v - 0.45) * 0.5
            let paws = bottom - y <= 1 || (isInk(x, y + 1) && bottom - y <= 3 && !(y + 1 < n && body[i + n]))
            return chest || paws ? .accent : .fill
        case .socks:
            for k in 1...2 where y + k < n && kind[(y + k) * n + x] == .ink
                && (y + k + 1 >= n || kind[(y + k + 1) * n + x] != .fill) {
                return v > 0.55 ? .accent : .fill
            }
            return .fill
        case .point:
            let t = Double(reach[i]) / Double(reachMax), from = 0.58
            if t > from + 0.08 { return .accent }
            return t > from && Double(Self.bayer[y % 4][x % 4]) < (t - from) / 0.08 * 16 ? .accent : .fill
        case .galaxy:
            if Self.hash(x, y, 99) > 0.93 && edge[i] >= 2 { return .accent }
            return Self.hash(x, y, 98) > 0.985 ? .accent2 : .fill
        }
    }

    private static let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    /// 0..<1, always the same for the same inputs.
    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 982_451_653)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    /// Smooth value noise, 0...1.
    static func noise(_ x: Double, _ y: Double, scale: Double, seed: Int) -> Double {
        let fx = x / scale, fy = y / scale
        let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
        var tx = fx - Double(ix), ty = fy - Double(iy)
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed)
        let c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }
}

extension RGBA {
    /// An outline that stands out against this fill: lighter for dark coats, darker for light ones.
    var contrastingOutline: RGBA {
        let lum = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
        func ch(_ c: UInt8) -> UInt8 {
            lum < 0.4 ? UInt8(Double(c) + (255 - Double(c)) * 0.6) : UInt8(Double(c) * 0.3)
        }
        return RGBA(r: ch(r), g: ch(g), b: ch(b))
    }

    /// This colour, a little darker (soft shading).
    var shaded: RGBA { RGBA(r: UInt8(Double(r) * 0.82), g: UInt8(Double(g) * 0.82), b: UInt8(Double(b) * 0.82), a: a) }
}
