import CoreGraphics

enum Thing: Equatable { case cat, bone, box, yarn }

/// Somewhere the cat can wander off to for a long nap.
struct NapSpot: Equatable {
    enum Kind: Equatable { case box, window(Int), menuBar, dock }
    var kind: Kind
    /// Where the cat's centre sits while napping (global, y-up).
    var point: CGPoint
}

enum CatMode: Equatable {
    case chasing                                  // classic oneko
    case goingToSpot(NapSpot)
    case napping(NapSpot, ticksLeft: Int)
    case held                                     // being dragged
    case flying                                   // thrown / knocked: physics
    case landing(elapsed: CGFloat, onWindow: Int?) // righting itself after touchdown
    case dazed(ticksLeft: Int, onWindow: Int?)    // sitting it off (💢 if angry)
    case petted(ticksLeft: Int)
    case fetching
    case returningBone
    case staying(frame: Int)                      // double-clicked: sleeps right here
    case pinned(frame: Int)                       // right-clicked: clipped in mid-air
    case erased(ticksLeft: Int)                   // rubbed out; respawns soon
    case captured                                 // held in a Paint selection
    case walking                                  // Toolbox: gravity; walks on the ground and drawings
    case chasingYarn(ticksLeft: Int)              // after a rolling ball of yarn
    case zoomies(ticksLeft: Int, target: CGPoint) // catnip!
    case stretching(ticksLeft: Int)               // waking up after you were away
}

enum PropState: Equatable {
    case hidden
    case resting(onWindow: Int?)
    case flying
    case held
    case carried    // bone in the cat's mouth
    case pinned     // clipped in mid-air
}

struct Prop {
    var body = Body(pos: .zero)
    var state: PropState = .hidden
    var shape: Shape
    /// Resting angles snap to multiples of this (π: a bone can lie either way up).
    var uprightStep: CGFloat

    var isOut: Bool { state != .hidden && state != .carried }
    var isResting: Bool { if case .resting = state { return true } else { return false } }
    var restingWindow: Int? { if case .resting(let w) = state { return w } else { return nil } }
    var settledAngle: CGFloat { (body.angle / uprightStep).rounded() * uprightStep }
}

struct CatPose: Equatable {
    var sprite: SpriteName
    var frame: Int
    var center: CGPoint
    var angle: CGFloat
    var squash: CGFloat
    var angry: Bool
    var inBox: Bool
    var carryingBone: Bool
    var boxClosed = false
    var clipped = false
    /// 1 = solid; the eraser fades it; 0 = rubbed out.
    var opacity: CGFloat = 1
    /// Wobble of a closed box with a cat that wants out.
    var rattle: CGFloat = 0
}

enum PlaygroundEvent: Equatable {
    case heart, boneTaken, boneDropped
    case thrown(speed: CGFloat)                           // let go of with some speed
    case apex(height: CGFloat)                            // top of a flight, above where it started
    case landed(impact: CGFloat, onWindow: Int?, at: CGPoint)
    case fetched, bonked, dockYeet, batYarn, boxHop, woke
}

/// The cat, its toys and how they react to the desktop and the mouse. No AppKit.
struct Playground {
    var cat: NekoBrain
    private(set) var mode: CatMode = .chasing
    private(set) var catBody = Body(pos: .zero)
    private(set) var catShape = Shape(halfW: 13, halfH: 16, foot: 3, bounce: 0.35)
    private(set) var squash: CGFloat = 1
    private(set) var angry = false
    var bone = Prop(shape: Shape(halfW: 8, halfH: 3.5, foot: 0, bounce: 0.45), uprightStep: .pi)
    var box = Prop(shape: Shape(halfW: 14, halfH: 16, foot: 1, bounce: 0.15), uprightStep: 2 * .pi)
    var yarn = Prop(shape: Shape(halfW: 6, halfH: 6, foot: 0, bounce: 0.55, rolls: true), uprightStep: .pi / 8)

    /// Laser pointer mode: it dashes after the dot on your cursor and pounces on it.
    var laser = false
    /// Late at night: naps more often.
    var sleepy = false
    private var zoomBoost = 0          // gravity mode's catnip: ticks of triple speed
    private var batCooldown = 0
    private var launchY: CGFloat = 0
    private var rising = false
    /// The velocity you last threw the cat with (zero if it fell or was knocked).
    private(set) var lastThrow = CGVector.zero
    private(set) var scale: CGFloat = 1
    private(set) var boxClosed = false

    // Toolbox
    /// Toolbox mode: no floating. Neko falls, and walks along the ground, window tops and
    /// whatever you draw, towards your cursor.
    var gravityMode = false
    private enum WalkGoal { case cursor, bone, bringBack, nap }
    /// Extra upward kick on flicks (the Touch Bar is too short to swipe upward much).
    var throwLift: CGFloat = 0
    private var walkGoal = WalkGoal.cursor
    private var walkFrame = 0
    /// Standing right under the cursor, nothing to do: no physics needed.
    private(set) var walkArrived = false
    private var walkGrounded = false
    /// Health while being erased (1 full … 0 rubbed out).
    private(set) var hp: CGFloat = 1
    /// Magnifier: the cat's size relative to everything else.
    private(set) var catSize: CGFloat = 1

    var paused = false
    var spotWindows = true
    var spotMenuBar = true
    var spotDock = true
    var random: (Int) -> Int = { Int.random(in: 0..<max($0, 1)) }

    private var events: [PlaygroundEvent] = []
    /// The current flight was your doing (a throw or a window you swung), not the cat's.
    private var userLaunched = false
    /// You put it on the Dock: once it has landed and sat a moment, it stays there.
    private var parkWhenSettled = false
    /// The window (or drawing) a parked cat is sitting on, so it rides along.
    private var stayWindow: Int?
    private var lastScreens: [ScreenInfo] = []
    private var napFrame = 0
    private var flyFrame = 0
    private var boneWanted = false
    private var lastWindows: [Int: CGRect] = [:]
    private var grab: Grab?
    private var swing: Swing?
    private var boneSwing: Swing?

    /// A held cat hangs off the cursor on a short arm and turns with your hand, like a Wii
    /// remote: circle the mouse and it spins around the cursor in step; hold still and it
    /// settles upright.
    private struct Swing {
        var pivot: CGPoint
        var prevPivot: CGPoint
        var vel = CGVector.zero
        var heading: CGFloat?        // direction the cursor is moving, while it moves
        var target: CGFloat          // accumulated turn (unwrapped)
        var length: CGFloat
    }

    private struct Grab {
        var thing: Thing
        var offset: CGVector
        var start: CGPoint
        var dragging = false
        var samples: [(t: Double, p: CGPoint)]
    }

    init(position: CGPoint) {
        cat = NekoBrain(position: position)
    }

    mutating func setScale(_ s: Int) {
        scale = CGFloat(s)
        applyCatSize()
        bone.shape = Shape(halfW: 8 * scale, halfH: 3.5 * scale, foot: 0, bounce: 0.45)
        box.shape = Shape(halfW: 14 * scale, halfH: 16 * scale, foot: 1 * scale, bounce: 0.15)
        yarn.shape = Shape(halfW: 6 * scale, halfH: 6 * scale, foot: 0, bounce: 0.55, rolls: true)
    }

    private mutating func applyCatSize() {
        let k = scale * catSize
        cat.halfSize = 16 * k
        catShape = Shape(halfW: 13 * k, halfH: 16 * k, foot: 3 * k, bounce: 0.35)
    }

    /// Magnifier: make the cat (only) bigger. 1 = normal.
    mutating func setCatSize(_ k: CGFloat) {
        let feet = cat.position.y - catShape.halfH + catShape.foot
        catSize = k
        applyCatSize()
        cat.position.y = feet + catShape.halfH - catShape.foot   // grow from the feet up
        catBody.pos = cat.position
    }

    var catScale: CGFloat { scale * catSize }

    mutating func drainEvents() -> [PlaygroundEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - What to draw

    var inBox: Bool {
        if case .napping(let s, _) = mode, s.kind == .box { return true }
        return false
    }

    var catPose: CatPose {
        let physical: Bool
        switch mode {
        case .held, .flying, .landing: physical = true
        default: physical = false
        }
        var showAnger = false
        switch mode {
        case .landing, .dazed: showAnger = angry
        default: break
        }
        var rattle: CGFloat = 0
        if inBox, boxClosed, case .napping(_, let left) = mode, left <= 0 {
            rattle = CGFloat(sin(Double(napFrame) * 2.4)) * 0.12
        }
        return CatPose(sprite: cat.sprite, frame: cat.spriteFrame, center: cat.position,
                       angle: physical ? catBody.angle : 0, squash: squash,
                       angry: showAnger, inBox: inBox,
                       carryingBone: mode == .returningBone || (mode == .walking && walkGoal == .bringBack),
                       boxClosed: boxClosed, clipped: { if case .pinned = mode { return true }; return false }(),
                       opacity: { if case .erased = mode { return 0 }; return hp }(),
                       rattle: rattle)
    }

    /// True while something sits on a window or is in the air, so window positions must be
    /// read every tick (otherwise once a second is plenty).
    var needsWindowTracking: Bool {
        if catWindow != nil || bone.restingWindow != nil || box.restingWindow != nil || yarn.restingWindow != nil { return true }   // riding something
        switch mode {
        case .goingToSpot(let s): if case .window = s.kind { return true }
        case .flying, .landing: return true
        case .walking: if !walkArrived { return true }
        default: break
        }
        return bone.state == .flying || box.state == .flying || yarn.state == .flying
    }

    /// Why physics is running (for ONEKO_DEBUG).
    var physicsReason: String {
        var r: [String] = []
        switch mode {
        case .held, .flying, .landing: r.append("cat \(mode)")
        case .walking where !walkArrived: r.append("walking")
        default: break
        }
        for (n, p) in [("bone", bone), ("box", box), ("yarn", yarn)] {
            if p.state == .flying || p.state == .held { r.append("\(n) \(p.state)") }
            if p.isResting && abs(p.body.angle - p.settledAngle) > 0.001 { r.append("\(n) angle \(p.body.angle) vs \(p.settledAngle)") }
        }
        if squash != 1 { r.append("squash \(squash)") }
        return r.joined(separator: ", ")
    }

    /// True while anything needs the 60 fps physics clock.
    var needsPhysics: Bool {
        switch mode {
        case .held, .flying, .landing: return true
        case .walking: if !walkArrived { return true }
        default: break
        }
        for p in [bone, box, yarn] {
            if p.state == .flying || p.state == .held { return true }
            if p.isResting && abs(p.body.angle - p.settledAngle) > 0.001 { return true }
        }
        return squash != 1
    }

    // MARK: - Toys

    mutating func placeBox(at p: CGPoint, falling: Bool) {
        box.body = Body(pos: p)
        box.state = falling ? .flying : .resting(onWindow: nil)
    }

    mutating func removeBox() {
        if inBox { mode = .chasing; cat.wakeUp() }
        box.state = .hidden
        boxClosed = false
    }

    /// Right-click: fold the flaps shut, or open them. A cat that's done napping in a closed
    /// box pops out when you open it.
    mutating func toggleBoxLid() {
        guard box.state != .hidden else { return }
        boxClosed.toggle()
        if !boxClosed, inBox, case .napping(_, let left) = mode, left <= 0 {
            cat.wakeUp()
            startFalling(velocity: CGVector(dx: CGFloat(random(400) - 200), dy: 1000))
        }
    }

    mutating func placeBone(at p: CGPoint, falling: Bool) {
        bone.body = Body(pos: p)
        bone.state = falling ? .flying : .resting(onWindow: nil)
    }

    mutating func removeBone() {
        if mode == .fetching || mode == .returningBone { mode = .chasing }
        walkGoal = .cursor
        boneWanted = false
        bone.state = .hidden
    }

    // MARK: - 10 Hz behaviour

    /// Call with each fresh window list (10–30×/s). `dt`: seconds since the previous list.
    mutating func updateWindows(_ world: World, dt: CGFloat) {
        let dt = max(dt, 0.01)
        if mode == .walking, world.windows.contains(where: { lastWindows[$0.id] != $0.frame }) { walkArrived = false }
        rideWindows(world, dt: dt)
        if world.mouseDown { collide(world, dt: dt) }
        lastWindows = Dictionary(world.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    mutating func tick10(world: World) {
        lastScreens = world.screens
        if batCooldown > 0 { batCooldown -= 1 }
        if zoomBoost > 0 { zoomBoost -= 1 }
        defer { batNearbyYarn() }
        if gravityMode && mode == .chasing { startWalking() }
        if !gravityMode && mode == .walking { mode = .chasing }
        defer { dockBounce(world) }   // after this tick's moves, so it never sits inside the Dock
        cat.paused = paused
        if paused {
            switch mode {
            case .goingToSpot, .fetching:
                mode = .chasing
            case .returningBone:
                dropBone(falling: true)
                mode = .chasing
            default: break
            }
        }

        // Fetch! (Cats in a cardboard box can't be bothered.)
        if boneWanted, !paused, bone.state == .flying || bone.isResting {
            switch mode {
            case .chasing, .petted, .goingToSpot:
                mode = .fetching
            case .napping(let spot, _) where spot.kind != .box:
                mode = .fetching
            case .walking:
                walkGoal = .bone          // on foot
                boneWanted = false
                walkArrived = false
            default: break
            }
        }

        switch mode {
        case .chasing:
            if laser && !paused {
                // Dash after the dot; when it's caught, pounce on it.
                if cat.walk(to: world.cursor, speedMultiplier: 2.2) { cat.set(.scratchSelf, napFrame); napFrame += 1 }
            } else {
                cat.tick(cursor: world.cursor, screens: world.screenFrames)
                if !paused { maybeStartNap(world) }
            }
            if !paused, !laser, yarn.state == .flying, hypot(yarn.body.vel.dx, yarn.body.vel.dy) > 250 {
                mode = .chasingYarn(ticksLeft: 50)          // a rolling ball? must chase
            }


        case .goingToSpot(var spot):
            if spot.kind == .box {
                guard box.isResting, !boxClosed else { mode = .chasing; break }
                spot.point = box.body.pos
            }
            if cat.walk(to: spot.point) {
                if spot.kind == .box { events.append(.boxHop) }
                napFrame = 0
                mode = .napping(spot, ticksLeft: 400 + random(800))   // 40 s – 2 min
            } else {
                mode = .goingToSpot(spot)
            }

        case .napping(let spot, let left):
            squash = 1
            if spot.kind == .box {
                // The cat stays in the box wherever it goes: carried, thrown or caught.
                guard box.state != .hidden else { mode = .chasing; cat.wakeUp(); break }
                cat.position = box.body.pos
            } else {
                cat.position = spot.point
            }
            cat.set(napFrame < 8 ? .tired : .sleeping, napFrame / 4)
            napFrame += 1
            if left <= 0 {
                if spot.kind == .box && boxClosed {
                    mode = .napping(spot, ticksLeft: 0)   // wants out: the box rattles
                } else {
                    mode = .chasing
                    cat.wakeUp()
                    events.append(.woke)
                }
            } else {
                mode = .napping(spot, ticksLeft: left - 1)
            }

        case .dazed(let left, let win):
            cat.set(.idle, 0)
            if left <= 0 {
                if parkWhenSettled {
                    // You put it here (Dock, window, drawing): it stays put, riding along.
                    parkWhenSettled = false
                    angry = false
                    stayWindow = win
                    mode = .staying(frame: 0)
                } else {
                    angry = false
                    mode = .chasing
                    cat.wakeUp()
                }
            } else {
                mode = .dazed(ticksLeft: left - 1, onWindow: win)
            }

        case .petted(let left):
            cat.set(.idle, 0)
            mode = left <= 0 ? .chasing : .petted(ticksLeft: left - 1)

        case .fetching:
            guard bone.state == .flying || bone.isResting else { mode = .chasing; break }
            // Line the cat's feet up with the bone's bottom.
            let target = CGPoint(x: bone.body.pos.x,
                                 y: bone.body.pos.y - bone.shape.halfH + catShape.halfH - catShape.foot)
            let near = hypot(cat.position.x - bone.body.pos.x, cat.position.y - bone.body.pos.y) < 18 * scale
            if near || cat.walk(to: target, speedMultiplier: 1.3) {
                bone.state = .carried
                boneWanted = false
                events.append(.boneTaken)
                mode = .returningBone
            }

        case .returningBone:
            let c = world.cursor
            if hypot(c.x - cat.position.x, c.y - cat.position.y) < cat.stopDistance {
                dropBone(falling: false, toward: c)
                events.append(.fetched)
                cat.set(.idle, 0)
                mode = .chasing
            } else {
                _ = cat.walk(to: c, speedMultiplier: 1.1)
            }
            bone.body.pos = cat.position

        case .staying(let n):
            cat.set(n < 8 ? .tired : .sleeping, n / 4)
            mode = .staying(frame: n + 1)

        case .chasingYarn(let left):
            let near = hypot(yarn.body.pos.x - cat.position.x, yarn.body.pos.y - cat.position.y) < catShape.halfW + 8 * scale
            if !yarn.isOut || yarn.state == .held || left <= 0 || paused {
                mode = .chasing
            } else if near || cat.walk(to: yarn.body.pos, speedMultiplier: 1.5) {
                batYarn()
                mode = .chasing
            } else {
                mode = .chasingYarn(ticksLeft: left - 1)
            }

        case .zoomies(let left, var target):
            if cat.walk(to: target, speedMultiplier: 3) || random(25) == 0 { target = randomSpot() }
            if left % 20 == 0 { events.append(.heart) }
            mode = left <= 0 ? .chasing : .zoomies(ticksLeft: left - 1, target: target)

        case .stretching(let left):
            cat.set(left > 4 ? .tired : .alert, 0)          // big yawn and stretch, then up
            mode = left <= 0 ? .chasing : .stretching(ticksLeft: left - 1)

        case .walking:
            let target = walkTarget(world)
            if walkGrounded, walkGoal == .cursor, abs(target.x - cat.position.x) <= 6 {
                if !walkArrived { cat.wakeUp(); cat.tick(cursor: cat.position, screens: world.screenFrames) }
                walkArrived = true
                // Classic idle life (grooming, yawning, naps) while it waits under you.
                cat.tick(cursor: cat.position, screens: world.screenFrames)
                // ...and a box nearby is irresistible: walk over and climb in.
                if !paused, cat.sleepEnabled, box.isResting, !boxClosed, cat.idleTime > 30, random(250) == 0 {
                    walkGoal = .nap
                    walkArrived = false
                }
            } else {
                walkArrived = false
            }

        case .erased(let left):
            if left <= 0 { respawn(world) } else { mode = .erased(ticksLeft: left - 1) }

        case .captured:
            cat.set(.alert, 0)

        case .pinned(let n):
            // Hangs there patiently, then dozes off on its clip.
            if n < 30 { cat.set(.idle, 0) } else if n < 38 { cat.set(.tired, 0) } else { cat.set(.sleeping, (n - 38) / 4) }
            mode = .pinned(frame: n + 1)

        case .held, .flying, .landing:
            break
        }
    }

    // MARK: - 60 Hz physics

    mutating func physics(dt: CGFloat, world: World) {
        lastScreens = world.screens
        switch mode {
        case .walking:
            walk(dt: dt, world: world)

        case .flying:
            flyFrame += 1
            let result = Physics.step(&catBody, shape: catShape, dt: dt, world: world)
            cat.position = catBody.pos
            cat.set(flailSprite(), flyFrame / 4)
            if rising && catBody.vel.dy <= 0 {
                rising = false
                events.append(.apex(height: cat.position.y - launchY))
            }
            if dropsIntoBox {
                // Plop! Straight into the box, and very pleased about it.
                catBody = Body(pos: box.body.pos)
                cat.position = box.body.pos
                angry = false
                squash = 0.8
                napFrame = 0
                events.append(.heart)
                events.append(.boxHop)
                mode = .napping(NapSpot(kind: .box, point: box.body.pos), ticksLeft: 400 + random(800))
                break
            }
            switch result {
            case .bounced(let impact):
                squash = 0.75
                if impact > 1600 { angry = true }
                // The first hard contact is the one that matters (it bounces before it rests).
                let s = world.screen(containing: cat.position) ?? world.nearestScreen(to: cat.position)
                let feet = cat.position.y - catShape.halfH + catShape.foot
                let onFloor = s.map { abs(feet - $0.floor(at: cat.position.x)) < 2 } ?? false
                events.append(.landed(impact: impact, onWindow: onFloor ? nil : 0, at: cat.position))
            case .rested(let win, let impact):
                events.append(.landed(impact: impact, onWindow: win, at: cat.position))
                if impact > 1300 { angry = true }
                // You put it on the Dock or on a window: it'll stay there.
                if userLaunched && (win != nil || landedOnDock(world)) { parkWhenSettled = true }
                squash = 0.7
                catBody.spin = 0
                mode = .landing(elapsed: 0, onWindow: win)
            case .flying:
                squash += (1 - squash) * min(1, dt * 10)
            }

        case .landing(let t, let win):
            let upright = (catBody.angle / (2 * .pi)).rounded() * 2 * .pi
            catBody.angle += (upright - catBody.angle) * min(1, dt * 12)
            squash += (1 - squash) * min(1, dt * 9)
            cat.set(angry ? .alert : .idle, 0)
            if t + dt >= 0.3 {
                catBody.angle = 0
                squash = 1
                cat.set(.idle, 0)
                mode = .dazed(ticksLeft: angry ? 25 : 5, onWindow: win)
            } else {
                mode = .landing(elapsed: t + dt, onWindow: win)
            }

        case .held:
            guard var s = swing else { break }
            Self.steer(&s, &catBody, dt: dt, sway: true)
            swing = s
            placeOnSwing()

        default:
            squash = 1
        }
        if bone.state == .held, var s = boneSwing {
            Self.steer(&s, &bone.body, dt: dt, sway: false)
            boneSwing = s
            bone.body.pos = s.pivot
        }
        Self.stepProp(&bone, dt: dt, world: world)
        Self.stepProp(&box, dt: dt, world: world)
        Self.stepProp(&yarn, dt: dt, world: world)
        if inBox { cat.position = box.body.pos }   // riding in a closed box
    }

    /// Wii-remote turning: every bit the cursor's heading turns, the held thing turns too;
    /// held still, it eases back upright. `body.spin` tracks the turn rate for the throw.
    private static func steer(_ s: inout Swing, _ body: inout Body, dt: CGFloat, sway: Bool) {
        let raw = CGVector(dx: (s.pivot.x - s.prevPivot.x) / dt, dy: (s.pivot.y - s.prevPivot.y) / dt)
        s.vel = CGVector(dx: s.vel.dx + (raw.dx - s.vel.dx) * 0.4, dy: s.vel.dy + (raw.dy - s.vel.dy) * 0.4)
        s.prevPivot = s.pivot
        if hypot(s.vel.dx, s.vel.dy) > 120 {
            let h = atan2(s.vel.dy, s.vel.dx)
            if let prev = s.heading {
                var dh = h - prev
                while dh > .pi { dh -= 2 * .pi }
                while dh < -.pi { dh += 2 * .pi }
                s.target += dh
            }
            s.heading = h
        } else {
            s.heading = nil
            let upright = (s.target / (2 * .pi)).rounded() * 2 * .pi
            s.target += (upright - s.target) * min(1, dt * 4)
        }
        let lean = sway ? max(-0.35, min(0.35, -s.vel.dx / 3000)) : 0   // trails a little when dragged
        let before = body.angle
        body.angle += (s.target + lean - body.angle) * min(1, dt * 18)
        let w = (body.angle - before) / dt
        body.spin += (w - body.spin) * 0.3
    }

    private static func stepProp(_ p: inout Prop, dt: CGFloat, world: World) {
        switch p.state {
        case .flying:
            if case .rested(let win, _) = Physics.step(&p.body, shape: p.shape, dt: dt, world: world) {
                p.state = .resting(onWindow: win)
                p.body.spin = 0
            }
        case .resting:
            let target = p.settledAngle
            p.body.angle += (target - p.body.angle) * min(1, dt * 12)
            if abs(target - p.body.angle) < 0.001 { p.body.angle = target }
        default:
            break
        }
    }

    // MARK: - Mouse

    mutating func mouseDown(on thing: Thing, at p: CGPoint, time: Double) {
        let c = position(of: thing)
        grab = Grab(thing: thing, offset: CGVector(dx: c.x - p.x, dy: c.y - p.y), start: p,
                    samples: [(time, p)])
    }

    mutating func mouseDragged(to p: CGPoint, time: Double) {
        guard var g = grab else { return }
        g.samples.append((time, p))
        if g.samples.count > 8 { g.samples.removeFirst() }
        if !g.dragging, hypot(p.x - g.start.x, p.y - g.start.y) > 4 {
            g.dragging = true
            beginHold(g.thing, grab: g, at: p)
        }
        if g.dragging {
            let c = CGPoint(x: p.x + g.offset.dx, y: p.y + g.offset.dy)
            switch g.thing {
            case .cat:
                // The pendulum swings at 60 fps in physics(); here just move the pivot and
                // keep the body attached so it tracks the cursor instantly.
                swing?.pivot = p
                placeOnSwing()
            case .bone:
                boneSwing?.pivot = c
                bone.body.pos = c
            case .box:
                box.body.pos = c
                if inBox { cat.position = c }
            case .yarn:
                yarn.body.pos = c
            }
        }
        grab = g
    }

    mutating func mouseUp(at p: CGPoint, time: Double, clickCount: Int = 1) {
        guard var g = grab else { return }
        grab = nil
        guard g.dragging else { click(g.thing, count: clickCount); return }
        g.samples.append((time, p))
        // Throws carry more than the raw mouse speed: flicks should yeet.
        let raw = Self.velocity(g.samples)
        let lift = hypot(raw.dx, raw.dy) > 150 ? throwLift : 0
        let v = Physics.clampSpeed(CGVector(dx: raw.dx * Self.throwBoost, dy: raw.dy * Self.throwBoost + lift))
        let speed = hypot(v.dx, v.dy)
        switch g.thing {
        case .cat where speed < 400 && parkInMenuBar():
            swing = nil
        case .cat:
            // Let go mid-swing: the cat keeps its whirl and flies off along the swing.
            let w = catBody.spin
            let len = swing?.length ?? 0
            let tangent = CGVector(dx: len * w * cos(catBody.angle), dy: len * w * sin(catBody.angle))
            catBody.vel = Physics.clampSpeed(CGVector(dx: v.dx + tangent.dx * 1.3, dy: v.dy + tangent.dy * 1.3))
            if abs(w) < 3 { catBody.spin = -v.dx / 100 + CGFloat(random(200) - 100) / 50 }
            swing = nil
            if speed > 2200 { angry = true }   // yeet
            flyFrame = 0
            mode = .flying
            userLaunched = true
            lastThrow = catBody.vel
            launchY = cat.position.y
            rising = catBody.vel.dy > 0
            events.append(.thrown(speed: speed))
        case .bone:
            bone.body.vel = v
            if abs(bone.body.spin) < 3 { bone.body.spin = max(-30, min(30, -v.dx / 50)) }  // else keep its twirl
            boneSwing = nil
            bone.state = .flying
            if speed > 300 { boneWanted = true }
        case .box:
            box.body.vel = CGVector(dx: v.dx * 0.7, dy: v.dy * 0.7)
            box.body.spin = -v.dx / 400
            box.state = .flying
        case .yarn:
            yarn.body.vel = v
            yarn.body.spin = -v.dx / 40
            yarn.state = .flying
        }
    }

    var isDragging: Bool { grab?.dragging ?? false }

    /// Asleep until you wake it: told to stay, parked, or off napping somewhere.
    var isSleeping: Bool {
        switch mode {
        case .staying: return true
        case .napping: return !(inBox && boxClosed)
        default: return false
        }
    }

    /// Right-click. Mid-drag: clip whatever you're dragging right there. On a clipped thing:
    /// let go (it falls). On the cat: clip it where it is (even mid-flight). On the box (or
    /// the cat in it): open/close the flaps.
    mutating func rightClick(_ thing: Thing) {
        if let g = grab, g.dragging {
            grab = nil
            clip(g.thing)
            return
        }
        grab = nil
        switch thing {
        case .cat:
            if inBox { toggleBoxLid(); return }
            if case .pinned = mode { startFalling(velocity: .zero) } else { clip(.cat) }
        case .box:
            if box.state == .pinned { Self.unclip(&box) } else { toggleBoxLid() }
        case .bone:
            if bone.state == .pinned { Self.unclip(&bone) } else if bone.isOut { clip(.bone) }
        case .yarn:
            if yarn.state == .pinned { Self.unclip(&yarn) } else if yarn.isOut { clip(.yarn) }
        }
    }

    private mutating func clip(_ thing: Thing) {
        switch thing {
        case .cat:
            if mode == .returningBone { dropBone(falling: true) }
            swing = nil
            catBody = Body(pos: cat.position)
            squash = 1
            mode = .pinned(frame: 0)
            cat.set(.idle, 0)
        case .box:
            box.state = .pinned
            box.body.vel = .zero
            box.body.spin = 0
        case .bone:
            if mode == .fetching { mode = .chasing }
            boneWanted = false
            boneSwing = nil
            bone.state = .pinned
            bone.body.vel = .zero
            bone.body.spin = 0
        case .yarn:
            if case .chasingYarn = mode { mode = .chasing }
            yarn.state = .pinned
            yarn.body.vel = .zero
            yarn.body.spin = 0
        }
    }

    private static func unclip(_ p: inout Prop) {
        p.state = .flying
        p.body.vel = .zero
    }

    static let throwBoost: CGFloat = 1.8

    private mutating func beginHold(_ thing: Thing, grab g: Grab, at p: CGPoint) {
        switch thing {
        case .cat:
            if mode == .returningBone || walkGoal == .bringBack { dropBone(falling: true) }
            walkGoal = .cursor
            angry = false
            parkWhenSettled = false
            // Hang from wherever it was grabbed: by the scruff it dangles, by the feet it
            // starts upside down and flops over.
            let off = g.offset   // cat centre minus grab point
            let reach = hypot(off.dx, off.dy)
            let theta = reach > 3 ? atan2(off.dx, -off.dy) : 0
            swing = Swing(pivot: p, prevPivot: p, target: theta,
                          length: max(10 * scale, min(22 * scale, reach)))
            catBody = Body(pos: cat.position, angle: theta, spin: 0)
            squash = 1
            mode = .held
            placeOnSwing()
        case .bone:
            if mode == .fetching || mode == .returningBone { mode = .chasing }
            if walkGoal == .bone { walkGoal = .cursor }
            boneWanted = false
            bone.state = .held
            bone.body.vel = .zero
            bone.body.spin = 0
            let c = CGPoint(x: p.x + g.offset.dx, y: p.y + g.offset.dy)
            boneSwing = Swing(pivot: c, prevPivot: c, target: bone.body.angle, length: 0)
        case .box:
            box.state = .held   // a cat inside comes along for the ride
            box.body.vel = .zero
        case .yarn:
            if case .chasingYarn = mode { mode = .chasing }
            yarn.state = .held
            yarn.body.vel = .zero
        }
    }

    private mutating func click(_ thing: Thing, count: Int = 1) {
        switch thing {
        case .cat where count >= 2:
            // Double-click: "stay!" — sleep right here. Double-click a sleeping cat to wake it
            // (one that stays, or one off napping somewhere).
            if case .staying = mode {
                mode = .chasing
                cat.wakeUp()
            } else if case .napping(let spot, _) = mode {
                mode = .napping(spot, ticksLeft: 0)   // wakes on the next tick
            } else {
                if mode == .returningBone { dropBone(falling: true) }
                angry = false
                stayWindow = nil
                mode = .staying(frame: 0)
            }
        case .cat:
            events.append(.heart)
            angry = false                       // pets fix everything
            switch mode {
            case .chasing, .petted, .dazed, .walking, .stretching, .chasingYarn:
                mode = .petted(ticksLeft: 20)       // calmed right down
                cat.set(.idle, 0)
            default:
                break                           // napping cats just get a heart
            }
        case .bone:
            // One click = a little toss, and off the cat goes.
            bone.body.vel = CGVector(dx: CGFloat(random(800) - 400), dy: 900)
            bone.body.spin = CGFloat(random(20) - 10)
            bone.state = .flying
            boneWanted = true
        case .box:
            break
        case .yarn:
            // A little nudge: it rolls off, and the cat can't resist.
            yarn.body.vel = CGVector(dx: CGFloat(random(2) == 0 ? -350 : 350), dy: 350)
            yarn.body.spin = CGFloat(random(20) - 10)
            yarn.state = .flying
        }
    }

    private func position(of thing: Thing) -> CGPoint {
        switch thing {
        case .cat: return cat.position
        case .bone: return bone.body.pos
        case .box: return box.body.pos
        case .yarn: return yarn.body.pos
        }
    }

    static func velocity(_ s: [(t: Double, p: CGPoint)]) -> CGVector {
        guard let last = s.last else { return .zero }
        let first = s.first { last.t - $0.t <= 0.08 } ?? last
        let dt = last.t - first.t
        guard dt > 0.005 else { return .zero }
        return CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
    }

    // MARK: - Helpers

    /// Falling (or dropped) into the opening of a resting box?
    private var dropsIntoBox: Bool {
        guard box.isResting || box.state == .held || box.state == .pinned, !boxClosed, catBody.vel.dy <= 0 else { return false }
        let dx = cat.position.x - box.body.pos.x
        let dy = cat.position.y - box.body.pos.y
        let held: CGFloat = box.state == .held ? 1.25 : 1   // catching with the box in hand: a bit easier
        return abs(dx) < 13 * scale * held && dy > -6 * scale * held && dy < 22 * scale * held
    }

    /// Put the held cat at the end of its arm.
    private mutating func placeOnSwing() {
        guard let s = swing else { return }
        let p = CGPoint(x: s.pivot.x + s.length * sin(catBody.angle),
                        y: s.pivot.y - s.length * cos(catBody.angle))
        catBody.pos = p
        cat.position = p
        cat.set(.alert, 0)
    }

    private mutating func dropBone(falling: Bool, toward target: CGPoint? = nil) {
        var p = cat.position
        if let t = target {
            let dx = t.x - p.x, dy = t.y - p.y, d = max(hypot(dx, dy), 1)
            p.x += dx / d * 12 * scale
            p.y += dy / d * 12 * scale
        }
        p.y = min(p.y, cat.position.y - catShape.halfH + catShape.foot + bone.shape.halfH + 2 * scale)
        bone.body = Body(pos: p)
        bone.state = falling ? .flying : .resting(onWindow: nil)
        events.append(.boneDropped)
    }

    private func landedOnDock(_ world: World) -> Bool {
        let feet = cat.position.y - catShape.halfH + catShape.foot
        return world.screens.contains { s in
            guard let d = s.dock, d.width >= d.height, d.minX <= cat.position.x, cat.position.x <= d.maxX
            else { return false }
            return abs(feet - d.maxY) < 2
        }
    }

    /// Dropped gently into a menu bar: park it there instead of letting it fall.
    private mutating func parkInMenuBar() -> Bool {
        guard catScale <= 1 else { return false }   // too big to sit up there: it just falls
        guard let s = lastScreens.first(where: { $0.frame.contains(cat.position) }),
              s.frame.maxY - s.visible.maxY >= 18, cat.position.y > s.visible.maxY
        else { return false }
        cat.position.y = min(s.visible.maxY + catShape.halfH - catShape.foot, s.frame.maxY - catShape.halfH + 3 * scale)
        catBody = Body(pos: cat.position)
        stayWindow = nil
        mode = .staying(frame: 0)
        return true
    }

    private mutating func startFalling(velocity v: CGVector) {
        userLaunched = false
        lastThrow = .zero
        launchY = cat.position.y
        rising = v.dy > 0
        if mode == .returningBone { dropBone(falling: true) }
        catBody = Body(pos: cat.position, vel: v, angle: 0, spin: -v.dx / 150)
        flyFrame = 0
        mode = .flying
    }

    private func flailSprite() -> SpriteName {
        let v = catBody.vel
        let m = hypot(v.dx, v.dy)
        guard m > 40 else { return .alert }
        return NekoBrain.direction(diffX: -v.dx, diffY: v.dy, distance: m)
    }

    // MARK: - Nap spots

    private mutating func maybeStartNap(_ world: World) {
        guard !gravityMode, cat.sleepEnabled, cat.idleTime > 30, cat.idleAnimation == nil, random(sleepy ? 100 : 250) == 0,
              let spot = chooseSpot(world) else { return }
        mode = .goingToSpot(spot)
    }

    mutating func chooseSpot(_ world: World) -> NapSpot? {
        var options: [NapSpot] = []
        if box.isResting && !boxClosed {   // a box is irresistible
            options += Array(repeating: NapSpot(kind: .box, point: box.body.pos), count: 3)
        }
        if spotWindows, let s = windowSpot(world) { options.append(s) }
        if spotMenuBar, let s = menuBarSpot(world) { options.append(s) }
        if spotDock, let s = dockSpot(world) { options.append(s) }
        guard !options.isEmpty else { return nil }
        return options[random(options.count)]
    }

    private func windowSpot(_ world: World) -> NapSpot? {
        let margin = 24 * scale
        let candidates = world.windows.enumerated().filter {
            $0.element.frame.width >= 160 && $0.element.frame.height >= 80
        }.prefix(6)
        guard !candidates.isEmpty else { return nil }
        let (i, w) = Array(candidates)[random(candidates.count)]
        let span = Int(w.frame.width - 2 * margin)
        guard span > 0 else { return nil }
        let x = w.frame.minX + margin + CGFloat(random(span))
        let top = w.frame.maxY
        guard !world.isCovered(CGPoint(x: x, y: top - 2), inFrontOf: i),
              let s = world.screen(containing: CGPoint(x: x, y: top - 2)),
              top + 2 * cat.halfSize <= s.visible.maxY + 4
        else { return nil }
        return NapSpot(kind: .window(w.id), point: CGPoint(x: x, y: top + catShape.halfH - catShape.foot))
    }

    private func menuBarSpot(_ world: World) -> NapSpot? {
        guard catScale <= 1 else { return nil }   // a 2×/3× cat doesn't fit in the menu bar
        guard let s = world.screen(containing: cat.position) ?? world.screens.first else { return nil }
        let band = s.frame.maxY - s.visible.maxY
        guard band >= 18 else { return nil }   // hidden menu bar
        // The empty middle of the menu bar, between app menus and status items.
        let x = s.frame.midX + (CGFloat(random(1000)) / 1000 - 0.5) * 0.24 * s.frame.width
        let y = min(s.visible.maxY + catShape.halfH - catShape.foot, s.frame.maxY - catShape.halfH + 3 * scale)
        return NapSpot(kind: .menuBar, point: CGPoint(x: x, y: y))
    }

    private func dockSpot(_ world: World) -> NapSpot? {
        for s in world.screens {
            guard let d = s.dock else { continue }   // hidden Docks don't count
            if d.minY <= s.frame.minY + 1 && d.width >= d.height {       // bottom Dock: nap on top of it
                let room = max(0, min(120 * scale, d.width / 2 - catShape.halfW))
                let x = d.midX + (room > 0 ? CGFloat(random(Int(2 * room) + 1)) - room : 0)
                return NapSpot(kind: .dock, point: CGPoint(x: x, y: d.maxY + catShape.halfH - catShape.foot))
            }
            if d.minX <= s.frame.minX + 1 {                               // left Dock: curl up beside it
                return NapSpot(kind: .dock, point: CGPoint(x: d.maxX + catShape.halfW, y: s.frame.midY))
            }
            return NapSpot(kind: .dock, point: CGPoint(x: d.minX - catShape.halfW, y: s.frame.midY))
        }
        return nil
    }

    // MARK: - Yarn, catnip, waking up

    mutating func placeYarn(at p: CGPoint, falling: Bool) {
        yarn.body = Body(pos: p)
        yarn.state = falling ? .flying : .resting(onWindow: nil)
    }

    mutating func removeYarn() {
        if case .chasingYarn = mode { mode = .chasing }
        yarn.state = .hidden
    }

    /// Bat the yarn away (and it rolls off).
    private mutating func batYarn() {
        guard yarn.isOut, yarn.state != .held, yarn.state != .pinned, batCooldown == 0 else { return }
        let dir: CGFloat = yarn.body.pos.x >= cat.position.x ? 1 : -1
        yarn.state = .flying
        yarn.body.vel = CGVector(dx: dir * CGFloat(500 + random(500)), dy: CGFloat(250 + random(400)))
        yarn.body.spin = -dir * 12
        batCooldown = 12
        cat.set(.scratchSelf, 0)
        events.append(.batYarn)
    }

    /// Walking or sitting right next to the yarn: give it a pat.
    private mutating func batNearbyYarn() {
        guard yarn.isResting, !paused, batCooldown == 0 else { return }
        switch mode {
        case .chasing, .walking, .petted: break
        default: return
        }
        let d = hypot(yarn.body.pos.x - cat.position.x, yarn.body.pos.y - cat.position.y)
        if d < catShape.halfW + 6 * scale { batYarn() }
    }

    /// Catnip: zoomies for ~12 seconds.
    mutating func giveCatnip() {
        events.append(.heart)
        if gravityMode {
            zoomBoost = 120
            walkArrived = false
            return
        }
        switch mode {
        case .chasing, .petted, .staying, .dazed, .napping, .chasingYarn, .stretching:
            if inBox { return }
            mode = .zoomies(ticksLeft: 120, target: randomSpot())
        default:
            break
        }
    }

    private func randomSpot() -> CGPoint {
        guard let s = lastScreens.first(where: { $0.frame.contains(cat.position) }) ?? lastScreens.first else {
            return cat.position
        }
        let r = s.visible.insetBy(dx: catShape.halfW * 2, dy: catShape.halfH * 2)
        guard r.width > 0, r.height > 0 else { return cat.position }
        return CGPoint(x: r.minX + CGFloat(random(Int(r.width))), y: r.minY + CGFloat(random(Int(r.height))))
    }

    /// You're back: a big stretch, then it's up and about.
    mutating func stretchAwake() {
        switch mode {
        case .chasing, .staying, .petted:
            mode = .stretching(ticksLeft: 10)
            events.append(.woke)
        default:
            break
        }
    }

    // MARK: - Moving between worlds

    /// Arrive flying (e.g. yeeted up off the Touch Bar onto the desktop).
    mutating func launch(at p: CGPoint, velocity v: CGVector) {
        swing = nil
        cat.position = p
        startFalling(velocity: Physics.clampSpeed(v))
        catBody.spin = -v.dx / 120 + CGFloat(random(200) - 100) / 40
        userLaunched = true
        if hypot(v.dx, v.dy) > 2200 { angry = true }
    }

    /// Pull the cat and resting toys back inside `range` (e.g. the visible part of the
    /// Touch Bar), unless they're in the middle of being thrown or carried.
    mutating func keepInside(_ range: ClosedRange<CGFloat>) {
        func clamp(_ x: CGFloat, _ m: CGFloat) -> CGFloat { min(max(x, range.lowerBound + m), range.upperBound - m) }
        switch mode {
        case .held, .flying, .landing: break
        default:
            let x = clamp(cat.position.x, catShape.halfW)
            if x != cat.position.x {
                cat.position.x = x
                catBody.pos = cat.position
                walkArrived = false
            }
        }
        if bone.isResting || bone.state == .pinned { bone.body.pos.x = clamp(bone.body.pos.x, bone.shape.halfW) }
        if yarn.isResting || yarn.state == .pinned { yarn.body.pos.x = clamp(yarn.body.pos.x, yarn.shape.halfW) }
        if box.isResting || box.state == .pinned { box.body.pos.x = clamp(box.body.pos.x, box.shape.halfW) }
    }

    // MARK: - Gravity walking (Toolbox)

    private mutating func startWalking() {
        catBody = Body(pos: cat.position)
        walkArrived = false
        walkGrounded = false
        walkGoal = .cursor
        mode = .walking
    }

    /// The drawings changed (drawn, erased, cleared): check the footing again.
    mutating func groundChanged() {
        walkArrived = false
    }

    private func walkTarget(_ world: World) -> CGPoint {
        if paused { return cat.position }
        switch walkGoal {
        case .bone where bone.state == .flying || bone.isResting: return bone.body.pos
        case .nap where box.isResting: return box.body.pos
        default: return world.cursor
        }
    }

    private mutating func walk(dt: CGFloat, world: World) {
        walkFrame += 1
        if walkGoal == .bone && !(bone.state == .flying || bone.isResting) { walkGoal = .cursor }
        if walkGoal == .nap && !(box.isResting && !boxClosed) { walkGoal = .cursor }
        let target = walkTarget(world)
        let dx = target.x - cat.position.x
        let moving = abs(dx) > 6 && !walkArrived
        let speed = cat.speed * 10 * (walkGoal == .bone ? 1.3 : 1)   // same pace as classic oneko
            * (zoomBoost > 0 ? 3 : 1) * (laser ? 2.2 : 1)
        catBody.pos = cat.position
        catBody.vel.dx = moving ? (dx > 0 ? speed : -speed) : 0
        let result = Physics.step(&catBody, shape: catShape, dt: dt, world: world)
        cat.position = catBody.pos
        switch result {
        case .rested(_, let impact):
            walkGrounded = true
            if impact > 900 { squash = 0.75 }
        case .bounced(let impact):
            walkGrounded = false
            if impact > 900 { squash = 0.75 }
        case .flying:
            if catBody.airTime > 0.05 { walkGrounded = false }
        }
        squash += (1 - squash) * min(1, dt * 10)
        if abs(squash - 1) < 0.01 { squash = 1 }

        if !walkGrounded && catBody.airTime > 0.15 {
            cat.set(.alert, 0)                                   // falling!
        } else if moving {
            cat.set(dx > 0 ? .E : .W, walkFrame / 6)             // trotting along
        } else if !walkArrived {
            cat.set(.idle, 0)
        }

        // Reached the box: hop in for a nap.
        if walkGoal == .nap, walkGrounded, abs(box.body.pos.x - cat.position.x) < 8 {
            walkGoal = .cursor
            napFrame = 0
            cat.position = box.body.pos
            events.append(.boxHop)
            mode = .napping(NapSpot(kind: .box, point: box.body.pos), ticksLeft: 400 + random(800))
            return
        }

        // Fetch on foot.
        if walkGoal == .bone, abs(bone.body.pos.x - cat.position.x) < 14 * scale,
           abs(bone.body.pos.y - cat.position.y) < 30 * scale {
            bone.state = .carried
            walkGoal = .bringBack
            events.append(.boneTaken)
        }
        if walkGoal == .bringBack {
            bone.body.pos = cat.position
            if !moving && walkGrounded {
                dropBone(falling: true, toward: world.cursor)
                events.append(.fetched)
                walkGoal = .cursor
            }
        }
    }

    // MARK: - Toolbox

    /// Is `p` on the cat (roughly)?
    func catContains(_ p: CGPoint, slop: CGFloat = 0) -> Bool {
        if case .erased = mode { return false }
        return abs(p.x - cat.position.x) < catShape.halfW + slop
            && abs(p.y - cat.position.y) < catShape.halfH - catShape.foot + slop
    }

    /// A freshly drawn solid shape that cuts through the cat knocks it out of the way.
    mutating func drawingAdded(_ d: Drawing) {
        guard d.solid, catCanBeHit, !inBox else { return }
        for (a, b) in d.segments where Geometry.distance(cat.position, a, b) < catShape.halfW + d.width / 2 {
            var n = CGVector(dx: -(b.y - a.y), dy: b.x - a.x)
            let len = max(hypot(n.dx, n.dy), 0.001)
            n = CGVector(dx: n.dx / len, dy: n.dy / len)
            if (cat.position.x - a.x) * n.dx + (cat.position.y - a.y) * n.dy < 0 { n = CGVector(dx: -n.dx, dy: -n.dy) }
            angry = true
            startFalling(velocity: CGVector(dx: n.dx * 1500, dy: n.dy * 1500 + 500))
            return
        }
    }

    /// Eraser rubbing over the cat. Returns true if it touched the cat.
    @discardableResult
    mutating func erase(at p: CGPoint, radius: CGFloat) -> Bool {
        switch mode {
        case .erased, .held: return false
        default: break
        }
        guard !inBox, catContains(p, slop: radius) else { return false }
        hp = max(0, hp - 0.06)
        angry = true
        if hp <= 0 {
            if mode == .returningBone { dropBone(falling: true) }
            mode = .erased(ticksLeft: 20)
        }
        return true
    }

    /// Fill With Color landed on the cat.
    mutating func painted() {
        angry = true
        switch mode {
        case .chasing, .petted, .staying, .goingToSpot: mode = .dazed(ticksLeft: 3, onWindow: nil)
        default: break
        }
    }

    /// Airbrush spray on the cat: now and then it's had enough and sits there fuming.
    mutating func sprayed() {
        guard mode == .chasing, random(30) == 0 else { return }
        angry = true
        mode = .dazed(ticksLeft: 12, onWindow: nil)
    }

    /// A Paint selection closed around the cat: it's grabbed and frozen.
    mutating func capture() {
        switch mode {
        case .erased, .held: return
        default: break
        }
        if inBox { return }
        if mode == .returningBone { dropBone(falling: true) }
        swing = nil
        catBody = Body(pos: cat.position)
        squash = 1
        mode = .captured
    }

    mutating func moveCaptured(to p: CGPoint) {
        guard mode == .captured else { return }
        cat.position = p
        catBody.pos = p
    }

    /// Deselect: it drops, and it's not happy about it.
    mutating func releaseCaptured() {
        guard mode == .captured else { return }
        angry = true
        startFalling(velocity: .zero)
    }

    private mutating func respawn(_ world: World) {
        let s = world.screen(containing: world.cursor) ?? world.screens.first
        let top = (s?.visible.maxY ?? 800) - catShape.halfH
        cat.position = CGPoint(x: world.cursor.x, y: top)
        hp = 1
        angry = true     // back, and grumpy
        startFalling(velocity: CGVector(dx: 0, dy: -200))
    }

    // MARK: - The Dock is not a floor

    /// The Dock strips seen last tick (to tell "walked into it" from "it appeared under me").
    private var lastDocks: [CGRect] = []
    /// Ticks of grace after a Dock yeet, so it can't loop.
    private var dockCooldown = 0

    /// A cat that follows your cursor into a showing Dock gets yeeted up and out of it.
    /// Merely dipping its feet in (chasing a cursor just above the Dock), a Dock appearing
    /// underneath it, or being just after a yeet only nudges it back on top, so it never
    /// glitches on the ground.
    private mutating func dockBounce(_ world: World) {
        let docks = world.screens.compactMap(\.dock)
        defer { lastDocks = docks }
        if dockCooldown > 0 { dockCooldown -= 1 }

        // A Dock went away (auto-hide, or it moved to another display), or got shorter (an
        // app quit): whatever was sitting on a part that's gone falls to the bottom.
        for d in lastDocks where !docks.contains(d) && d.width >= d.height {
            let now = docks.first { $0.intersects(d) && abs($0.maxY - d.maxY) < 1.5 }
            func gone(_ x: CGFloat) -> Bool { now.map { x < $0.minX || x > $0.maxX } ?? true }
            var sitting = false
            switch mode {
            case .staying, .napping, .dazed, .petted: sitting = !inBox && catWindow == nil
            default: break
            }
            let feet = cat.position.y - catShape.halfH + catShape.foot
            if sitting, abs(feet - d.maxY) < 1.5, cat.position.x >= d.minX, cat.position.x <= d.maxX,
               gone(cat.position.x) {
                stayWindow = nil
                startFalling(velocity: .zero)
            }
            for i in 0..<2 {
                var p = i == 0 ? bone : box
                let bottom = p.body.pos.y - p.shape.halfH + p.shape.foot
                if p.isResting, p.restingWindow == nil, abs(bottom - d.maxY) < 1.5,
                   p.body.pos.x >= d.minX, p.body.pos.x <= d.maxX, gone(p.body.pos.x) {
                    p.state = .flying
                    p.body.vel = .zero
                    if i == 0 { bone = p } else { box = p }
                }
            }
        }
        for s in world.screens {
            guard let d = s.dock else { continue }
            let left = d.minX <= s.frame.minX + 1 && d.height > d.width
            let right = d.maxX >= s.frame.maxX - 1 && d.height > d.width
            let wasThere = lastDocks.contains { $0.intersects(d) }

            func feetIn(_ p: CGPoint, _ shape: Shape, margin: CGFloat = 0.01) -> Bool {
                d.contains(CGPoint(x: p.x, y: p.y - shape.halfH + shape.foot + margin))
            }
            /// The closest spot just outside the Dock.
            func onTop(_ p: CGPoint, _ shape: Shape) -> CGPoint {
                if left { return CGPoint(x: d.maxX + shape.halfW, y: p.y) }
                if right { return CGPoint(x: d.minX - shape.halfW, y: p.y) }
                return CGPoint(x: p.x, y: d.maxY + shape.halfH - shape.foot)
            }
            func out() -> CGVector {
                if left { return CGVector(dx: 1300, dy: 900) }
                if right { return CGVector(dx: -1300, dy: 900) }
                return CGVector(dx: CGFloat(random(600) - 300), dy: 1700)
            }

            let grounded: Bool
            switch mode {
            case .held, .flying, .landing, .pinned, .captured, .erased: grounded = false
            default: grounded = !inBox && catWindow == nil
            }
            var moving = false
            switch mode {
            case .chasing, .goingToSpot, .fetching, .returningBone, .walking: moving = true
            default: break
            }
            // Following your cursor into the Dock: the moment it touches the Dock (even just
            // standing on top of it, waiting above your cursor), it's yeeted.
            if grounded, moving, wasThere, dockCooldown == 0, d.contains(world.cursor),
               feetIn(cat.position, catShape, margin: -3) {
                let v = out()
                startFalling(velocity: v)
                catBody.spin = -v.dx / 150 + CGFloat(random(200) - 100) / 30
                dockCooldown = 20              // 2 s of grace
                events.append(.dockYeet)
            } else if grounded, feetIn(cat.position, catShape) {
                do {
                    cat.position = onTop(cat.position, catShape)   // just a dip: back on top
                    catBody.pos = cat.position
                }
            }
            if yarn.isResting, feetIn(yarn.body.pos, yarn.shape, margin: 2 * scale) {
                if wasThere { yarn.body.vel = out(); yarn.state = .flying }
                else { yarn.body.pos = onTop(yarn.body.pos, yarn.shape) }
            }
            if bone.isResting, feetIn(bone.body.pos, bone.shape, margin: 2 * scale) {
                if wasThere { bone.body.vel = out(); bone.body.spin = CGFloat(random(30) - 15); bone.state = .flying }
                else { bone.body.pos = onTop(bone.body.pos, bone.shape) }
            }
            if box.isResting, feetIn(box.body.pos, box.shape, margin: 2 * scale) {
                if wasThere { box.body.vel = out(); box.body.spin = CGFloat(random(6) - 3); box.state = .flying }
                else { box.body.pos = onTop(box.body.pos, box.shape) }
            }
        }
    }

    // MARK: - Windows: riding along, and getting hit

    /// Delta of a window's top-left since last tick; nil if it vanished.
    private func windowDelta(_ id: Int, _ world: World) -> CGVector? {
        if id < 0 { return world.drawing(id) != nil ? .zero : nil }   // drawings don't move
        guard let now = world.window(id)?.frame else { return nil }
        guard let old = lastWindows[id] else { return .zero }
        return CGVector(dx: now.minX - old.minX, dy: now.maxY - old.maxY)
    }

    /// A window flicked upward (or yanked hard) while something sits on it launches it.
    private func launch(_ d: CGVector, dt: CGFloat, mouseDown: Bool) -> CGVector? {
        let v = CGVector(dx: d.dx / dt, dy: d.dy / dt)
        guard mouseDown, v.dy > 500 || hypot(v.dx, v.dy) > 1800 else { return nil }
        return Physics.clampSpeed(CGVector(dx: v.dx * 1.6, dy: v.dy * 1.8 + 300))
    }

    private mutating func rideWindows(_ world: World, dt: CGFloat) {
        func ride(_ id: Int, apply: (CGVector) -> Void) -> Bool? {   // nil: window gone; false: launched
            guard let d = windowDelta(id, world) else { return nil }
            if let v = launch(d, dt: dt, mouseDown: world.mouseDown) {
                startFalling(velocity: v)
                userLaunched = true
                catBody.spin = -v.dx / 150 + CGFloat(random(200) - 100) / 60
                if hypot(v.dx, v.dy) > 2600 { angry = true }
                return false
            }
            apply(d)
            return true
        }
        switch mode {
        case .napping(var spot, let left):
            if case .window(let id) = spot.kind {
                switch ride(id, apply: { spot.point.x += $0.dx; spot.point.y += $0.dy }) {
                case nil: startFalling(velocity: .zero)   // the window closed under it
                case true?: cat.position = spot.point; mode = .napping(spot, ticksLeft: left)
                case false?: break
                }
            }
        case .goingToSpot(var spot):
            if case .window(let id) = spot.kind {
                if let d = windowDelta(id, world) {
                    spot.point.x += d.dx
                    spot.point.y += d.dy
                    mode = .goingToSpot(spot)
                } else {
                    mode = .chasing
                }
            }
        case .staying where stayWindow != nil:
            var p = cat.position
            switch ride(stayWindow!, apply: { p.x += $0.dx; p.y += $0.dy }) {
            case nil: stayWindow = nil; startFalling(velocity: .zero)
            case true?: cat.position = p
            case false?: stayWindow = nil
            }
        case .dazed(_, let win?):
            var p = cat.position
            switch ride(win, apply: { p.x += $0.dx; p.y += $0.dy }) {
            case nil: startFalling(velocity: .zero)
            case true?: cat.position = p
            case false?: break
            }
        default:
            break
        }
        Self.rideProp(&bone, world: world, last: lastWindows, dt: dt, launch: launch)
        Self.rideProp(&box, world: world, last: lastWindows, dt: dt, launch: launch)
        Self.rideProp(&yarn, world: world, last: lastWindows, dt: dt, launch: launch)
    }

    private static func rideProp(_ p: inout Prop, world: World, last: [Int: CGRect], dt: CGFloat,
                                 launch: (CGVector, CGFloat, Bool) -> CGVector?) {
        guard let id = p.restingWindow else { return }
        if id < 0 {   // resting on a drawing: fall if it's erased
            if world.drawing(id) == nil { p.state = .flying; p.body.vel = .zero }
            return
        }
        guard let now = world.window(id)?.frame else { p.state = .flying; return }
        guard let old = last[id] else { return }
        let d = CGVector(dx: now.minX - old.minX, dy: now.maxY - old.maxY)
        if let v = launch(d, dt, world.mouseDown) {
            p.body.vel = v
            p.body.spin = -v.dx / 80
            p.state = .flying
        } else {
            p.body.pos.x += d.dx
            p.body.pos.y += d.dy
        }
    }

    /// The window the cat is sitting on, if any (it rides that one instead of being hit by it).
    private var catWindow: Int? {
        switch mode {
        case .napping(let s, _): if case .window(let id) = s.kind { return id }
        case .dazed(_, let w): return w
        case .staying: return stayWindow
        default: break
        }
        return nil
    }

    private var catCanBeHit: Bool {
        switch mode {
        case .held, .flying, .landing, .pinned, .captured, .erased: return false
        default: return true
        }
    }

    private mutating func collide(_ world: World, dt: CGFloat) {
        for w in world.windows {
            guard let old = lastWindows[w.id], old != w.frame else { continue }
            let new = w.frame
            let sweep = old.union(new)
            func hits(_ p: CGPoint) -> Bool { !old.contains(p) && sweep.contains(p) }

            if catCanBeHit, catWindow != w.id, hits(cat.position) {
                let v = Self.knock(Self.push(old, new, at: cat.position, dt: dt))
                angry = true
                startFalling(velocity: v)
                userLaunched = true
                events.append(.bonked)
                catBody.spin = -v.dx / 150 + CGFloat(random(200) - 100) / 40
            } else if mode == .flying, hits(cat.position) {
                paddle(old: old, new: new, id: w.id, dt: dt)
            }
            if yarn.isResting || yarn.state == .flying, yarn.restingWindow != w.id, hits(yarn.body.pos) {
                yarn.body.vel = Self.knock(Self.push(old, new, at: yarn.body.pos, dt: dt))
                yarn.body.spin = -yarn.body.vel.dx / 30
                yarn.state = .flying
            }
            if bone.isResting || bone.state == .flying, bone.restingWindow != w.id, hits(bone.body.pos) {
                let v = Self.knock(Self.push(old, new, at: bone.body.pos, dt: dt))
                bone.body.vel = Physics.clampSpeed(CGVector(dx: v.dx + bone.body.vel.dx * 0.3, dy: v.dy))
                bone.body.spin = -bone.body.vel.dx / 50
                bone.state = .flying
            }
            if box.isResting, box.restingWindow != w.id, !inBox || boxClosed, hits(box.body.pos) {
                box.body.vel = Self.knock(Self.push(old, new, at: box.body.pos, dt: dt))
                box.body.spin = -box.body.vel.dx / 400
                box.state = .flying
            }
        }
    }

    /// A window swung into a flying cat: a gentle lift from underneath catches it on the
    /// title bar; anything else bats it away.
    private mutating func paddle(old: CGRect, new: CGRect, id: Int, dt: CGFloat) {
        let v = Self.push(old, new, at: cat.position, dt: dt)
        let feet = cat.position.y - catShape.halfH + catShape.foot
        let fromAbove = feet >= old.maxY - 4 && catBody.vel.dy <= 0
        if fromAbove && v.dy >= 0 && hypot(v.dx, v.dy) < 500 {
            cat.position.y = new.maxY + catShape.halfH - catShape.foot   // caught!
            catBody.pos = cat.position
            catBody.vel = .zero
            catBody.spin = 0
            squash = 0.8
            mode = .landing(elapsed: 0, onWindow: id)
            return
        }
        // Bat it: window speed plus a bit of what it had, and pop it outside the window.
        let k = Self.knock(v)
        catBody.vel = Physics.clampSpeed(CGVector(dx: k.dx + catBody.vel.dx * 0.3, dy: k.dy + max(0, catBody.vel.dy) * 0.3))
        catBody.spin += -k.dx / 150
        if abs(v.dy) >= abs(v.dx) {
            cat.position.y = v.dy > 0 ? new.maxY + catShape.halfH - catShape.foot + 1 : new.minY - catShape.halfH - 1
        } else {
            cat.position.x = v.dx > 0 ? new.maxX + catShape.halfW + 1 : new.minX - catShape.halfW - 1
        }
        catBody.pos = cat.position
        if hypot(k.dx, k.dy) > 2600 { angry = true }
        events.append(.bonked)
    }

    /// How fast the window edge facing `p` was moving (pt/s).
    static func push(_ old: CGRect, _ new: CGRect, at p: CGPoint, dt: CGFloat = 0.1) -> CGVector {
        if old.size == new.size {
            return CGVector(dx: (new.midX - old.midX) / dt, dy: (new.midY - old.midY) / dt)
        }
        let dx = p.x < old.midX ? new.minX - old.minX : new.maxX - old.maxX
        let dy = p.y < old.midY ? new.minY - old.minY : new.maxY - old.maxY
        return CGVector(dx: dx / dt, dy: dy / dt)
    }

    /// A bit harder than the window, with a hop, never a limp tap.
    static func knock(_ v: CGVector) -> CGVector {
        var k = CGVector(dx: v.dx * 2.0, dy: v.dy * 2.0 + 650)
        let m = hypot(k.dx, k.dy)
        if m < 1100, m > 0 { k = CGVector(dx: k.dx / m * 1100, dy: k.dy / m * 1100) }
        return Physics.clampSpeed(k)
    }
}
