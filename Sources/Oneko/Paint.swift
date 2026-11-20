import CoreGraphics

/// The classic Paint toolbox (plus a pointer for normal play), with macOS SF Symbols.
enum PaintTool: Int, CaseIterable {
    case pointer
    case freeSelect, select, eraser, fill, pickColor, magnifier, pencil, brush
    case airbrush, text, line, curve, rectangle, polygon, ellipse, roundedRect

    var title: String {
        switch self {
        case .pointer: return "Pointer: pet, drag and throw"
        case .freeSelect: return "Free-Form Select: lasso Neko to pick him up"
        case .select: return "Select: box Neko in to pick him up"
        case .eraser: return "Eraser: rub out drawings (and fade Neko)"
        case .fill: return "Fill With Color: paint Neko or a shape"
        case .pickColor: return "Pick Color"
        case .magnifier: return "Magnifier: click Neko to make him huge (right-click: normal)"
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .airbrush: return "Airbrush"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve: drag a line, then drag again to bend it"
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon: click corners, double-click to finish"
        case .ellipse: return "Ellipse"
        case .roundedRect: return "Rounded Rectangle"
        }
    }

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .freeSelect: return "lasso"
        case .select: return "rectangle.dashed"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .pickColor: return "eyedropper"
        case .magnifier: return "plus.magnifyingglass"
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed"
        case .airbrush: return "aqi.medium"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .rectangle: return "rectangle"
        case .polygon: return "pentagon"
        case .ellipse: return "oval"
        case .roundedRect: return "app"
        }
    }

    /// The 16-colour Paint palette.
    static let palette: [RGBA] = [
        RGBA(r: 0, g: 0, b: 0), RGBA(r: 128, g: 128, b: 128), RGBA(r: 128, g: 0, b: 0), RGBA(r: 128, g: 128, b: 0),
        RGBA(r: 0, g: 128, b: 0), RGBA(r: 0, g: 128, b: 128), RGBA(r: 0, g: 0, b: 128), RGBA(r: 128, g: 0, b: 128),
        RGBA(r: 255, g: 255, b: 255), RGBA(r: 192, g: 192, b: 192), RGBA(r: 255, g: 0, b: 0), RGBA(r: 255, g: 255, b: 0),
        RGBA(r: 0, g: 255, b: 0), RGBA(r: 0, g: 255, b: 255), RGBA(r: 0, g: 0, b: 255), RGBA(r: 255, g: 0, b: 255),
    ]
}

/// Something drawn on the screen. Everything except airbrush spray is solid: thrown things
/// bounce off it and land on it.
struct Drawing: Equatable {
    enum Kind: Equatable { case stroke, line, curve, rectangle, ellipse, roundedRect, polygon, text(String), spray }

    /// Negative, so physics can tell drawings from window ids.
    var id: Int
    var kind: Kind
    /// Outline in global y-up points (spray: the dots).
    var points: [CGPoint]
    var closed: Bool
    var color: RGBA
    var fill: RGBA? = nil
    var width: CGFloat = 3

    var solid: Bool { kind != .spray }

    var segments: [(CGPoint, CGPoint)] {
        guard solid, points.count >= 2 else { return [] }
        var s = zip(points, points.dropFirst()).map { ($0, $1) }
        if closed, let f = points.first, let l = points.last { s.append((l, f)) }
        return s
    }

    var bounds: CGRect {
        guard let f = points.first else { return .null }
        return points.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -width, dy: -width)
    }

    /// Inside a closed shape (or a text block)?
    func contains(_ p: CGPoint) -> Bool {
        guard closed, points.count >= 3 else { return false }
        return Geometry.polygon(points, contains: p)
    }

    func isNear(_ p: CGPoint, within r: CGFloat) -> Bool {
        if kind == .spray { return points.contains { hypot($0.x - p.x, $0.y - p.y) <= r } }
        if points.count == 1, let q = points.first { return hypot(q.x - p.x, q.y - p.y) <= r + width / 2 }
        return segments.contains { Geometry.distance(p, $0.0, $0.1) <= r + width / 2 } || contains(p)
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    static func polygon(_ poly: [CGPoint], contains p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func rectangle(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func ellipse(_ r: CGRect, steps: Int = 36) -> [CGPoint] {
        (0..<steps).map { i in
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            return CGPoint(x: r.midX + cos(t) * r.width / 2, y: r.midY + sin(t) * r.height / 2)
        }
    }

    static func roundedRect(_ r: CGRect) -> [CGPoint] {
        let rad = min(16, r.width / 4, r.height / 4)
        var pts: [CGPoint] = []
        let corners = [(CGPoint(x: r.maxX - rad, y: r.minY + rad), -CGFloat.pi / 2),
                       (CGPoint(x: r.maxX - rad, y: r.maxY - rad), 0),
                       (CGPoint(x: r.minX + rad, y: r.maxY - rad), CGFloat.pi / 2),
                       (CGPoint(x: r.minX + rad, y: r.minY + rad), CGFloat.pi)]
        for (c, start) in corners {
            for k in 0...5 {
                let t = start + CGFloat(k) / 5 * .pi / 2
                pts.append(CGPoint(x: c.x + cos(t) * rad, y: c.y + sin(t) * rad))
            }
        }
        return pts
    }

    /// Quadratic Bézier from a to b, bent towards c.
    static func curve(_ a: CGPoint, _ b: CGPoint, control c: CGPoint, steps: Int = 24) -> [CGPoint] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
    }
}
