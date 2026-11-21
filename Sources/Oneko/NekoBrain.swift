import CoreGraphics

/// Every animation the cat can show. Raw values match oneko.js naming.
enum SpriteName: String, CaseIterable {
    case idle, alert, scratchSelf, tired, sleeping
    case scratchWallN, scratchWallS, scratchWallE, scratchWallW
    case N, NE, E, SE, S, SW, W, NW

    /// (column, row) cells in the 8×4 sprite sheet, 32×32 px each.
    /// Taken from oneko.js (its negative background offsets, flipped to positive cells).
    var frames: [(col: Int, row: Int)] {
        switch self {
        case .idle:         return [(3, 3)]
        case .alert:        return [(7, 3)]
        case .scratchSelf:  return [(5, 0), (6, 0), (7, 0)]
        case .scratchWallN: return [(0, 0), (0, 1)]
        case .scratchWallS: return [(7, 1), (6, 2)]
        case .scratchWallE: return [(2, 2), (2, 3)]
        case .scratchWallW: return [(4, 0), (4, 1)]
        case .tired:        return [(3, 2)]
        case .sleeping:     return [(2, 0), (2, 1)]
        case .N:            return [(1, 2), (1, 3)]
        case .NE:           return [(0, 2), (0, 3)]
        case .E:            return [(3, 0), (3, 1)]
        case .SE:           return [(5, 1), (5, 2)]
        case .S:            return [(6, 3), (7, 2)]
        case .SW:           return [(5, 3), (6, 1)]
        case .W:            return [(4, 2), (4, 3)]
        case .NW:           return [(1, 0), (1, 1)]
        }
    }

    func cell(at frame: Int) -> (col: Int, row: Int) {
        let f = frames
        return f[((frame % f.count) + f.count) % f.count]
    }
}

/// The oneko.js behaviour, ported 1:1 but in AppKit's y-up global coordinates.
/// Pure logic, no AppKit, so it can be simulated headless (`Oneko --selftest`).
struct NekoBrain {
    /// Centre of the cat, in global screen points (y grows upward).
    var position: CGPoint
    var speed: CGFloat = 10
    /// Asleep in place (menu Pause, or Reduce Motion).
    var paused = false
    /// Whether "sleeping" is one of the random idle animations.
    var sleepEnabled = true
    /// Half the cat's on-screen size: 16 at 1×. Distances below scale with it,
    /// matching oneko.js at 1× (stop at 48, walls at 32, keep 16 from the edge).
    var halfSize: CGFloat = 16

    /// Wall scratching up/down (off for the Touch Bar, which is only 30 pt tall).
    var allowVerticalWalls = true

    var stopDistance: CGFloat { halfSize + 32 }
    private var wallMargin: CGFloat { halfSize + 16 }

    private(set) var sprite: SpriteName = .idle
    private(set) var spriteFrame = 0

    private var frameCount = 0
    private(set) var idleTime = 0
    private(set) var idleAnimation: SpriteName?
    private var idleAnimationFrame = 0
    private var pausedFrame = 0

    /// Injectable so tests can be deterministic. Returns 0..<upperBound.
    var random: (Int) -> Int = { Int.random(in: 0..<$0) }

    init(position: CGPoint) {
        self.position = position
    }

    /// One 100 ms tick. `screens` are the frames of every connected display.
    mutating func tick(cursor: CGPoint, screens: [CGRect]) {
        frameCount += 1

        if paused {
            // Curl up and sleep in place until resumed.
            if pausedFrame < 8 { set(.tired, 0) } else { set(.sleeping, pausedFrame / 4) }
            pausedFrame += 1
            return
        }
        pausedFrame = 0

        let diffX = position.x - cursor.x   // > 0: cursor is to the west
        let diffY = cursor.y - position.y   // > 0: cursor is to the north
        let distance = (diffX * diffX + diffY * diffY).squareRoot()

        if distance < speed || distance < stopDistance {
            idle(screens: screens)
            return
        }

        idleAnimation = nil
        idleAnimationFrame = 0

        if idleTime > 1 {
            set(.alert, 0)
            // Show "alert" for at most 7 ticks before running.
            idleTime = min(idleTime, 7)
            idleTime -= 1
            return
        }

        set(Self.direction(diffX: diffX, diffY: diffY, distance: distance), frameCount)

        var next = position
        next.x -= (diffX / distance) * speed
        next.y += (diffY / distance) * speed
        position = move(from: position, to: next, cursor: cursor, screens: screens)
    }

    /// Run straight at `target` (nap spots, fetching). Returns true on arrival.
    mutating func walk(to target: CGPoint, speedMultiplier: CGFloat = 1) -> Bool {
        frameCount += 1
        idleTime = 0
        resetIdleAnimation()
        let diffX = position.x - target.x
        let diffY = target.y - position.y
        let distance = (diffX * diffX + diffY * diffY).squareRoot()
        let step = speed * speedMultiplier
        if distance <= step {
            position = target
            return true
        }
        set(Self.direction(diffX: diffX, diffY: diffY, distance: distance), frameCount)
        position.x -= diffX / distance * step
        position.y += diffY / distance * step
        return false
    }

    /// One of the 8 running directions. diffX > 0: target is west; diffY > 0: target is north.
    static func direction(diffX: CGFloat, diffY: CGFloat, distance: CGFloat) -> SpriteName {
        var dir = ""
        if diffY / distance > 0.5 { dir += "N" }
        if diffY / distance < -0.5 { dir += "S" }
        if diffX / distance > 0.5 { dir += "W" }
        if diffX / distance < -0.5 { dir += "E" }
        return SpriteName(rawValue: dir) ?? .idle
    }

    /// Called when we resume, so the cat looks up before it runs off.
    mutating func wakeUp() {
        idleAnimation = nil
        idleAnimationFrame = 0
        idleTime = 7
    }

    // MARK: - Private

    private mutating func idle(screens: [CGRect]) {
        idleTime += 1

        if idleTime > 10, random(200) == 0, idleAnimation == nil {
            var choices: [SpriteName] = sleepEnabled ? [.sleeping, .scratchSelf] : [.scratchSelf]
            if let s = screen(containing: position, in: screens) {
                if position.x < s.minX + wallMargin { choices.append(.scratchWallW) }
                if position.x > s.maxX - wallMargin { choices.append(.scratchWallE) }
                if allowVerticalWalls, position.y > s.maxY - wallMargin { choices.append(.scratchWallN) }
                if allowVerticalWalls, position.y < s.minY + wallMargin { choices.append(.scratchWallS) }
            }
            idleAnimation = choices[random(choices.count)]
        }

        switch idleAnimation {
        case .sleeping:
            if idleAnimationFrame < 8 {
                set(.tired, 0)
            } else {
                set(.sleeping, idleAnimationFrame / 4)
                if idleAnimationFrame > 192 { resetIdleAnimation() }
            }
        case .scratchSelf, .scratchWallN, .scratchWallS, .scratchWallE, .scratchWallW:
            set(idleAnimation!, idleAnimationFrame)
            if idleAnimationFrame > 9 { resetIdleAnimation() }
        default:
            set(.idle, 0)
            return
        }
        idleAnimationFrame += 1
    }

    private mutating func resetIdleAnimation() {
        idleAnimation = nil
        idleAnimationFrame = 0
    }

    /// Show a pose directly (used by the playground for naps, flights and petting).
    mutating func set(_ name: SpriteName, _ frame: Int) {
        sprite = name
        spriteFrame = frame
    }

    private func screen(containing p: CGPoint, in screens: [CGRect]) -> CGRect? {
        screens.first { $0.contains(p) }
    }

    /// Where a step from `p0` to `p` ends up. The whole cat always stays on one display
    /// (with separate Spaces per display, macOS can't show a window across two). Heading for
    /// the cursor's display, it goes through the edge the two share: along its own edge to
    /// where they meet, then a hop over, never a jump across a corner.
    func move(from p0: CGPoint, to p: CGPoint, cursor: CGPoint, screens: [CGRect]) -> CGPoint {
        let m = halfSize
        if screens.contains(where: { $0.insetBy(dx: m, dy: m).contains(p) }) { return p }
        guard let target = screen(containing: cursor, in: screens),
              let here = screens.first(where: { $0.insetBy(dx: m - 0.5, dy: m - 0.5).contains(p0) }),
              here != target
        else { return clamp(p, cursor: cursor, screens: screens) }   // same display: slide along its edge
        let hi = here.insetBy(dx: m, dy: m), ti = target.insetBy(dx: m, dy: m)
        func inside(_ r: CGRect, _ q: CGPoint) -> CGPoint {
            CGPoint(x: min(max(q.x, r.minX), r.maxX), y: min(max(q.y, r.minY), r.maxY))
        }
        let step = hypot(p.x - p0.x, p.y - p0.y)
        func walk(to goal: CGPoint) -> CGPoint {
            let d = hypot(goal.x - p0.x, goal.y - p0.y)
            guard d > step else { return goal }
            return CGPoint(x: p0.x + (goal.x - p0.x) / d * step, y: p0.y + (goal.y - p0.y) / d * step)
        }
        // Side by side.
        let leftOf = abs(here.maxX - target.minX) < 1, rightOf = abs(here.minX - target.maxX) < 1
        if leftOf || rightOf {
            let lo = max(here.minY, target.minY) + m, up = min(here.maxY, target.maxY) - m
            if lo <= up {
                if p0.y >= lo - 0.5 && p0.y <= up + 0.5 {
                    let crossing = leftOf ? p.x > hi.maxX : p.x < hi.minX
                    guard crossing else { return inside(hi, p) }
                    return CGPoint(x: leftOf ? ti.minX : ti.maxX, y: min(max(p.y, lo), up))
                }
                return walk(to: CGPoint(x: leftOf ? hi.maxX : hi.minX, y: min(max(p0.y, lo), up)))
            }
        }
        // Stacked.
        let below = abs(here.maxY - target.minY) < 1, above = abs(here.minY - target.maxY) < 1
        if below || above {
            let lo = max(here.minX, target.minX) + m, up = min(here.maxX, target.maxX) - m
            if lo <= up {
                if p0.x >= lo - 0.5 && p0.x <= up + 0.5 {
                    let crossing = below ? p.y > hi.maxY : p.y < hi.minY
                    guard crossing else { return inside(hi, p) }
                    return CGPoint(x: min(max(p.x, lo), up), y: below ? ti.minY : ti.maxY)
                }
                return walk(to: CGPoint(x: min(max(p0.x, lo), up), y: below ? hi.maxY : hi.minY))
            }
        }
        return inside(ti, p)   // displays that don't share an edge: straight over
    }

    /// Keep the whole cat inside a display. If the step would leave every display
    /// (e.g. the gap between two monitors of different sizes), snap onto the cursor's display.
    func clamp(_ p: CGPoint, cursor: CGPoint, screens: [CGRect]) -> CGPoint {
        let m = halfSize
        if screens.contains(where: { $0.insetBy(dx: m, dy: m).contains(p) }) { return p }
        guard let target = screen(containing: cursor, in: screens)
                ?? screen(containing: p, in: screens)
                ?? screens.first else { return p }
        let r = target.insetBy(dx: m, dy: m)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }
}
