import CoreGraphics

struct ScreenInfo: Equatable {
    var frame: CGRect
    /// Frame minus the menu bar and the Dock.
    var visible: CGRect
    /// The Dock on this display while it's showing (nil when hidden or elsewhere): the Dock
    /// itself, from the bottom (or side) of the display to its top, not the whole strip.
    var dock: CGRect? = nil

    /// What falling things land on at `x`: the top of a showing bottom Dock, or beside it
    /// the real bottom of the display.
    func floor(at x: CGFloat) -> CGFloat {
        if let d = dock, d.minY <= frame.minY + 1, d.width >= d.height {
            return x >= d.minX && x <= d.maxX ? d.maxY : frame.minY
        }
        return visible.minY
    }

    /// The Dock as no floor at all: cats and toys walk and land on the real bottom (or side)
    /// of the display, in front of the Dock.
    var dockIgnored: ScreenInfo {
        guard let d = dock else { return self }
        var v = visible
        if d.minY <= frame.minY + 1 && d.width >= d.height {          // bottom Dock
            v = CGRect(x: v.minX, y: frame.minY, width: v.width, height: v.maxY - frame.minY)
        } else if d.minX <= frame.minX + 1 {                           // left Dock
            v = CGRect(x: frame.minX, y: v.minY, width: v.maxX - frame.minX, height: v.height)
        } else if d.maxX >= frame.maxX - 1 {                           // right Dock
            v = CGRect(x: v.minX, y: v.minY, width: frame.maxX - v.minX, height: v.height)
        }
        return ScreenInfo(frame: frame, visible: v, dock: nil)
    }
}

struct WindowInfo: Equatable {
    var id: Int
    var pid: Int32
    /// Global, y-up.
    var frame: CGRect
}

/// A snapshot of the desktop, refreshed 10×/s. Pure data so the playground can be tested headless.
struct World {
    var screens: [ScreenInfo]
    /// On-screen app windows, frontmost first.
    var windows: [WindowInfo]
    /// Where this cat is headed (your cursor, or its spot in a swarm or conga line).
    var cursor: CGPoint
    var mouseDown = false
    /// Your actual cursor, when `cursor` is something else (bones come back to you).
    var pointer: CGPoint? = nil
    var frontmostPID: Int32 = 0
    /// Toolbox drawings (solid ones are physical).
    var drawings: [Drawing] = []

    func drawing(_ id: Int) -> Drawing? { drawings.first { $0.id == id } }

    /// This world with the Dock treated as not there (Settings › Behavior › Dock: on the ground).
    func ignoringDock() -> World {
        var w = self
        w.screens = screens.map(\.dockIgnored)
        return w
    }

    var screenFrames: [CGRect] { screens.map(\.frame) }

    func screen(containing p: CGPoint) -> ScreenInfo? {
        screens.first { $0.frame.contains(p) }
    }

    func nearestScreen(to p: CGPoint) -> ScreenInfo? {
        func d(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { d($0.frame) < d($1.frame) }
    }

    func window(_ id: Int) -> WindowInfo? {
        windows.first { $0.id == id }
    }

    /// Is `p` hidden behind any window in front of `windows[index]`?
    func isCovered(_ p: CGPoint, inFrontOf index: Int) -> Bool {
        windows.prefix(index).contains { $0.frame.contains(p) }
    }

    /// Displays the frontmost app fills edge to edge (full-screen Spaces, videos, games).
    var fullScreenDisplays: [CGRect] {
        screenFrames.filter { s in
            windows.contains { w in
                w.pid == frontmostPID
                    && abs(w.frame.minX - s.minX) < 1 && abs(w.frame.minY - s.minY) < 1
                    && abs(w.frame.width - s.width) < 1 && abs(w.frame.height - s.height) < 1
            }
        }
    }
}

/// Collision size of a thrown thing. `foot` is the transparent gap under the art.
struct Shape: Equatable {
    var halfW: CGFloat
    var halfH: CGFloat
    var foot: CGFloat
    var bounce: CGFloat
    /// A ball: it keeps rolling along the ground instead of stopping dead.
    var rolls = false
}

struct Body: Equatable {
    var pos: CGPoint
    var vel = CGVector.zero
    var angle: CGFloat = 0
    var spin: CGFloat = 0
    var airTime: CGFloat = 0
}

enum StepResult: Equatable {
    case flying
    case bounced(impact: CGFloat)
    case rested(onWindow: Int?, impact: CGFloat)
}

/// Gravity, bounces and landings. Things land on the Dock / bottom of a display, or on the
/// top edge of any window whose title bar is visible there.
enum Physics {
    static let gravity: CGFloat = 2200
    static let maxSpeed: CGFloat = 7000

    static func clampSpeed(_ v: CGVector, max m: CGFloat = maxSpeed) -> CGVector {
        let s = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard s > m else { return v }
        return CGVector(dx: v.dx / s * m, dy: v.dy / s * m)
    }

    /// `inside`: a window it was dropped into: its inside bottom edge is a floor and its sides
    /// are walls (until it leaves through the top).
    static func step(_ b: inout Body, shape: Shape, dt: CGFloat, world: World, inside: Int? = nil) -> StepResult {
        guard let cur = world.screen(containing: b.pos) ?? world.nearestScreen(to: b.pos) else { return .flying }
        b.airTime += dt
        b.vel.dy -= gravity * dt
        let drag = max(0, 1 - 0.3 * dt)
        b.vel.dx *= drag
        b.vel.dy *= drag
        b.angle += b.spin * dt
        var next = CGPoint(x: b.pos.x + b.vel.dx * dt, y: b.pos.y + b.vel.dy * dt)

        // Side walls and ceiling, except where another display continues.
        let f = cur.frame
        if next.x - shape.halfW < f.minX,
           world.screen(containing: CGPoint(x: next.x - shape.halfW, y: next.y)) == nil {
            next.x = f.minX + shape.halfW
            b.vel.dx = abs(b.vel.dx) * 0.6
            b.spin = -b.spin * 0.7
        }
        if next.x + shape.halfW > f.maxX,
           world.screen(containing: CGPoint(x: next.x + shape.halfW, y: next.y)) == nil {
            next.x = f.maxX - shape.halfW
            b.vel.dx = -abs(b.vel.dx) * 0.6
            b.spin = -b.spin * 0.7
        }
        if next.y + shape.halfH > f.maxY,
           world.screen(containing: CGPoint(x: next.x, y: next.y + shape.halfH)) == nil {
            next.y = f.maxY - shape.halfH
            b.vel.dy = -abs(b.vel.dy) * 0.5
        }

        // Dropped into a window: its sides keep it in, its bottom edge catches it.
        var innerFloor: (y: CGFloat, id: Int)?
        if let id = inside, let w = world.window(id)?.frame, next.y - shape.halfH < w.maxY {
            if next.x - shape.halfW < w.minX { next.x = w.minX + shape.halfW; b.vel.dx = abs(b.vel.dx) * 0.6; b.spin = -b.spin * 0.7 }
            if next.x + shape.halfW > w.maxX { next.x = w.maxX - shape.halfW; b.vel.dx = -abs(b.vel.dx) * 0.6; b.spin = -b.spin * 0.7 }
            innerFloor = (w.minY, id)
        }

        // Drawn shapes: solid lines that bounce things and catch them on gentle slopes.
        if let hit = collideDrawings(&b, &next, shape: shape, dt: dt, world: world) { return hit }

        // Floors: the Dock / display bottom, and window title bars.
        if b.vel.dy <= 0 {
            let feetBefore = b.pos.y - shape.halfH + shape.foot
            let feetAfter = next.y - shape.halfH + shape.foot
            let floorScreen = world.screen(containing: CGPoint(x: next.x, y: max(next.y, f.minY))) ?? cur
            let floor = floorScreen.floor(at: next.x)
            var landing: (y: CGFloat, window: Int?)? = feetAfter <= floor ? (floor, nil) : nil
            if let inner = innerFloor {
                let edge = inner.y, best = landing?.y ?? -.infinity
                if feetBefore >= edge - 0.5 && feetAfter < edge && edge > best { landing = (edge, inner.id) }
            }
            for (i, w) in world.windows.enumerated() where next.x >= w.frame.minX && next.x <= w.frame.maxX {
                let top = w.frame.maxY
                let best = landing?.y ?? -.infinity
                guard feetBefore >= top - 0.5, (feetAfter < top), (top > best),
                      !world.isCovered(CGPoint(x: next.x, y: top - 2), inFrontOf: i),
                      world.screen(containing: CGPoint(x: next.x, y: top - 2)) != nil
                else { continue }
                landing = (top, w.id)
            }
            if let land = landing {
                next.y = land.y + shape.halfH - shape.foot
                b.pos = next
                let impact = -b.vel.dy
                if impact > 300 {
                    b.vel.dy = impact * shape.bounce
                    b.vel.dx *= 0.7
                    b.spin = b.spin * 0.5 - b.vel.dx / max(shape.halfW * 6, 1)
                    return .bounced(impact: impact)
                }
                if shape.rolls, abs(b.vel.dx) > 25 {       // roll on, slowing down
                    b.vel.dy = 0
                    b.vel.dx *= max(0, 1 - 1.2 * dt)
                    b.spin = -b.vel.dx / max(shape.halfW, 1)
                    b.airTime = 0
                    return .flying
                }
                b.vel = .zero
                b.airTime = 0
                return .rested(onWindow: land.window, impact: impact)
            }
        }

        b.pos = next
        if b.airTime > 10 {   // safety net: never fly forever
            b.vel = .zero
            b.airTime = 0
            return .rested(onWindow: nil, impact: 0)
        }
        return .flying
    }

    /// Treat the body as a circle and every drawn segment as a solid line. Gentle slopes
    /// (< ~53°) are ground: things land on them and walkers slide along them. Steeper ones
    /// are walls that bounce.
    private static func collideDrawings(_ b: inout Body, _ next: inout CGPoint, shape: Shape, dt: CGFloat,
                                        world: World) -> StepResult? {
        let r = max(2, min(shape.halfW, shape.halfH - shape.foot))
        var support: Int?
        for d in world.drawings where d.solid {
            let reach = r + d.width / 2
            // The same segments as `d.segments` (each point to the next, and back to the
            // start if it's closed), without building that array every step.
            let pts = d.points
            guard pts.count >= 2 else { continue }
            for k in 0..<(d.closed ? pts.count : pts.count - 1) {
                let a = pts[k], e = pts[k + 1 == pts.count ? 0 : k + 1]
                let abx = e.x - a.x, aby = e.y - a.y
                let len = hypot(abx, aby)
                guard len > 0.5 else { continue }
                var n = CGVector(dx: -aby / len, dy: abx / len)
                var d0 = (b.pos.x - a.x) * n.dx + (b.pos.y - a.y) * n.dy
                if d0 < 0 { n = CGVector(dx: -n.dx, dy: -n.dy); d0 = -d0 }
                let alongNow = ((b.pos.x - a.x) * abx + (b.pos.y - a.y) * aby) / len

                // Already sunk into the line (e.g. at a joint between segments): push out.
                if d0 < reach - 0.5, alongNow >= 0, alongNow <= len {
                    let push = reach - d0
                    b.pos.x += n.dx * push; b.pos.y += n.dy * push
                    next.x += n.dx * push; next.y += n.dy * push
                    let vn = b.vel.dx * n.dx + b.vel.dy * n.dy
                    if vn < 0 { b.vel.dx -= n.dx * vn; b.vel.dy -= n.dy * vn }
                    d0 = reach
                    if n.dy > 0.6 { support = d.id }
                }

                let d1 = (next.x - a.x) * n.dx + (next.y - a.y) * n.dy
                guard d0 >= reach - 1, d1 < reach else { continue }
                let t = max(0, min(1, (d0 - reach) / max(d0 - d1, 0.0001)))
                let c = CGPoint(x: b.pos.x + (next.x - b.pos.x) * t, y: b.pos.y + (next.y - b.pos.y) * t)
                let along = ((c.x - a.x) * abx + (c.y - a.y) * aby) / len
                guard along >= -r * 0.4, along <= len + r * 0.4 else { continue }
                let vn = b.vel.dx * n.dx + b.vel.dy * n.dy
                guard vn < 0 else { continue }
                let impact = -vn
                if n.dy > 0.6 && impact < 320 {
                    // Ground: keep the rest of the move, along the surface (walk up/down slopes).
                    let tx = n.dy, ty = -n.dx
                    let slide = (next.x - c.x) * tx + (next.y - c.y) * ty
                    next = CGPoint(x: c.x + n.dx * 0.5 + tx * slide, y: c.y + n.dy * 0.5 + ty * slide)
                    b.pos = next
                    let along = b.vel.dx * tx + b.vel.dy * ty
                    if shape.rolls, abs(along) > 25 {      // a ball rolls along (and down) the line
                        let friction: CGFloat = max(0, 1 - 1.2 * dt)
                        let downhill: CGFloat = Physics.gravity * ty * dt * 0.5
                        let a: CGFloat = along * friction - downhill
                        b.vel = CGVector(dx: tx * a, dy: ty * a)
                        b.spin = -a / max(shape.halfW, 1)
                        b.airTime = 0
                        return .flying
                    }
                    b.vel = .zero
                    b.airTime = 0
                    return .rested(onWindow: d.id, impact: impact)
                }
                next = CGPoint(x: c.x + n.dx * 0.5, y: c.y + n.dy * 0.5)
                b.pos = next
                b.vel = CGVector(dx: (b.vel.dx - n.dx * vn * (1 + shape.bounce)) * 0.92,
                                 dy: (b.vel.dy - n.dy * vn * (1 + shape.bounce)) * 0.92)
                b.spin = b.spin * 0.6 + (b.vel.dx * n.dy - b.vel.dy * n.dx) / max(shape.halfW * 6, 1)
                return .bounced(impact: impact)
            }
        }
        if let id = support, b.vel.dy <= 0 {   // standing on a line it was pushed back onto
            b.pos = next
            b.vel = .zero
            b.airTime = 0
            return .rested(onWindow: id, impact: 0)
        }
        return nil
    }
}
