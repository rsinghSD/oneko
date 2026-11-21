import CoreGraphics

extension Array {
    /// The element at `i`, or nil if it's out of range. Lives here, next to its hottest
    /// callers: without whole-module optimization a generic helper is only specialized
    /// (no runtime generic metadata lookups) in the file that defines it.
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

enum Thing: Equatable { case cat, bone, box, yarn, bowl }

/// Dice for the cats' whims (naps, hunts, idle animations). Thousands of cats roll them every
/// tick, and the system generator is a cryptographic one that reads the clock on every call;
/// this is wyrand, seeded once from the system generator. Main thread only, like the cats.
enum Dice {
    /// The state, behind a pointer: a plain `static var` would cost an exclusivity check per roll.
    private static let state: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        p.pointee = UInt64.random(in: .min ... .max)
        return p
    }()

    struct Generator: RandomNumberGenerator {
        mutating func next() -> UInt64 {
            Dice.state.pointee &+= 0xa076_1d64_78bd_642f
            let s = Dice.state.pointee
            let m = s.multipliedFullWidth(by: s ^ 0xe703_7ed1_a0b4_28db)
            return m.high ^ m.low
        }
    }

    /// A uniform roll in `0..<n` (0 when `n` < 1), like `Int.random(in: 0..<max(n, 1))`.
    static func roll(_ n: Int) -> Int {
        var g = Generator()
        return Int.random(in: 0..<max(n, 1), using: &g)
    }
}

/// Somewhere the cat can wander off to for a long nap.
struct NapSpot: Equatable {
    /// `box`: one of the real boxes; `heap`: one of the GPU-drawn boxes piled on the floor.
    enum Kind: Equatable {
        case box(Int), heap(Int), window(Int), menuBar, dock
        /// Right where it is (a nap after a good meal).
        case here
        var isBox: Bool {
            switch self {
            case .box, .heap: return true
            default: return false
            }
        }
    }
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
    case goingToBowl(Int)                         // hungry
    case eating(Int, ticksLeft: Int)
    case playing(PlayKind, ticksLeft: Int, leader: Bool)   // with another cat
    case exploring(Outing)                                 // off on its own: climbing a window, the menu bar
}

/// Left alone, a cat goes off on its own: up the side of a window and along its title bar,
/// or along the menu bar.
struct Outing: Equatable {
    /// `window`: up its side and along its title bar. `inside`: round the inside of its border.
    enum Place: Equatable { case window(Int), inside(Int), menuBar }
    enum Stage: Equatable { case approach, scratch, climb, stroll }
    var place: Place
    var stage: Stage = .approach
    /// Window: -1 climbs its left side, +1 its right side.
    var side: CGFloat = -1
    /// Ticks of strolling left.
    var ticksLeft: Int
    /// Strolling east (+1) or west (-1).
    var dir: CGFloat = 1
    /// Ticks to sit and look about (or groom) before strolling on.
    var pause = 0
    /// Where your cursor was when it set off: move it away and the cat comes running.
    var cursorAtStart: CGPoint
    /// Inside a window: how far round the border it is (from the bottom-left corner,
    /// anticlockwise).
    var along: CGFloat = 0
    /// Ticks of scratching the window's edge (a scratching post!) before moving on.
    var scratch = 0
    /// It's had its scratch at this corner (one per pass).
    var cornerDone = false
    /// Which window it's on or in, if any.
    var windowID: Int? {
        switch place {
        case .window(let id), .inside(let id): return id
        case .menuBar: return nil
        }
    }
}

/// What two cats get up to together.
enum PlayKind: Equatable, CaseIterable {
    case groom      // wash each other: hearts
    case fight      // a scrap: 💢, then they sit it off
    case chase      // one runs, the other chases
    var ticks: Int {
        switch self {
        case .groom: return 50
        case .fight: return 30
        case .chase: return 40
        }
    }
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
    /// In a big box: the box's own windows draw it (in front of and behind the cat).
    var inBigBox = false
    var clipped = false
    /// 1 = solid; the eraser fades it; 0 = rubbed out.
    var opacity: CGFloat = 1
    /// Wobble of a closed box with a cat that wants out.
    var rattle: CGFloat = 0
    /// Tucking in at a food bowl (a little fish bobs over its head).
    var eating = false
}

enum PlaygroundEvent: Equatable {
    case heart, boneTaken, boneDropped
    case thrown(speed: CGFloat)                           // let go of with some speed
    case apex(height: CGFloat)                            // top of a flight, above where it started
    case landed(impact: CGFloat, onWindow: Int?, at: CGPoint)
    case fetched, bonked, dockYeet, dockBonk, batYarn, boxHop, woke, ate, played
    case dinnerBell                                       // you clicked a bowl: everyone, come eat
    case scratched                                        // gave a window a good scratch
    case catBump                                          // knocked flying by another cat
}

/// Every toy: cardboard boxes, bones and balls of yarn. One pile is shared by every cat
/// (it's a class, so all the playgrounds holding it see the same toys): any cat naps in any
/// free box, fetches any bone and chases any ball of yarn. The first cat's playground (the
/// one with `ownsToys`) moves them; the others only play with them.
final class ToyPile {
    struct Box {
        var prop: Prop
        var closed = false
        /// The cat napping in it (`Playground.catID`).
        var napper: Int?
        /// A big box: twice the size, room for `bigSeats` cats, no flaps to shut.
        var big = false
        /// The cats in a big box, in seat order.
        var nappers: [Int] = []
        var occupied: Bool { big ? !nappers.isEmpty : napper != nil }
    }
    static let bigSeats = 4
    /// A bone or a ball of yarn.
    struct Toy {
        var prop: Prop
        /// Thrown or tossed: a cat should fetch it.
        var wanted = false
        /// The cat going for it (or carrying it), and how far off it was: a closer cat takes over.
        var fetcher: Int?
        var fetcherDistance: CGFloat = .infinity
    }
    /// Real boxes: you can pick them up, throw them and shut them.
    var boxes: [Box] = [] { didSet { rims = nil } }

    /// A resting box's rim, as a drawing things land on (see `Playground.boxTops`).
    struct Rim {
        var index: Int
        var top: CGFloat
        var drawing: Drawing
    }
    /// The rims of the resting boxes, built once and kept until a box changes. (Every walking
    /// cat asks for them every frame; building them each time was most of its frame.)
    private var rims: (scale: CGFloat, list: [Rim])?

    func restingRims(scale s: CGFloat) -> [Rim] {
        if let r = rims, r.scale == s { return r.list }
        var list: [Rim] = []
        for (i, b) in boxes.enumerated() where b.prop.isResting {
            let top = Self.rimY(b, scale: s)
            let hw = b.prop.shape.halfW
            list.append(Rim(index: i, top: top, drawing: Drawing(
                id: Playground.boxTopID - i, kind: .line,
                points: [CGPoint(x: b.prop.body.pos.x - hw, y: top), CGPoint(x: b.prop.body.pos.x + hw, y: top)],
                closed: false, color: RGBA(r: 0, g: 0, b: 0), width: 2)))
        }
        rims = (s, list)
        return list
    }

    /// The height of a box's rim (where the next box sits).
    static func rimY(_ b: Box, scale: CGFloat) -> CGFloat {
        b.prop.body.pos.y + 6 * (b.big ? 2 * scale : scale)
    }
    var bones: [Toy] = []
    var yarns: [Toy] = []

    /// A food bowl: a toy you can move, with a few meals of kibble in it.
    struct Bowl {
        var prop: Prop
        var food = Bowl.full
        static let full = 8
        /// A cat has eaten from it: once nobody's eating from it (or on the way), it's cleared away.
        var finished = false
    }
    var bowls: [Bowl] = []
    /// Boxes past the real ones: a heap on the floor, drawn by the graphics chip. They stay
    /// put, but a cat can still curl up in one near the top. Centres, global, y-up.
    var heap: [SIMD2<Float>] = []
    /// Heap boxes with a cat in them (heap index -> `Playground.catID`).
    var heapNappers: [Int: Int] = [:]
    private(set) var scale: CGFloat = 1

    static func shape(_ s: CGFloat, big: Bool = false) -> Shape {
        let k = big ? 2 * s : s
        return Shape(halfW: 14 * k, halfH: 16 * k, foot: 1 * k, bounce: 0.15)
    }

    /// Make box `i` a big box (or a normal one again).
    func setBig(_ i: Int, _ big: Bool) {
        guard i < boxes.count, boxes[i].big != big else { return }
        boxes[i].big = big
        boxes[i].closed = false
        boxes[i].prop.shape = Self.shape(scale, big: big)
        if boxes[i].prop.isResting { boxes[i].prop.state = .flying }   // settle at the new size
    }

    /// Where cat `cat` sits in box `i`: the middle, or its seat along a big box.
    func seat(_ i: Int, cat: Int) -> CGPoint? {
        guard let b = boxes[safe: i] else { return nil }
        guard b.big else { return b.prop.body.pos }
        let slot = b.nappers.firstIndex(of: cat) ?? b.nappers.count
        let xs: [CGFloat] = [-18, 6, -6, 18]
        return CGPoint(x: b.prop.body.pos.x + xs[slot % xs.count] * scale, y: b.prop.body.pos.y - 10 * scale)
    }
    static func boneShape(_ s: CGFloat) -> Shape { Shape(halfW: 8 * s, halfH: 3.5 * s, foot: 0, bounce: 0.45) }
    static func yarnShape(_ s: CGFloat) -> Shape { Shape(halfW: 6 * s, halfH: 6 * s, foot: 0, bounce: 0.55, rolls: true) }
    static func newBone(_ s: CGFloat) -> Prop { Prop(shape: boneShape(s), uprightStep: .pi) }
    static func newYarn(_ s: CGFloat) -> Prop { Prop(shape: yarnShape(s), uprightStep: .pi / 8) }
    static func bowlShape(_ s: CGFloat) -> Shape { Shape(halfW: 8 * s, halfH: 3.5 * s, foot: 0, bounce: 0.2) }

    var count: Int { boxes.count }

    func setScale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        for i in boxes.indices { boxes[i].prop.shape = Self.shape(s, big: boxes[i].big) }
        for i in bones.indices { bones[i].prop.shape = Self.boneShape(s) }
        for i in yarns.indices { yarns[i].prop.shape = Self.yarnShape(s) }
        for i in bowls.indices { bowls[i].prop.shape = Self.bowlShape(s) }
    }

    func placeBowl(_ i: Int, at p: CGPoint, falling: Bool) {
        while bowls.count <= i { bowls.append(Bowl(prop: Prop(shape: Self.bowlShape(scale), uprightStep: 2 * .pi))) }
        bowls[i].prop.body = Body(pos: p)
        bowls[i].prop.state = falling ? .flying : .resting(onWindow: nil)
    }

    /// Put box `i` at `p` (adding boxes up to `i` if needed).
    func place(_ i: Int, at p: CGPoint, falling: Bool) {
        while boxes.count <= i {
            boxes.append(Box(prop: Prop(shape: Self.shape(scale), uprightStep: 2 * .pi)))
        }
        boxes[i].prop.body = Body(pos: p)
        boxes[i].prop.state = falling ? .flying : .resting(onWindow: nil)
    }

    func placeBone(_ i: Int, at p: CGPoint, falling: Bool) {
        while bones.count <= i { bones.append(Toy(prop: Self.newBone(scale))) }
        bones[i] = Toy(prop: bones[i].prop)
        bones[i].prop.body = Body(pos: p)
        bones[i].prop.state = falling ? .flying : .resting(onWindow: nil)
    }

    func placeYarn(_ i: Int, at p: CGPoint, falling: Bool) {
        while yarns.count <= i { yarns.append(Toy(prop: Self.newYarn(scale))) }
        yarns[i] = Toy(prop: yarns[i].prop)
        yarns[i].prop.body = Body(pos: p)
        yarns[i].prop.state = falling ? .flying : .resting(onWindow: nil)
    }

    /// Keep only the first `n` boxes (cats napping in the others wake on their next tick).
    func truncate(_ n: Int) {
        if boxes.count > n { boxes.removeLast(boxes.count - n) }
    }

    /// Box `i` is resting, open and nobody's in it (or `cat` is).
    func isFree(_ i: Int, for cat: Int) -> Bool {
        guard let b = boxes[safe: i] else { return false }
        return Self.isFree(b, for: cat)
    }

    static func isFree(_ b: Box, for cat: Int) -> Bool {
        guard b.prop.isResting || b.prop.state == .pinned, !b.closed else { return false }
        if b.big { return b.nappers.contains(cat) || b.nappers.count < Self.bigSeats }
        return b.napper == nil || b.napper == cat
    }

    func heapPoint(_ i: Int) -> CGPoint? {
        guard i >= 0, i < heap.count else { return nil }
        return CGPoint(x: CGFloat(heap[i].x), y: CGFloat(heap[i].y))
    }

    /// Any toy moving (held, flying or settling): needs the 60 fps clock.
    var anyMoving: Bool {
        boxes.contains { Playground.propMoving($0.prop) } || bones.contains { Playground.propMoving($0.prop) }
            || yarns.contains { Playground.propMoving($0.prop) } || bowls.contains { Playground.propMoving($0.prop) }
    }
}

/// Finds cats sitting next to each other that could play together. A grid of buckets, so
/// it's linear in the number of cats.
enum PlayMatcher {
    /// Pairs of indices into `positions` (only where `free`), each cat in at most one pair.
    static func pairs(_ positions: [CGPoint], free: [Bool], radius r: CGFloat, chance: (Int) -> Int) -> [(Int, Int)] {
        var grid: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        func cell(_ p: CGPoint) -> (Int, Int) { (Int((p.x / r).rounded(.down)), Int((p.y / r).rounded(.down))) }
        for i in positions.indices where free[i] {
            let (x, y) = cell(positions[i])
            grid[key(x, y), default: []].append(i)
        }
        var taken = Set<Int>()
        var out: [(Int, Int)] = []
        for i in positions.indices where free[i] && !taken.contains(i) {
            let (x, y) = cell(positions[i])
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for j in grid[key(x + dx, y + dy)] ?? [] where j != i && !taken.contains(j) {
                        let a = positions[i], b = positions[j]
                        guard hypot(a.x - b.x, a.y - b.y) < r, chance(4) == 0 else { continue }
                        taken.insert(i); taken.insert(j)
                        out.append((i, j))
                        break search
                    }
                }
            }
        }
        return out
    }
}

/// Points on a grid of square cells, in flat arrays (no array per cell): a fixed number of
/// hashed buckets, filled with a counting sort. A bucket can hold points from more than one
/// cell, so callers check real distances.
struct BucketGrid {
    let cell: CGFloat
    private let mask: Int
    private var starts: [Int32]      // bucket b's points: order[starts[b] ..< starts[b + 1]]
    private var order: [Int32]

    init(_ points: [CGPoint], include: (Int) -> Bool, cell: CGFloat) {
        self.cell = cell
        var size = 64
        while size < points.count * 2 { size <<= 1 }
        mask = size - 1
        var counts = [Int32](repeating: 0, count: size + 1)
        var bucketOf = [Int32](repeating: -1, count: points.count)
        for i in points.indices where include(i) {
            let b = Self.bucket(points[i], cell, mask)
            bucketOf[i] = Int32(b)
            counts[b + 1] += 1
        }
        for b in 0..<size { counts[b + 1] += counts[b] }
        starts = counts
        var fill = counts
        order = [Int32](repeating: 0, count: Int(counts[size]))
        for i in points.indices where bucketOf[i] >= 0 {
            let b = Int(bucketOf[i])
            order[Int(fill[b])] = Int32(i)
            fill[b] += 1
        }
    }

    @inline(__always) private static func bucket(_ p: CGPoint, _ cell: CGFloat, _ mask: Int) -> Int {
        bucket(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)), mask)
    }
    @inline(__always) private static func bucket(_ x: Int, _ y: Int, _ mask: Int) -> Int {
        Int(truncatingIfNeeded: (UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F)) & mask
    }

    /// Every point in the cells overlapping `rect` (and maybe a few more: check distances).
    /// Each point once, even if two of those cells share a bucket.
    func forEach(in rect: CGRect, _ body: (Int) -> Void) {
        let x0 = Int((rect.minX / cell).rounded(.down)), x1 = Int((rect.maxX / cell).rounded(.down))
        let y0 = Int((rect.minY / cell).rounded(.down)), y1 = Int((rect.maxY / cell).rounded(.down))
        // Buckets already visited (two cells can share one), in a buffer on the stack.
        let cells = (x1 - x0 + 1) * (y1 - y0 + 1)
        withUnsafeTemporaryAllocation(of: Int.self, capacity: cells) { seen in
            var count = 0
            for gx in x0...x1 {
                for gy in y0...y1 {
                    let b = Self.bucket(gx, gy, mask)
                    var dup = false
                    for i in 0..<count where seen[i] == b { dup = true; break }
                    if dup { continue }
                    seen[count] = b
                    count += 1
                    for k in Int(starts[b])..<Int(starts[b + 1]) { body(Int(order[k])) }
                }
            }
        }
    }
}

/// Cats bumping into each other (0.6.5).
enum CatCollisions {
    /// Pairs of indices into `positions` closer than `reach` (each pair once), found with a grid
    /// so thousands of cats stay cheap. `skip`: cats that take no part.
    static func overlaps(_ positions: [CGPoint], skip: [Bool], reach r: CGFloat) -> [(Int, Int)] {
        guard r > 0, positions.count > 1 else { return [] }
        let grid = BucketGrid(positions, include: { !skip[$0] }, cell: r)
        var out: [(Int, Int)] = []
        for i in positions.indices where !skip[i] {
            let a = positions[i]
            grid.forEach(in: CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)) { j in
                guard j > i else { return }
                let b = positions[j]
                if (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) < r * r { out.append((i, j)) }
            }
        }
        return out
    }

    /// Reach cat `k` (0 is the first cat) and do something to it in place.
    typealias Access = (Int, (inout Playground) -> Void) -> Void

    private static func read(_ k: Int, _ cat: Access) -> (pos: CGPoint, kind: Playground.BodyKind, r: CGFloat) {
        var out = (pos: CGPoint.zero, kind: Playground.BodyKind.none, r: CGFloat(0))
        cat(k) { p in
            let b = Playground.body(&p)
            out = (b.pos, b.kind, Playground.bumpRadius(&p))
        }
        return out
    }

    /// 10 Hz: cats that have walked into each other are pushed apart, half each (sideways
    /// only for a cat on a window, the Dock or the ground). Napping cats, cats in boxes, cats
    /// you're holding and flying cats take no part. `swarmSpacing`: in a swarm squeezed closer
    /// than the cats are wide, they only keep that far apart. With `style.pinball`, two cats
    /// running into each other launch each other into the air; returns those cats.
    @discardableResult
    static func separate(count n: Int, skipFirst: Bool, swarmSpacing: CGFloat?, style: Style = .normal,
                         roll: (Int) -> Int = { Dice.roll($0) }, _ cat: Access) -> [Int] {
        var launched: [Int] = []
        guard n > 1, style.separates else { return launched }
        var pos: [CGPoint] = [], skip: [Bool] = [], radius: [CGFloat] = []
        pos.reserveCapacity(n); skip.reserveCapacity(n); radius.reserveCapacity(n)
        for k in 0..<n {
            let b = read(k, cat)
            pos.append(b.pos)
            skip.append(b.kind == .none || b.kind == .flying || (k == 0 && skipFirst))
            radius.append(b.r)
        }
        var squeeze: CGFloat = 1
        if let s = swarmSpacing { squeeze = min(1, s * 0.95 / max(2 * (radius.first ?? 1), 1)) }
        let reach = (radius.max() ?? 0) * 2 * squeeze
        for (i, j) in overlaps(pos, skip: skip, reach: reach) {
            let r = (radius[i] + radius[j]) * squeeze
            let push = separation(pos[i], pos[j], reach: r, tieBreak: i &+ j)
            guard push != .zero else { continue }
            // Total chaos: a real collision (not a squeezed swarm touching) sends both flying.
            if style.pinball > 0, squeeze >= 1, hypot(push.dx, push.dy) > r * 0.25, roll(3) == 0 {
                let m = max(hypot(push.dx, push.dy), 0.01)
                let nx = push.dx / m, ny = push.dy / m
                let up = style.pinball * 0.7
                var a = false, b = false
                cat(i) { a = $0.knockedByCat(CGVector(dx: nx * style.pinball, dy: ny * style.pinball + up), spin: style.spin) }
                cat(j) { b = $0.knockedByCat(CGVector(dx: -nx * style.pinball, dy: -ny * style.pinball + up), spin: style.spin) }
                if a { launched.append(i) }
                if b { launched.append(j) }
                if a || b { continue }
            }
            let half = CGVector(dx: push.dx / 2, dy: push.dy / 2)
            cat(i) { $0.shove(half) }
            cat(j) { $0.shove(CGVector(dx: -half.dx, dy: -half.dy)) }
        }
        return launched
    }

    /// How often (in 10 Hz ticks) to push cats apart: every tick, but with thousands of cats
    /// every third (still smooth, and a third of the work).
    static func separateEvery(_ cats: Int) -> Int { cats > 1000 ? 3 : 1 }

    /// How wild bumping is (Settings › Cats › Bumping).
    struct Style: Equatable {
        /// Cats push apart where they meet.
        var separates = true
        /// Thrown cats knock into others (and bounce off each other in mid-air).
        var knocks = true
        /// How hard a thrown cat sends another flying (1 = normal).
        var knock: CGFloat = 1
        /// And how much extra upward kick that gets (pt/s).
        var lift: CGFloat = 450
        /// The slowest throw that knocks a cat over (pt/s, toward it).
        var threshold: CGFloat = 250
        /// How much of its speed into the hit the thrown cat keeps.
        var keep: CGFloat = 0.3
        /// Mid-air: share of the closing speed traded (0.9 = a bit less than a perfect bounce;
        /// past 1, they fly apart faster than they came).
        var bounce: CGFloat = 0.9
        /// How much a knocked cat spins.
        var spin: CGFloat = 1
        /// Running into each other launches both cats this fast (0: they just push apart).
        var pinball: CGFloat = 0
        /// Up to this many cats in the air at once bounce off each other.
        var midAir = 100

        static let off = Style(separates: false, knocks: false)
        static let gentle = Style(knock: 0.5, lift: 150, threshold: 600, keep: 0.6, bounce: 0.5, spin: 0.5)
        static let normal = Style()
        static let crazy = Style(knock: 2, lift: 1000, threshold: 120, keep: 0.15, bounce: 1.3, spin: 2.5, midAir: 200)
        static let chaos = Style(knock: 3.2, lift: 1600, threshold: 60, keep: 0.05, bounce: 1.7, spin: 4,
                                 pinball: 1500, midAir: 300)
    }

    /// 60 fps: each flying cat in `flyers` that hits another cat up and about knocks it
    /// flying (and slows down); two flying cats bounce off each other. Returns the cats it
    /// knocked flying.
    static func bump(flyers: [Int], count n: Int, skipFirst: Bool, frame: CGFloat = 1.0 / 60, style: Style = .normal,
                     _ cat: Access) -> [Int] {
        var knocked: [Int] = []
        guard !flyers.isEmpty, n > 1, style.knocks else { return knocked }
        // Every cat that can be bumped, on a grid (thousands of cats, thousands thrown: still cheap).
        var pos = [CGPoint](repeating: .zero, count: n), rad = [CGFloat](repeating: 0, count: n)
        var maxR: CGFloat = 1
        var inPlay = [Bool](repeating: false, count: n)
        // A whole swarm in the air at once (the Dock bonked them all): they only knock into
        // cats on the ground, not each other (hundreds bouncing off each other is just noise,
        // and costly).
        let crowdedAir = flyers.count > style.midAir
        var any = false
        for k in 0..<n {
            let b = read(k, cat)
            pos[k] = b.pos; rad[k] = b.r
            maxR = max(maxR, b.r)
            inPlay[k] = b.kind != .none && !(crowdedAir && b.kind == .flying) && !(k == 0 && skipFirst)
            any = any || inPlay[k]
        }
        guard any else { return knocked }
        let grid = BucketGrid(pos, include: { inPlay[$0] }, cell: 2 * maxR)
        var near: [Int] = []
        for f in flyers {
            let me = read(f, cat)
            guard me.kind == .flying else { continue }
            var fv0 = CGVector.zero
            cat(f) { fv0 = Playground.velocity(&$0) }
            // Where it was a frame ago: a fast throw covers a lot of ground in a frame, so check
            // the whole stretch (no flying straight through a cat), and hit from that side.
            let prev = CGPoint(x: me.pos.x - fv0.dx * frame, y: me.pos.y - fv0.dy * frame)
            let minX = min(prev.x, me.pos.x), maxX = max(prev.x, me.pos.x)
            let minY = min(prev.y, me.pos.y), maxY = max(prev.y, me.pos.y)
            near.removeAll(keepingCapacity: true)
            let pad = me.r + maxR
            grid.forEach(in: CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)) { k in
                guard k != f else { return }
                let p = pos[k], reach = me.r + rad[k]
                if p.x > minX - reach, p.x < maxX + reach, p.y > minY - reach, p.y < maxY + reach { near.append(k) }
            }
            for k in near {
                let o = read(k, cat)                       // (now: it may have been knocked already)
                if crowdedAir && o.kind == .flying { continue }
                let reach = me.r + o.r
                guard o.kind != .none, o.pos.x > minX - reach, o.pos.x < maxX + reach,
                      o.pos.y > minY - reach, o.pos.y < maxY + reach else { continue }
                // The closest it came to that cat along the way.
                let sx = me.pos.x - prev.x, sy = me.pos.y - prev.y, len2 = sx * sx + sy * sy
                let t = len2 > 0 ? max(0, min(1, ((o.pos.x - prev.x) * sx + (o.pos.y - prev.y) * sy) / len2)) : 1
                let c = CGPoint(x: prev.x + sx * t, y: prev.y + sy * t)
                guard hypot(o.pos.x - c.x, o.pos.y - c.y) < reach else { continue }
                var dx = o.pos.x - prev.x, dy = o.pos.y - prev.y
                var d = hypot(dx, dy)
                if d < 0.01 { dx = o.pos.x - me.pos.x; dy = o.pos.y - me.pos.y; d = hypot(dx, dy) }
                guard d > 0.01 else { continue }
                let nx = dx / d, ny = dy / d
                var fv = CGVector.zero
                cat(f) { fv = Playground.velocity(&$0) }
                if o.kind == .flying {
                    // Both in the air: they bounce off each other (only while closing in).
                    var ov = CGVector.zero
                    cat(k) { ov = Playground.velocity(&$0) }
                    let closing = (fv.dx - ov.dx) * nx + (fv.dy - ov.dy) * ny
                    guard closing > 0 else { continue }
                    let j = closing * style.bounce
                    cat(f) { $0.setFlightVelocity(CGVector(dx: fv.dx - nx * j, dy: fv.dy - ny * j)) }
                    cat(k) { $0.setFlightVelocity(CGVector(dx: ov.dx + nx * j, dy: ov.dy + ny * j)) }
                } else {
                    // Into a cat that's up and about: it's knocked flying, the thrown one slows.
                    let along = fv.dx * nx + fv.dy * ny
                    guard along > style.threshold else { continue }      // just drifting past
                    let k1 = 0.5 * style.knock
                    let hit = CGVector(dx: (fv.dx + nx * along) * k1, dy: (fv.dy + ny * along) * k1 + style.lift)
                    var ok = false
                    cat(k) { ok = $0.knockedByCat(hit, spin: style.spin) }
                    guard ok else { continue }
                    let lose = 1 - style.keep
                    cat(f) { $0.setFlightVelocity(CGVector(dx: fv.dx - nx * along * lose, dy: fv.dy - ny * along * lose)) }
                    knocked.append(k)
                }
            }
        }
        return knocked
    }

    /// How far to push two overlapping cats apart (each moves its share along the line
    /// between them; a cat that can't be moved has share 0). Returns the push for `a`; `b`
    /// gets the opposite, scaled by its share.
    static func separation(_ a: CGPoint, _ b: CGPoint, reach: CGFloat, tieBreak: Int) -> CGVector {
        var dx = a.x - b.x, dy = a.y - b.y
        var d = hypot(dx, dy)
        if d < 0.01 {                                   // right on top of each other: pick a side
            dx = tieBreak % 2 == 0 ? 1 : -1; dy = 0; d = 1
        }
        let overlap = reach - d
        guard overlap > 0 else { return .zero }
        return CGVector(dx: dx / d * overlap, dy: dy / d * overlap)
    }
}

/// The cat, its toys and how they react to the desktop and the mouse. No AppKit.
struct Playground {
    var cat: NekoBrain
    private(set) var mode: CatMode = .chasing
    private(set) var catBody = Body(pos: .zero)
    private(set) var catShape = Shape(halfW: 13, halfH: 16, foot: 3, bounce: 0.35)
    private(set) var squash: CGFloat = 1
    private(set) var angry = false
    /// Every toy, shared with the other cats.
    var toys = ToyPile()
    /// Which cat this is (box and bone claims). The first cat is 0.
    var catID = 0
    /// This playground moves the toys (physics, windows, the Dock). Exactly one per pile.
    var ownsToys = true
    /// An auto-hiding Dock popping up underneath bonks whatever's sitting there.
    var dockBonk = true
    /// The bone this cat is after (or carrying) and the ball of yarn it's chasing, in the
    /// shared pile. `bone` and `yarn` read and write that one (a hidden stand-in if none).
    private(set) var boneIndex = 0
    private(set) var yarnIndex = 0
    /// Ticks since it last ate, and how many until it's hungry (20–40 minutes).
    private(set) var hunger = 0
    private var hungryAfter = 12_000
    var isHungry: Bool { hunger >= hungryAfter }
    /// For tests and the demo: skip ahead to dinner time.
    mutating func makeHungry() { hunger = hungryAfter }

    /// Dinner's served (you clicked a bowl, or Feed the Cats): it comes to eat now, hungry or
    /// not. A cat dozing in place, sitting it off or napping (not in a box) gets up for it.
    mutating func callToDinner() {
        guard !paused, !gravityMode else { return }
        hunger = max(hunger, hungryAfter)
        switch mode {
        case .staying, .petted, .dazed, .stretching, .chasingYarn, .zoomies, .goingToSpot:
            stayWindow = nil
            angry = false
            mode = .chasing
            cat.wakeUp()
        case .napping(let spot, _) where !spot.kind.isBox:
            mode = .chasing
            cat.wakeUp()
        default: break
        }
    }
    /// The cat it's playing with (kept up to date by the app).
    var partner: CGPoint?
    private var playTarget: CGPoint?

    /// Free to play with another cat: just sitting about.
    var canPlay: Bool {
        @inline(__always) get { !paused && !laser && !gravityMode && mode == .chasing && cat.idleTime > 15 }
    }

    var isPlaying: Bool { if case .playing = mode { return true }; return false }

    /// Start playing with the cat at `with`. The leader runs in a chase.
    mutating func startPlay(_ kind: PlayKind, with p: CGPoint, leader: Bool) {
        partner = p
        playTarget = nil
        napFrame = 0
        mode = .playing(kind, ticksLeft: kind.ticks, leader: leader)
        if leader { events.append(.played) }
    }
    // (`@inline(__always)` on the small helpers below: called from a mutating method, a
    // non-inlined getter gets a copy of the whole 900-byte playground.)
    var bone: Prop {
        @inline(__always) get { toys.bones[safe: boneIndex]?.prop ?? ToyPile.newBone(scale) }
        set { if boneIndex < toys.bones.count { toys.bones[boneIndex].prop = newValue } }
    }
    var yarn: Prop {
        @inline(__always) get { toys.yarns[safe: yarnIndex]?.prop ?? ToyPile.newYarn(scale) }
        set { if yarnIndex < toys.yarns.count { toys.yarns[yarnIndex].prop = newValue } }
    }

    /// Laser pointer mode: it dashes after the dot on your cursor and pounces on it.
    var laser = false
    /// Late at night: naps more often.
    var sleepy = false
    /// Left alone, it goes off exploring now and then (windows, the menu bar).
    var explores = false
    /// Exploring, it stops to scratch the edges of windows.
    var scratchesWindows = false
    /// How much it sleeps, relative to classic oneko (1): Settings › Behavior › Naps.
    var sleepiness: CGFloat = 1 { didSet { cat.sleepiness = sleepiness } }
    /// How long a nap lasts, relative to classic oneko.
    private var napLength: CGFloat { min(1.7, 0.3 + 0.7 * sleepiness) }
    private var zoomBoost = 0          // gravity mode's catnip: ticks of catnip speed
    private var batCooldown = 0
    private var launchY: CGFloat = 0
    private var rising = false
    /// The velocity you last threw the cat with (zero if it fell or was knocked).
    private(set) var lastThrow = CGVector.zero
    private(set) var scale: CGFloat = 1
    /// The box it's after on foot (gravity mode).
    private var walkBox: Int?
    /// Shut in a closed box after its nap, wanting out.
    private var rattling = false
    /// The boxes this cat holds a claim on (it's napping in them).
    private var claimedBox: Int?
    /// The box you just lifted it out of: let go over it and it doesn't drop straight back in
    /// (with the big box's wide opening, you couldn't get a cat out at all). Until it lands.
    private var liftedFromBox: Int?
    /// It has claimed a bone (`claimBone`) and not let go of it since: it may be the fetcher.
    private var mayHoldBone = false
    private var claimedHeap: Int?

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
    var random: (Int) -> Int = { Dice.roll($0) }

    private var events: [PlaygroundEvent] = []
    /// The current flight was your doing (a throw or a window you swung), not the cat's.
    private var userLaunched = false
    /// You put it on the Dock: once it has landed and sat a moment, it stays there.
    private var parkWhenSettled = false
    /// The window (or drawing) a parked cat is sitting on, so it rides along.
    private var stayWindow: Int?
    /// Parked on the inside of `stayWindow`'s bottom edge (it rides that edge, not the top).
    private var stayInside = false
    /// You put it there (on a window, the Dock, the menu bar): a cat that isn't sleepy runs up
    /// and down it. (Told to stay with a double-click, it sits.)
    private var roamsParked = false
    private var parkDir: CGFloat = 1
    private var parkPause = 0
    /// Let go of gently over a window: this flight lands inside it, on its bottom edge.
    private var dropInside: Int?
    private var lastScreens: [ScreenInfo] = []
    /// Where it was headed last tick (your cursor, or its spot in the swarm).
    private var lastCursor = CGPoint.zero
    /// `world.screenFrames`, kept while the screens stay the same (every tick would otherwise
    /// build a new array, for every cat).
    private var frames: (of: [ScreenInfo], frames: [CGRect]) = ([], [])
    private var napFrame = 0
    private var flyFrame = 0
    private var lastWindows: [Int: CGRect] = [:]
    /// The window list `lastWindows` was built from.
    private var lastWindowList: [WindowInfo] = []
    private var grab: Grab?
    private var swing: Swing?
    private var boneSwing: Swing?
    /// The bone that `boneSwing` swings (the one in your hand).
    private var boneSwingIndex = 0

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
        /// Which box, bone or ball of yarn.
        var index = 0
    }

    init(position: CGPoint) {
        cat = NekoBrain(position: position)
    }

    mutating func setScale(_ s: Int) {
        scale = CGFloat(s)
        applyCatSize()
        toys.setScale(scale)
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
        if case .napping(let s, _) = mode, s.kind.isBox { return true }
        return false
    }

    /// The real box it's napping in.
    var boxIndex: Int? {
        if case .napping(let s, _) = mode, case .box(let i) = s.kind { return i }
        return nil
    }

    /// The heap box it's napping in.
    var heapIndex: Int? {
        if case .napping(let s, _) = mode, case .heap(let i) = s.kind { return i }
        return nil
    }

    /// The first box (the only one on the Touch Bar and in tests); hidden if there's none.
    var box: Prop {
        toys.boxes.first?.prop ?? Prop(shape: ToyPile.shape(scale), uprightStep: 2 * .pi)
    }

    /// Is the box it's in shut? (Not in one: is the first box shut?)
    var boxClosed: Bool {
        @inline(__always) get {
            if heapIndex != nil { return false }
            return toys.boxes[safe: boxIndex ?? 0]?.closed ?? false
        }
    }

    /// Where the box it's in is.
    private var myBoxPos: CGPoint? {
        if let i = boxIndex { return toys.seat(i, cat: catID) }
        if let i = heapIndex { return toys.heapPoint(i) }
        return nil
    }

    /// Keep the pile's "who's in which box" in step with what this cat is doing.
    private mutating func syncClaims() {
        // (Only a cat that claimed a bone can be its fetcher, so the others skip looking: this
        // runs every frame for every flying cat.)
        if !fetchingBone, mayHoldBone {
            if toys.bones[safe: boneIndex]?.fetcher == catID {
                toys.bones[boneIndex].fetcher = nil
                toys.bones[boneIndex].fetcherDistance = .infinity
            }
            mayHoldBone = false
        }
        let b = boxIndex, h = heapIndex
        if claimedBox != b {
            if let c = claimedBox, c < toys.boxes.count {
                if toys.boxes[c].napper == catID { toys.boxes[c].napper = nil }
                toys.boxes[c].nappers.removeAll { $0 == catID }
            }
            if let n = b, n < toys.boxes.count {
                if toys.boxes[n].big {
                    if !toys.boxes[n].nappers.contains(catID) { toys.boxes[n].nappers.append(catID) }
                } else {
                    toys.boxes[n].napper = catID
                }
            }
            claimedBox = b
        }
        if claimedHeap != h {
            if let c = claimedHeap, toys.heapNappers[c] == catID { toys.heapNappers[c] = nil }
            if let n = h { toys.heapNappers[n] = catID }
            claimedHeap = h
        }
    }

    /// This cat is going away: let go of its box.
    mutating func leaveBoxes() {
        if inBox { mode = .chasing; cat.wakeUp() }
        syncClaims()
    }

    /// Start napping in real box `i`.
    private mutating func enterBox(_ i: Int) {
        let p = toys.boxes[i].prop.body.pos
        napFrame = 0
        mode = .napping(NapSpot(kind: .box(i), point: p), ticksLeft: 400 + random(800))   // 40 s – 2 min
        syncClaims()
        cat.position = toys.seat(i, cat: catID) ?? p
        catBody = Body(pos: cat.position)
    }

    /// Napping in a big box (it's drawn by the box's own windows, not the cat's).
    var inBigBox: Bool { boxIndex.map { toys.boxes[safe: $0]?.big ?? false } ?? false }

    /// The nearest free box to `p`, if any.
    private func nearestFreeBox(to p: CGPoint, within r: CGFloat = .infinity) -> Int? {
        var best: (Int, CGFloat)?
        for i in toys.boxes.indices where toys.isFree(i, for: catID) {
            let q = toys.boxes[i].prop.body.pos
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < r, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// The box nearest `p` (for grabbing).
    private func nearestBox(to p: CGPoint) -> Int? {
        toys.boxes.indices.filter { toys.boxes[$0].prop.isOut }.min {
            let a = toys.boxes[$0].prop.body.pos, b = toys.boxes[$1].prop.body.pos
            return hypot(a.x - p.x, a.y - p.y) < hypot(b.x - p.x, b.y - p.y)
        }
    }

    var catPose: CatPose {
        @inline(__always) get {
        let physical: Bool
        switch mode {
        case .held, .flying, .landing: physical = true
        default: physical = false
        }
        var showAnger = false
        switch mode {
        case .landing, .dazed: showAnger = angry
        case .playing(.fight, _, _): showAnger = true
        default: break
        }
        var rattle: CGFloat = 0
        if inBox, boxClosed, case .napping(_, let left) = mode, left <= 0 {
            rattle = CGFloat(sin(Double(napFrame) * 2.4)) * 0.12
        }
        return CatPose(sprite: cat.sprite, frame: cat.spriteFrame, center: cat.position,
                       angle: physical ? catBody.angle : 0, squash: squash,
                       angry: showAnger, inBox: inBox && !inBigBox,
                       carryingBone: mode == .returningBone || (mode == .walking && walkGoal == .bringBack),
                       boxClosed: boxClosed, inBigBox: inBigBox, clipped: { if case .pinned = mode { return true }; return false }(),
                       opacity: { if case .erased = mode { return 0 }; return hp }(),
                       rattle: rattle,
                       eating: { if case .eating = mode { return true }; return false }())
        }
    }

    /// True while something sits on a window or is in the air, so window positions must be
    /// read every tick (otherwise once a second is plenty).
    var needsWindowTracking: Bool {
        @inline(__always) get {
        if catWindow != nil { return true }   // riding something
        if ownsToys {
            // (Sitting on a box isn't riding a window: no need to read windows for that.)
            func tracked(_ p: Prop) -> Bool { (p.restingWindow.map { $0 > Self.boxTopID } ?? false) || p.state == .flying }
            if toys.boxes.contains(where: { tracked($0.prop) }) || toys.bones.contains(where: { tracked($0.prop) })
                || toys.yarns.contains(where: { tracked($0.prop) }) || toys.bowls.contains(where: { tracked($0.prop) }) { return true }
        }
        switch mode {
        case .goingToSpot(let s): if case .window = s.kind { return true }
        case .flying, .landing: return true
        case .walking: if !walkArrived { return true }
        default: break
        }
        return false
        }
    }

    /// Why physics is running (for ONEKO_DEBUG).
    var physicsReason: String {
        var r: [String] = []
        switch mode {
        case .held, .flying, .landing: r.append("cat \(mode)")
        case .walking where !walkArrived: r.append("walking")
        default: break
        }
        let mine = !ownsToys ? [] : toys.boxes.enumerated().map { ("box \($0.offset)", $0.element.prop) }
            + toys.bones.enumerated().map { ("bone \($0.offset)", $0.element.prop) }
            + toys.yarns.enumerated().map { ("yarn \($0.offset)", $0.element.prop) }
            + toys.bowls.enumerated().map { ("bowl \($0.offset)", $0.element.prop) }
        for (n, p) in mine {
            if p.state == .flying || p.state == .held { r.append("\(n) \(p.state)") }
            if p.isResting && abs(p.body.angle - p.settledAngle) > 0.001 { r.append("\(n) angle \(p.body.angle) vs \(p.settledAngle)") }
        }
        if squash != 1 { r.append("squash \(squash)") }
        return r.joined(separator: ", ")
    }

    /// True while anything needs the 60 fps physics clock.
    var needsPhysics: Bool {
        @inline(__always) get {
        switch mode {
        case .held, .flying, .landing: return true
        case .walking: if !walkArrived { return true }
        default: break
        }
        if ownsToys {
            if toys.anyMoving { return true }
        } else if let i = boxIndex, let b = toys.boxes[safe: i], Self.propMoving(b.prop) {
            return true   // riding in a box that's being carried or thrown
        }
        return squash != 1
        }
    }

    static func propMoving(_ p: Prop) -> Bool {
        if p.state == .flying || p.state == .held { return true }
        return p.isResting && abs(p.body.angle - p.settledAngle) > 0.001
    }

    // MARK: - Toys

    /// Put box `index` (the first by default) at `p`.
    mutating func placeBox(at p: CGPoint, falling: Bool, index: Int = 0) {
        toys.place(index, at: p, falling: falling)
    }

    /// Put every box away.
    mutating func removeBox() {
        removeBoxes(keeping: 0)
    }

    /// Keep only the first `n` toys.
    mutating func removeBoxes(keeping n: Int) {
        if let i = boxIndex, i >= n { mode = .chasing; cat.wakeUp() }
        toys.truncate(n)
        syncClaims()
    }

    /// Right-click: fold the flaps of box `index` (default: the one it's in, else the first)
    /// shut, or open them. A cat that's done napping in a closed box pops out when you open it.
    mutating func toggleBoxLid(_ index: Int? = nil) {
        let i = index ?? boxIndex ?? 0
        guard let b = toys.boxes[safe: i], b.prop.state != .hidden, !b.big else { return }   // big boxes have no flaps
        toys.boxes[i].closed.toggle()
        if !toys.boxes[i].closed, boxIndex == i, case .napping(_, let left) = mode, left <= 0 {
            popOutOfBox()
        }
    }

    private mutating func popOutOfBox() {
        rattling = false
        cat.wakeUp()
        startFalling(velocity: CGVector(dx: CGFloat(random(400) - 200), dy: 1000))
    }

    /// Put bone `index` (the first by default) at `p`.
    mutating func placeBone(at p: CGPoint, falling: Bool, index: Int = 0) {
        toys.placeBone(index, at: p, falling: falling)
    }

    /// Put every bone away.
    mutating func removeBone() { removeBones(keeping: 0) }

    /// Keep only the first `n` bones (a cat after one of the others gives up).
    mutating func removeBones(keeping n: Int) {
        if boneIndex >= n, mode == .fetching || mode == .returningBone { mode = .chasing }
        if boneIndex >= n, walkGoal == .bone || walkGoal == .bringBack { walkGoal = .cursor }
        if toys.bones.count > n { toys.bones.removeLast(toys.bones.count - n) }
        if boneIndex >= max(n, 1) { boneIndex = 0 }
    }

    /// Is this cat busy with its bone (going for it, or bringing it back)?
    private var fetchingBone: Bool {
        mode == .fetching || mode == .returningBone || (mode == .walking && (walkGoal == .bone || walkGoal == .bringBack))
    }

    /// A thrown bone this cat should go for: the closest free one, or one another cat is
    /// going for from much further away.
    private func wantedBone() -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        let bones = toys.bones   // one read of the shared pile, not one per bone
        let p = cat.position
        for i in bones.indices {
            let b = bones[i]
            guard b.wanted, b.prop.state == .flying || b.prop.isResting else { continue }
            let d = hypot(b.prop.body.pos.x - p.x, b.prop.body.pos.y - p.y)
            guard b.fetcher == nil || b.fetcher == catID || d < b.fetcherDistance - 40 * scale else { continue }
            if d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best
    }

    private mutating func claimBone(_ i: Int, distance d: CGFloat) {
        boneIndex = i
        mayHoldBone = true
        toys.bones[i].fetcher = catID
        toys.bones[i].fetcherDistance = d
    }

    // MARK: - 10 Hz behaviour

    /// Call with each fresh window list (10–30×/s). `dt`: seconds since the previous list.
    mutating func updateWindows(_ world: World, dt: CGFloat) {
        let dt = max(dt, 0.01)
        if mode == .walking, world.windows.contains(where: { lastWindows[$0.id] != $0.frame }) { walkArrived = false }
        rideWindows(world, dt: dt)
        if world.mouseDown { collide(world, dt: dt) }
        // Rebuild the lookup only when the list changed (it's shared by every cat, and
        // usually the same as last time).
        if !world.windows.elementsEqual(lastWindowList, by: { $0.id == $1.id && $0.frame == $1.frame }) {
            lastWindows = Dictionary(world.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
            lastWindowList = world.windows
        }
    }

    /// The frames of `world.screens` (cached: the same screens give the same array).
    private mutating func screenFrames(_ world: World) -> [CGRect] {
        if world.screens != frames.of { frames = (world.screens, world.screenFrames) }
        return frames.frames
    }

    mutating func tick10(world: World) {
        lastScreens = world.screens
        lastCursor = world.cursor
        if batCooldown > 0 { batCooldown -= 1 }
        if zoomBoost > 0 { zoomBoost -= 1 }
        defer { batNearbyYarn() }
        defer { syncClaims() }
        if !paused { hunger += 1 }
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
        // The closest cat goes for a thrown bone; a closer one can take over on the way.
        if !paused, !fetchingBone, !toys.bones.isEmpty, let (i, d) = wantedBone() {
            switch mode {
            case .chasing, .petted, .goingToSpot, .exploring:
                claimBone(i, distance: d)
                mode = .fetching
            case .napping(let spot, _) where !spot.kind.isBox:
                claimBone(i, distance: d)
                mode = .fetching
            case .walking:
                claimBone(i, distance: d)
                walkGoal = .bone          // on foot
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
                cat.tick(cursor: world.cursor, screens: screenFrames(world))
                if !paused { maybeStartNap(world) }
                if !paused, mode == .chasing { maybeExplore(world) }
            }
            // Dinner time, and there's kibble out.
            if !paused, !laser, isHungry, let i = nearestBowlWithFood() {
                mode = .goingToBowl(i)
                break
            }
            // A rolling ball? Must chase (any ball rolling by).
            if !paused, !laser, let i = rollingYarn() {
                yarnIndex = i
                mode = .chasingYarn(ticksLeft: 50)
            }


        case .goingToSpot(var spot):
            switch spot.kind {
            case .box(let i):
                // Someone else got there first, or it was picked up: never mind.
                guard toys.isFree(i, for: catID), toys.boxes[i].prop.isResting else { mode = .chasing; break }
                spot.point = toys.boxes[i].prop.body.pos
            case .heap(let i):
                guard let p = toys.heapPoint(i), toys.heapNappers[i] == nil || toys.heapNappers[i] == catID
                else { mode = .chasing; break }
                spot.point = p
            default: break
            }
            guard case .goingToSpot = mode else { break }
            if cat.walk(to: spot.point) {
                if spot.kind.isBox { events.append(.boxHop) }
                napFrame = 0
                mode = .napping(spot, ticksLeft: Int(CGFloat(400 + random(800)) * napLength))   // classic: 40 s – 2 min
                syncClaims()
            } else {
                mode = .goingToSpot(spot)
            }

        case .napping(let spot, let left):
            squash = 1
            switch spot.kind {
            case .box(let i):
                // The cat stays in the box wherever it goes: carried, thrown or caught.
                guard let b = toys.boxes[safe: i], b.prop.state != .hidden else { mode = .chasing; cat.wakeUp(); break }
                cat.position = toys.seat(i, cat: catID) ?? b.prop.body.pos
            case .heap(let i):
                guard let p = toys.heapPoint(i) else { mode = .chasing; cat.wakeUp(); break }
                cat.position = p
            default:
                cat.position = spot.point
            }
            guard case .napping = mode else { break }
            cat.set(napFrame < 8 ? .tired : .sleeping, napFrame / 4)
            napFrame += 1
            if left == 0, inBigBox {
                // The big box: it naps on until you take it out (or double-click it awake).
                mode = .napping(spot, ticksLeft: 0)
            } else if left <= 0 {
                if boxClosed {
                    rattling = true
                    mode = .napping(spot, ticksLeft: 0)   // wants out: the box rattles
                } else if rattling {
                    popOutOfBox()                         // someone opened it: out it pops
                } else {
                    mode = .chasing
                    cat.wakeUp()
                    events.append(.woke)
                }
            } else {
                rattling = left - 1 <= 0 && boxClosed   // nap's over, and it's shut in
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
                    roamsParked = true
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
            guard bone.state == .flying || bone.isResting, toys.bones[safe: boneIndex]?.fetcher == catID
            else { mode = .chasing; break }   // gone, or a closer cat took over
            toys.bones[boneIndex].fetcherDistance = hypot(cat.position.x - bone.body.pos.x, cat.position.y - bone.body.pos.y)
            // Line the cat's feet up with the bone's bottom.
            let target = CGPoint(x: bone.body.pos.x,
                                 y: bone.body.pos.y - bone.shape.halfH + catShape.halfH - catShape.foot)
            let near = hypot(cat.position.x - bone.body.pos.x, cat.position.y - bone.body.pos.y) < 18 * scale
            if near || cat.walk(to: target, speedMultiplier: 1.3) {
                bone.state = .carried
                toys.bones[boneIndex].wanted = false
                events.append(.boneTaken)
                mode = .returningBone
            }

        case .returningBone:
            let c = world.pointer ?? world.cursor   // to you, not to its spot in the swarm
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
            if dozesWhenStaying {
                cat.set(n < 8 ? .tired : .sleeping, n / 4)
            } else if roamsParked, let r = parkedSurface(world) {
                roamParked(r)
            } else {
                // Not sleepy: it sits there wide awake, looking about and washing now and then.
                let t = n % 150
                cat.set(t >= 120 && t < 134 ? .scratchSelf : t >= 60 && t < 66 ? .alert : .idle, t)
            }
            mode = .staying(frame: n + 1)

        case .chasingYarn(let left):
            let y = yarn   // (a read of the shared pile each time otherwise)
            let near = hypot(y.body.pos.x - cat.position.x, y.body.pos.y - cat.position.y) < catShape.halfW + 8 * scale
            if !y.isOut || y.state == .held || left <= 0 || paused {
                mode = .chasing
            } else if near || cat.walk(to: y.body.pos, speedMultiplier: 1.5) {
                batYarn()
                mode = .chasing
            } else {
                mode = .chasingYarn(ticksLeft: left - 1)
            }

        case .zoomies(let left, var target):
            if cat.walk(to: target, speedMultiplier: Self.catnipSpeed) || random(25) == 0 { target = randomSpot() }
            if left % 20 == 0 { events.append(.heart) }
            mode = left <= 0 ? .chasing : .zoomies(ticksLeft: left - 1, target: target)

        case .stretching(let left):
            cat.set(left > 4 ? .tired : .alert, 0)          // big yawn and stretch, then up
            mode = left <= 0 ? .chasing : .stretching(ticksLeft: left - 1)

        case .walking:
            let target = walkTarget(world)
            if walkGrounded, walkGoal == .cursor, abs(target.x - cat.position.x) <= 6 {
                if !walkArrived { cat.wakeUp(); cat.tick(cursor: cat.position, screens: screenFrames(world)) }
                walkArrived = true
                // Classic idle life (grooming, yawning, naps) while it waits under you.
                cat.tick(cursor: cat.position, screens: screenFrames(world))
                // ...and a box nearby is irresistible: walk over and climb in.
                if !paused, cat.sleepEnabled, cat.idleTime > 30, random(Int(250 / max(sleepiness, 0.05))) == 0,
                   let i = nearestFreeBox(to: cat.position), toys.boxes[i].prop.isResting {
                    walkGoal = .nap
                    walkBox = i
                    walkArrived = false
                }
            } else {
                walkArrived = false
            }

        case .goingToBowl(let i):
            guard !paused, let b = toys.bowls[safe: i], b.prop.isResting, b.food > 0 else { mode = .chasing; break }
            if cat.walk(to: bowlSpot(b)) {
                napFrame = 0
                mode = .eating(i, ticksLeft: 40)
            }

        case .eating(let i, let left):
            guard let b = toys.bowls[safe: i], b.prop.isResting else { mode = .chasing; break }
            cat.position = bowlSpot(b)
            cat.set(napFrame % 6 < 3 ? .idle : .alert, 0)     // nom, nom
            napFrame += 1
            if left <= 0 {
                if toys.bowls[i].food > 0 { toys.bowls[i].food -= 1 }
                toys.bowls[i].finished = true
                hunger = 0
                hungryAfter = 12_000 + random(12_000)
                events.append(.ate)
                events.append(.heart)
                napFrame = 0
                if cat.sleepEnabled && CGFloat(random(100)) < 50 * sleepiness {   // a food coma
                    mode = .napping(NapSpot(kind: .here, point: cat.position), ticksLeft: Int(CGFloat(300 + random(300)) * napLength))
                } else {
                    mode = .chasing
                }
            } else {
                mode = .eating(i, ticksLeft: left - 1)
            }

        case .playing(let kind, let left, let leader):
            let p = partner ?? cat.position
            guard !paused, left > 0 else {
                partner = nil
                if kind == .fight { angry = true; mode = .dazed(ticksLeft: 8, onWindow: nil) }   // sits it off
                else { mode = .chasing; cat.wakeUp() }
                break
            }
            switch kind {
            case .groom:
                cat.set(napFrame % 10 < 5 ? .scratchSelf : .idle, napFrame / 2)
                if leader && left % 15 == 0 { events.append(.heart) }
            case .fight:
                cat.set(p.x >= cat.position.x ? .scratchWallE : .scratchWallW, napFrame / 2)
            case .chase:
                if leader {
                    if playTarget == nil || random(15) == 0 {
                        let a = CGFloat(random(628)) / 100
                        let r = (120 + CGFloat(random(120))) * scale
                        playTarget = CGPoint(x: cat.position.x + cos(a) * r, y: cat.position.y + sin(a) * r)
                    }
                    if let t = playTarget, cat.walk(to: clampToScreens(t), speedMultiplier: 1.9) { playTarget = nil }
                } else {
                    _ = cat.walk(to: p, speedMultiplier: 2.0)
                }
            }
            napFrame += 1
            mode = .playing(kind, ticksLeft: left - 1, leader: leader)

        case .exploring(var o):
            // You moved the mouse (or it's bedtime): it drops what it's doing and comes running.
            if paused || laser || hypot(world.cursor.x - o.cursorAtStart.x, world.cursor.y - o.cursorAtStart.y) > 90 * scale {
                if case .window = o.place, o.stage == .climb { startFalling(velocity: .zero); break }   // lets go of the wall
                if case .inside(let id) = o.place, o.stage == .stroll, let f = world.window(id)?.frame,
                   let loop = insideLoop(f), Self.loopSegment(o.along, loop) != 0 {
                    startFalling(velocity: .zero)                                                      // lets go of the border
                    break
                }
                mode = .chasing
                cat.wakeUp()
                break
            }
            if explore(&o, world) { mode = .exploring(o) }

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
        if ownsToys { dropUnsupported() }
        switch mode {
        case .walking:
            walk(dt: dt, world: world)

        case .flying:
            flyFrame += 1
            if let id = dropInside, let f = world.window(id)?.frame, cat.position.y - catShape.halfH > f.maxY {
                dropInside = nil                     // flew out over the top
            }
            let result = Physics.step(&catBody, shape: catShape, dt: dt, world: world, inside: dropInside)
            cat.position = catBody.pos
            cat.set(flailSprite(), flyFrame / 4)
            if rising && catBody.vel.dy <= 0 {
                rising = false
                events.append(.apex(height: cat.position.y - launchY))
            }
            if let i = dropsIntoBox {
                // Plop! Straight into the box, and very pleased about it.
                angry = false
                squash = 0.8
                events.append(.heart)
                events.append(.boxHop)
                enterBox(i)
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
                stayInside = win != nil && win == dropInside
                dropInside = nil
                events.append(.landed(impact: impact, onWindow: win, at: cat.position))
                if impact > 1300 { angry = true }
                // You put it on the Dock or on a window: it'll stay there.
                if userLaunched && (win != nil || landedOnDock(world)) { parkWhenSettled = true }
                liftedFromBox = nil
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
        if ownsToys {
            let i = boneSwingIndex
            if i < toys.bones.count, toys.bones[i].prop.state == .held, var s = boneSwing {
                Self.steer(&s, &toys.bones[i].prop.body, dt: dt, sway: false)
                boneSwing = s
                toys.bones[i].prop.body.pos = s.pivot
            }
            for i in toys.boxes.indices where Self.propMoving(toys.boxes[i].prop) {
                Self.stepProp(&toys.boxes[i].prop, dt: dt, world: boxTops(world, except: i))
            }
            // The boxes are done moving for this frame: their rims are the same for every
            // bone, ball and bowl, so build them once (and only if something's moving).
            var tops: World?
            func rims() -> World {
                if let t = tops { return t }
                let t = boxTops(world)
                tops = t
                return t
            }
            for i in toys.bones.indices where Self.propMoving(toys.bones[i].prop) {
                Self.stepProp(&toys.bones[i].prop, dt: dt, world: rims())
            }
            for i in toys.yarns.indices where Self.propMoving(toys.yarns[i].prop) {
                Self.stepProp(&toys.yarns[i].prop, dt: dt, world: rims())
            }
            for i in toys.bowls.indices where Self.propMoving(toys.bowls[i].prop) {
                Self.stepProp(&toys.bowls[i].prop, dt: dt, world: rims())
            }
        }
        if let p = myBoxPos { cat.position = p }   // riding in a box
        syncClaims()
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

    /// `index`: which box, bone or ball of yarn (default: for a box, the one the cat is in,
    /// else the nearest; for a bone or yarn, the first).
    mutating func mouseDown(on thing: Thing, at p: CGPoint, time: Double, index: Int? = nil) {
        var i = index ?? 0
        if thing == .box, index == nil { i = boxIndex ?? nearestBox(to: p) ?? 0 }
        let c = position(of: thing, index: i)
        grab = Grab(thing: thing, offset: CGVector(dx: c.x - p.x, dy: c.y - p.y), start: p,
                    samples: [(time, p)], index: i)
    }

    /// A toy in the pile by kind and index (nil for the cat, or one that's gone).
    private func prop(_ thing: Thing, _ i: Int) -> Prop? {
        switch thing {
        case .cat: return nil
        case .box: return toys.boxes[safe: i]?.prop
        case .bone: return toys.bones[safe: i]?.prop
        case .yarn: return toys.yarns[safe: i]?.prop
        case .bowl: return toys.bowls[safe: i]?.prop
        }
    }

    private mutating func withProp(_ thing: Thing, _ i: Int, _ f: (inout Prop) -> Void) {
        switch thing {
        case .cat: break
        case .box: if i < toys.boxes.count { f(&toys.boxes[i].prop) }
        case .bone: if i < toys.bones.count { f(&toys.bones[i].prop) }
        case .yarn: if i < toys.yarns.count { f(&toys.yarns[i].prop) }
        case .bowl: if i < toys.bowls.count { f(&toys.bowls[i].prop) }
        }
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
                withProp(.bone, g.index) { $0.body.pos = c }
            case .box:
                withProp(.box, g.index) { $0.body.pos = c }
                if boxIndex == g.index { cat.position = toys.seat(g.index, cat: catID) ?? c }
            case .yarn, .bowl:
                withProp(g.thing, g.index) { $0.body.pos = c }
            }
        }
        grab = g
    }

    mutating func mouseUp(at p: CGPoint, time: Double, clickCount: Int = 1) {
        guard var g = grab else { return }
        grab = nil
        guard g.dragging else { click(g.thing, index: g.index, count: clickCount); return }
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
            // Let go of gently over a window (below its title bar): it drops in and lands on
            // the window's bottom edge, inside. (Thrown hard, it flies as before: a slam still
            // drops it into the Touch Bar.)
            dropInside = speed < 900 ? lastWindowList.first(where: {
                $0.frame.contains(cat.position) && cat.position.y < $0.frame.maxY - Self.titleBar * scale
                    && $0.frame.width > 4 * catShape.halfW && $0.frame.height > 3 * catShape.halfH
            })?.id : nil
            launchY = cat.position.y
            rising = catBody.vel.dy > 0
            events.append(.thrown(speed: speed))
        case .bone:
            withProp(.bone, g.index) {
                $0.body.vel = v
                if abs($0.body.spin) < 3 { $0.body.spin = max(-30, min(30, -v.dx / 50)) }  // else keep its twirl
                $0.state = .flying
            }
            boneSwing = nil
            if speed > 300, g.index < toys.bones.count { toys.bones[g.index].wanted = true }
        case .box, .bowl:
            withProp(g.thing, g.index) {
                $0.body.vel = CGVector(dx: v.dx * 0.7, dy: v.dy * 0.7)
                $0.body.spin = -v.dx / 400
                $0.state = .flying
            }
        case .yarn:
            withProp(.yarn, g.index) {
                $0.body.vel = v
                $0.body.spin = -v.dx / 40
                $0.state = .flying
            }
        }
    }

    var isDragging: Bool { grab?.dragging ?? false }

    /// Told to stay or parked (on the Dock, a window, the menu bar): does it doze off there?
    /// Only a sleepy cat (Often, Very Sleepy); otherwise it sits there awake.
    var dozesWhenStaying: Bool { cat.sleepEnabled && sleepiness >= 1 }

    /// Staying put where you left it (asleep or not): double-click to let it go.
    var isStaying: Bool { if case .staying = mode { return true }; return false }

    /// Asleep until you wake it: told to stay, parked, or off napping somewhere.
    var isSleeping: Bool {
        switch mode {
        case .staying: return dozesWhenStaying
        case .napping: return !(inBox && boxClosed)
        default: return false
        }
    }

    /// Right-click. Mid-drag: clip whatever you're dragging right there. On a clipped thing:
    /// let go (it falls). On the cat: clip it where it is (even mid-flight). On the box (or
    /// the cat in it): open/close the flaps. `index`: which box, bone or ball of yarn.
    mutating func rightClick(_ thing: Thing, index: Int? = nil) {
        if let g = grab, g.dragging {
            grab = nil
            clip(g.thing, index: g.index)
            return
        }
        grab = nil
        switch thing {
        case .cat:
            if boxIndex != nil { toggleBoxLid(); return }
            if heapIndex != nil { return }       // heap boxes have no flaps
            if case .pinned = mode { startFalling(velocity: .zero) } else { clip(.cat) }
        case .box:
            let i = index ?? boxIndex ?? 0
            guard i < toys.boxes.count else { return }
            if toys.boxes[i].prop.state == .pinned { Self.unclip(&toys.boxes[i].prop) } else { toggleBoxLid(i) }
        case .bone, .yarn, .bowl:
            let i = index ?? 0
            guard let p = prop(thing, i) else { return }
            if p.state == .pinned { withProp(thing, i) { Self.unclip(&$0) } } else if p.isOut { clip(thing, index: i) }
        }
    }

    private mutating func clip(_ thing: Thing, index i: Int = 0) {
        switch thing {
        case .cat:
            if mode == .returningBone { dropBone(falling: true) }
            swing = nil
            catBody = Body(pos: cat.position)
            squash = 1
            mode = .pinned(frame: 0)
            cat.set(.idle, 0)
            return
        case .bone:
            if mode == .fetching && boneIndex == i { mode = .chasing }
            if i < toys.bones.count { toys.bones[i].wanted = false }
            boneSwing = nil
        case .yarn:
            if case .chasingYarn = mode, yarnIndex == i { mode = .chasing }
        case .box, .bowl:
            break
        }
        withProp(thing, i) {
            $0.state = .pinned
            $0.body.vel = .zero
            $0.body.spin = 0
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
            liftedFromBox = boxIndex
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
            // Snatched away from this cat? It gives up (another cat after it gives up on its own).
            if mode == .fetching && boneIndex == g.index { mode = .chasing }
            if walkGoal == .bone && boneIndex == g.index { walkGoal = .cursor }
            guard g.index < toys.bones.count else { return }
            toys.bones[g.index].wanted = false
            withProp(.bone, g.index) {
                $0.state = .held
                $0.body.vel = .zero
                $0.body.spin = 0
            }
            let c = CGPoint(x: p.x + g.offset.dx, y: p.y + g.offset.dy)
            boneSwing = Swing(pivot: c, prevPivot: c, target: toys.bones[g.index].prop.body.angle, length: 0)
            boneSwingIndex = g.index
        case .box:
            withProp(.box, g.index) {   // a cat inside comes along for the ride
                $0.state = .held
                $0.body.vel = .zero
            }
        case .yarn:
            if case .chasingYarn = mode, yarnIndex == g.index { mode = .chasing }
            withProp(.yarn, g.index) {
                $0.state = .held
                $0.body.vel = .zero
            }
        case .bowl:
            withProp(.bowl, g.index) {
                $0.state = .held
                $0.body.vel = .zero
            }
        }
    }

    private mutating func click(_ thing: Thing, index i: Int = 0, count: Int = 1) {
        switch thing {
        case .cat where count >= 2:
            // Double-click: "stay!" — sleep right here. Double-click a sleeping cat to wake it
            // (one that stays, or one off napping somewhere).
            if case .staying = mode {
                mode = .chasing
                cat.wakeUp()
            } else if case .napping(let spot, _) = mode {
                mode = .napping(spot, ticksLeft: -1)   // wakes on the next tick (even in the big box)
            } else {
                if mode == .returningBone { dropBone(falling: true) }
                angry = false
                stayWindow = nil
                roamsParked = false                 // "stay!": it sits right here
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
            // One click = a little toss, and off a cat goes.
            let vx = CGFloat(random(800) - 400), spin = CGFloat(random(20) - 10)
            withProp(.bone, i) {
                $0.body.vel = CGVector(dx: vx, dy: 900)
                $0.body.spin = spin
                $0.state = .flying
            }
            if i < toys.bones.count { toys.bones[i].wanted = true }
        case .box:
            break
        case .bowl:
            // Click the bowl: fill it up, and dinner's served (every cat comes to eat).
            guard i < toys.bowls.count else { break }
            if toys.bowls[i].food < ToyPile.Bowl.full {
                toys.bowls[i].food = ToyPile.Bowl.full
                events.append(.heart)
            }
            events.append(.dinnerBell)
        case .yarn:
            // A little nudge: it rolls off, and the cats can't resist.
            let vx: CGFloat = random(2) == 0 ? -350 : 350, spin = CGFloat(random(20) - 10)
            withProp(.yarn, i) {
                $0.body.vel = CGVector(dx: vx, dy: 350)
                $0.body.spin = spin
                $0.state = .flying
            }
        }
    }

    private func position(of thing: Thing, index i: Int) -> CGPoint {
        thing == .cat ? cat.position : (prop(thing, i)?.body.pos ?? cat.position)
    }

    static func velocity(_ s: [(t: Double, p: CGPoint)]) -> CGVector {
        guard let last = s.last else { return .zero }
        let first = s.first { last.t - $0.t <= 0.08 } ?? last
        let dt = last.t - first.t
        guard dt > 0.005 else { return .zero }
        return CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
    }

    // MARK: - Helpers

    /// Falling (or dropped) into the opening of a resting (or held, or clipped) box? Which one.
    private var dropsIntoBox: Int? {
        guard catBody.vel.dy <= 0 else { return nil }
        let boxes = toys.boxes   // one read of the shared pile (this runs every frame, per flying cat)
        let p = cat.position
        for i in boxes.indices {
            let b = boxes[i]
            // Over its opening? (Checked first: it's cheap, and almost always no.)
            let dx = p.x - b.prop.body.pos.x
            let dy = p.y - b.prop.body.pos.y
            let held: CGFloat = (b.prop.state == .held ? 1.25 : 1) * (b.big ? 2 : 1)   // in hand: a bit easier
            guard abs(dx) < 13 * scale * held && dy > -6 * scale * held && dy < 22 * scale * held else { continue }
            guard b.prop.isResting || b.prop.state == .held || b.prop.state == .pinned, !b.closed,
                  ToyPile.isFree(b, for: catID) || b.prop.state == .held else { continue }
            if !b.big, b.napper != nil, b.napper != catID { continue }
            if i == liftedFromBox { continue }   // just taken out of this one
            return i
        }
        return nil
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
        if boneIndex < toys.bones.count {
            toys.bones[boneIndex].fetcher = nil
            toys.bones[boneIndex].fetcherDistance = .infinity
        }
        events.append(.boneDropped)
    }

    private func landedOnDock(_ world: World) -> Bool {
        let feet = cat.position.y - catShape.halfH + catShape.foot, x = cat.position.x
        return world.screens.contains { s in
            guard let d = s.dock, d.width >= d.height, d.minX <= x, x <= d.maxX
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
        roamsParked = true
        mode = .staying(frame: 0)
        return true
    }

    /// Where a parked cat can run up and down (x range): the window it's on (or in), the
    /// menu bar, or the top of the Dock. Nil: it just sits (e.g. on a drawing).
    private func parkedSurface(_ world: World) -> ClosedRange<CGFloat>? {
        let hw = catShape.halfW, x = cat.position.x
        let feet = cat.position.y - catShape.halfH + catShape.foot
        func span(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<CGFloat>? { hi - lo > 2 * hw ? (lo + hw)...(hi - hw) : nil }
        if let id = stayWindow {
            guard id >= 0, let f = world.window(id)?.frame else { return nil }
            return span(f.minX, f.maxX)
        }
        if let s = world.screen(containing: cat.position), cat.position.y > s.visible.maxY {
            return span(s.frame.minX, s.frame.maxX)                              // the menu bar
        }
        for s in world.screens {
            if let d = s.dock, d.width >= d.height, abs(feet - d.maxY) < 2, x >= d.minX, x <= d.maxX {
                return span(d.minX, d.maxX)                                      // the top of the Dock
            }
        }
        return nil
    }

    /// Parked and wide awake: it runs up and down where you put it, stopping now and then
    /// to look about or wash.
    private mutating func roamParked(_ r: ClosedRange<CGFloat>) {
        napFrame += 1
        if parkPause > 0 {
            parkPause -= 1
            cat.set(parkPause > 12 && napFrame % 40 < 12 ? .scratchSelf : .idle, napFrame)
            return
        }
        let s = min(max(sleepiness, 0.25), 2)
        let pace = 0.6 + 0.5 * (1 - min(s, 1))                 // Rarely: a real run
        cat.position.x += parkDir * cat.speed * pace
        if cat.position.x <= r.lowerBound || cat.position.x >= r.upperBound {
            cat.position.x = min(max(cat.position.x, r.lowerBound), r.upperBound)
            parkDir = -parkDir                                   // the end: turn around
            parkPause = 3 + random(8)
        } else if random(Int(25 + 30 / s)) == 0 {
            parkPause = Int(CGFloat(10 + random(30)) * max(0.5, s))
            if random(3) == 0 { parkDir = -parkDir }
        }
        catBody.pos = cat.position
        cat.set(parkDir > 0 ? .E : .W, napFrame)
    }

    private mutating func startFalling(velocity v: CGVector) {
        userLaunched = false
        dropInside = nil
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
        let odds = Int(CGFloat(sleepy ? 100 : 250) / max(sleepiness, 0.05))
        guard !gravityMode, cat.sleepEnabled, cat.idleTime > 30, cat.idleAnimation == nil, random(odds) == 0,
              let spot = chooseSpot(world) else { return }
        // Up to the menu bar or a title bar: a sleepy cat goes up there to nap, a wide-awake
        // one would rather run around up there.
        if explores, CGFloat(random(100)) >= min(1, 0.5 * sleepiness) * 100 {
            var outing: Outing?
            switch spot.kind {
            case .menuBar: outing = menuBarOuting(world)
            case .window: outing = windowOuting(world)
            default: break
            }
            if let o = outing {
                napFrame = 0
                mode = .exploring(o)
                return
            }
        }
        mode = .goingToSpot(spot)
    }

    mutating func chooseSpot(_ world: World) -> NapSpot? {
        var options: [NapSpot] = []
        // A box is irresistible: any free one (the nearest of a few picked at random).
        let free = toys.boxes.indices.filter { toys.isFree($0, for: catID) && toys.boxes[$0].prop.isResting }
        if !free.isEmpty {
            let picks = (0..<min(3, free.count)).map { _ in free[random(free.count)] }
            let i = picks.min {
                let a = toys.boxes[$0].prop.body.pos, b = toys.boxes[$1].prop.body.pos
                return hypot(a.x - cat.position.x, a.y - cat.position.y) < hypot(b.x - cat.position.x, b.y - cat.position.y)
            }!
            options += Array(repeating: NapSpot(kind: .box(i), point: toys.boxes[i].prop.body.pos), count: 3)
        }
        // The heap: one of the boxes near the top (the last ones drawn).
        if !toys.heap.isEmpty {
            let n = toys.heap.count
            let i = n - 1 - random(min(n, 64))
            if toys.heapNappers[i] == nil, let p = toys.heapPoint(i) {
                options += Array(repeating: NapSpot(kind: .heap(i), point: p), count: 2)
            }
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

    // MARK: - Exploring

    /// Left alone a while: now and then it sets off up a window or along the menu bar.
    private mutating func maybeExplore(_ world: World) {
        guard explores, !gravityMode, !laser, cat.idleTime > 40, cat.idleAnimation == nil, random(300) == 0 else { return }
        var options: [Outing] = []
        if let o = windowOuting(world) { options += [o, o] }
        if let o = insideOuting(world) { options += [o, o] }
        if let o = menuBarOuting(world) { options.append(o) }
        guard !options.isEmpty else { return }
        napFrame = 0
        mode = .exploring(options[random(options.count)])
    }

    /// One of the nearest big windows whose title bar it can get up onto.
    private func windowOuting(_ world: World) -> Outing? {
        let p = cat.position, hw = catShape.halfW
        var picks: [(Outing, CGFloat)] = []
        for (i, w) in world.windows.prefix(8).enumerated() {
            let f = w.frame
            guard f.width >= 200, f.height >= 120,
                  !world.isCovered(CGPoint(x: f.midX, y: f.maxY - 2), inFrontOf: i),
                  let s = world.screen(containing: CGPoint(x: f.midX, y: f.maxY - 2)),
                  f.maxY + 2 * cat.halfSize <= s.visible.maxY + 4
            else { continue }
            // Climb the side nearest the cat, if there's room beside it on the screen.
            let sides: [CGFloat] = abs(p.x - f.minX) <= abs(p.x - f.maxX) ? [-1, 1] : [1, -1]
            guard let side = sides.first(where: {
                let x = $0 < 0 ? f.minX - hw : f.maxX + hw
                return s.frame.insetBy(dx: hw, dy: 0).contains(CGPoint(x: x, y: f.maxY - 2))
            }) else { continue }
            let x = side < 0 ? f.minX - hw : f.maxX + hw
            let o = Outing(place: .window(w.id), side: side, ticksLeft: strollTicks(80 + random(160)), dir: -side, cursorAtStart: .zero)
            picks.append((o, hypot(x - p.x, f.maxY - p.y)))
        }
        guard !picks.isEmpty else { return nil }
        picks.sort { $0.1 < $1.1 }
        var o = picks[random(min(3, picks.count))].0
        o.cursorAtStart = lastCursor
        return o
    }

    private func menuBarOuting(_ world: World) -> Outing? {
        guard menuBarY(world) != nil else { return nil }
        return Outing(place: .menuBar, ticksLeft: strollTicks(100 + random(200)), dir: random(2) == 0 ? 1 : -1,
                      cursorAtStart: lastCursor)
    }

    /// How long it strolls about up there: longer the more awake it is.
    private func strollTicks(_ n: Int) -> Int { Int(CGFloat(n) * (1.5 - 0.25 * min(sleepiness, 2))) }

    /// At the end of a stroll up on the menu bar or a title bar, the chance it curls up for a
    /// nap there (else it carries on with its day): Rarely ~4 %, Now and Then ~11 %, Often
    /// 30 %, Very Sleepy ~85 %.
    var outingNapChance: CGFloat { min(0.9, 0.3 * pow(max(sleepiness, 0), 1.5)) }

    /// Where its centre sits walking along the menu bar of the display it's on (nil: hidden
    /// menu bar, or too big a cat).
    private func menuBarY(_ world: World) -> (y: CGFloat, screen: CGRect)? {
        guard catScale <= 1, let s = world.screen(containing: cat.position) ?? world.screens.first,
              s.frame.maxY - s.visible.maxY >= 18 else { return nil }
        return (min(s.visible.maxY + catShape.halfH - catShape.foot, s.frame.maxY - catShape.halfH + 3 * scale), s.frame)
    }

    /// One tick of an outing. False when it's over (`mode` says what's next).
    private mutating func explore(_ o: inout Outing, _ world: World) -> Bool {
        let hw = catShape.halfW, lift = catShape.halfH - catShape.foot
        napFrame += 1
        // The surface it strolls along: a title bar or the menu bar.
        var minX: CGFloat, maxX: CGFloat, y: CGFloat
        switch o.place {
        case .window(let id):
            guard let f = world.window(id)?.frame else {
                // The window closed (or went away) under it.
                if o.stage == .approach { mode = .chasing } else { startFalling(velocity: .zero) }
                return false
            }
            minX = f.minX + hw; maxX = f.maxX - hw; y = f.maxY + lift
            let edgeX = o.side < 0 ? f.minX - hw : f.maxX + hw
            switch o.stage {
            case .approach:
                // Over to the window's side, at the height it's at (never below the window).
                let baseY = min(max(cat.position.y, f.minY + catShape.halfH), f.maxY - catShape.halfH)
                if cat.walk(to: CGPoint(x: edgeX, y: baseY)) {
                    if scratchesWindows {
                        o.stage = .scratch
                        o.scratch = 15 + random(20)
                    } else {
                        o.stage = .climb
                    }
                }
                return true
            case .scratch:
                // A good scratch at the window's edge first.
                cat.position.x = edgeX
                cat.set(o.side < 0 ? .scratchWallE : .scratchWallW, napFrame)
                o.scratch -= 1
                if o.scratch <= 0 { o.stage = .climb; events.append(.scratched) }
                return true
            case .climb:
                // Paws on the window's edge, up it goes.
                cat.position.x = edgeX
                cat.position.y += cat.speed * 0.45
                cat.set(o.side < 0 ? .scratchWallE : .scratchWallW, napFrame / 2)
                if cat.position.y >= f.maxY - catShape.halfH * 0.4 {
                    // Over the top and onto the title bar.
                    cat.position = CGPoint(x: o.side < 0 ? minX + 2 * scale : maxX - 2 * scale, y: y)
                    o.stage = .stroll
                    o.pause = 8
                }
                return true
            case .stroll: break
            }
        case .inside(let id):
            guard let f = world.window(id)?.frame, let loop = insideLoop(f) else {
                if o.stage == .approach { mode = .chasing } else { startFalling(velocity: .zero) }
                return false
            }
            return walkInside(&o, id: id, loop)
        case .menuBar:
            guard let (my, sf) = menuBarY(world) else { mode = .chasing; return false }
            minX = sf.minX + hw; maxX = sf.maxX - hw; y = my
            if o.stage != .stroll {
                let target = CGPoint(x: min(max(cat.position.x, minX), maxX), y: y)
                if cat.walk(to: target) { o.stage = .stroll; o.pause = 6 }
                return true
            }
        }

        // Strolling along the top.
        guard maxX > minX else { mode = .chasing; return false }
        cat.position.y = y
        if o.ticksLeft <= 0 {
            // Done: a nap up here now and then, or back to you.
            if cat.sleepEnabled && CGFloat(random(100)) < outingNapChance * 100 {
                let kind: NapSpot.Kind
                if case .window(let id) = o.place { kind = .window(id) } else { kind = .menuBar }
                napFrame = 0
                mode = .napping(NapSpot(kind: kind, point: cat.position), ticksLeft: Int(CGFloat(300 + random(600)) * napLength))
            } else {
                mode = .chasing
                cat.wakeUp()
            }
            return false
        }
        o.ticksLeft -= 1
        // A sleepy cat ambles and sits about a lot; a wide-awake one runs up and down.
        let s = min(max(sleepiness, 0.25), 2)
        if o.pause > 0 {
            o.pause -= 1
            if o.pause > 12 && napFrame % 40 < 12 { cat.set(.scratchSelf, napFrame) }
            else if s >= 1.5 && o.pause > 8 { cat.set(.tired, 0) }   // a big yawn
            else { cat.set(.idle, 0) }
            return true
        }
        let pace = 0.5 + 0.6 * (1 - min(s, 1))                     // Often: 0.5× … Rarely: 0.95×
        cat.position.x += o.dir * cat.speed * pace
        if cat.position.x <= minX || cat.position.x >= maxX {
            cat.position.x = min(max(cat.position.x, minX), maxX)
            o.dir = -o.dir                                   // the end: turn around
            o.pause = 4 + random(8)
        } else if random(Int(20 + 30 / s)) == 0 {
            o.pause = Int(CGFloat(10 + random(30)) * max(0.5, s))   // stop and look about
            if random(3) == 0 { o.dir = -o.dir }
        }
        cat.set(o.dir > 0 ? .E : .W, pace > 0.7 ? napFrame : napFrame / 2)   // (a quicker step when running)
        return true
    }

    // MARK: - Inside a window's border

    /// Roughly how tall a title bar is: walking round the inside, it keeps its head under it.
    static let titleBar: CGFloat = 28

    /// The loop it walks round the inside of window `f`: x from `x0` to `x1`, its centre at
    /// `yb` along the bottom (feet on the bottom edge) and `yt` along the top (head just under
    /// the title bar). Nil if the window's too small.
    struct Loop: Equatable { var x0, x1, yb, yt: CGFloat }
    func insideLoop(_ f: CGRect) -> Loop? {
        let hw = catShape.halfW
        let l = Loop(x0: f.minX + hw, x1: f.maxX - hw, yb: f.minY + catShape.halfH - catShape.foot,
                     yt: f.maxY - Self.titleBar * scale - catShape.halfH)
        guard l.x1 - l.x0 > 6 * hw, l.yt - l.yb > 3 * catShape.halfH else { return nil }
        return l
    }

    /// 0 the bottom, 1 the right side (going up), 2 the top (going left), 3 the left side
    /// (going down).
    static func loopSegment(_ along: CGFloat, _ l: Loop) -> Int {
        let w = l.x1 - l.x0, h = l.yt - l.yb, a = loopWrap(along, l)
        return a < w ? 0 : a < w + h ? 1 : a < 2 * w + h ? 2 : 3
    }

    private static func loopWrap(_ along: CGFloat, _ l: Loop) -> CGFloat {
        let p = 2 * ((l.x1 - l.x0) + (l.yt - l.yb))
        let a = along.truncatingRemainder(dividingBy: p)
        return a < 0 ? a + p : a
    }

    static func loopPoint(_ along: CGFloat, _ l: Loop) -> CGPoint {
        let w = l.x1 - l.x0, h = l.yt - l.yb, a = loopWrap(along, l)
        if a < w { return CGPoint(x: l.x0 + a, y: l.yb) }
        if a < w + h { return CGPoint(x: l.x1, y: l.yb + (a - w)) }
        if a < 2 * w + h { return CGPoint(x: l.x1 - (a - w - h), y: l.yt) }
        return CGPoint(x: l.x0, y: l.yt - (a - 2 * w - h))
    }

    /// One of the nearest big windows it can walk round the inside of (all of it in view).
    private func insideOuting(_ world: World) -> Outing? {
        let p = cat.position
        var picks: [(Outing, CGFloat)] = []
        for (i, w) in world.windows.prefix(8).enumerated() {
            guard w.frame.width >= 320, w.frame.height >= 220, let l = insideLoop(w.frame) else { continue }
            let corners = [CGPoint(x: l.x0, y: l.yb), CGPoint(x: l.x1, y: l.yb), CGPoint(x: l.x1, y: l.yt), CGPoint(x: l.x0, y: l.yt)]
            guard corners.allSatisfy({ !world.isCovered($0, inFrontOf: i) && world.screen(containing: $0) != nil })
            else { continue }
            let along = min(max(p.x - l.x0, 0), l.x1 - l.x0)        // in at the bottom, below where it is
            let o = Outing(place: .inside(w.id), ticksLeft: strollTicks(150 + random(250)),
                           dir: random(2) == 0 ? 1 : -1, cursorAtStart: lastCursor, along: along)
            picks.append((o, hypot(l.x0 + along - p.x, l.yb - p.y)))
        }
        guard !picks.isEmpty else { return nil }
        picks.sort { $0.1 < $1.1 }
        return picks[random(min(3, picks.count))].0
    }

    /// Round the inside of the window's border: along the bottom, up the side, along under
    /// the title bar, down the other side. It sits about (and scratches the corners) on the
    /// bottom edge, and may nap there.
    private mutating func walkInside(_ o: inout Outing, id: Int, _ l: Loop) -> Bool {
        let w = l.x1 - l.x0
        if o.stage != .stroll {
            if cat.walk(to: Self.loopPoint(o.along, l)) { o.stage = .stroll; o.pause = 6 }
            return true
        }
        let seg = Self.loopSegment(o.along, l)
        if o.ticksLeft <= 0, seg == 0 {
            // Done, back on the bottom edge: a nap in the corner of the window now and then.
            if cat.sleepEnabled && CGFloat(random(100)) < outingNapChance * 100 {
                napFrame = 0
                mode = .napping(NapSpot(kind: .window(id), point: cat.position),
                                ticksLeft: Int(CGFloat(300 + random(600)) * napLength))
            } else {
                mode = .chasing
                cat.wakeUp()
            }
            return false
        }
        o.ticksLeft -= 1
        cat.position = Self.loopPoint(o.along, l)
        if o.scratch > 0 {
            o.scratch -= 1
            let a = Self.loopWrap(o.along, l)
            cat.set(a < w / 2 ? .scratchWallW : .scratchWallE, napFrame)
            if o.scratch == 0 { events.append(.scratched) }
            return true
        }
        if o.pause > 0, seg == 0 {
            o.pause -= 1
            if o.pause > 12 && napFrame % 40 < 12 { cat.set(.scratchSelf, napFrame) } else { cat.set(.idle, 0) }
            return true
        }
        let s = min(max(sleepiness, 0.25), 2)
        let pace = 0.5 + 0.6 * (1 - min(s, 1))
        let wasOnBottom = seg == 0
        if !wasOnBottom { o.cornerDone = false }
        o.along += o.dir * cat.speed * pace
        if wasOnBottom, Self.loopSegment(o.along, l) != 0, !o.cornerDone {
            o.cornerDone = true
            if scratchesWindows, random(3) == 0 {
                // Reached a bottom corner: stop right in it and give the window's edge a scratch.
                o.along = o.dir > 0 ? w - 0.01 : 0
                o.scratch = 15 + random(20)
            }
        }
        cat.position = Self.loopPoint(o.along, l)
        switch Self.loopSegment(o.along, l) {
        case 0:
            cat.set(o.dir > 0 ? .E : .W, napFrame / 2)
            if o.scratch == 0, random(Int(20 + 30 / s)) == 0 { o.pause = Int(CGFloat(10 + random(30)) * max(0.5, s)) }
        case 1: cat.set(.scratchWallE, napFrame / 2)        // paws on the right edge
        case 2: cat.set(o.dir > 0 ? .W : .E, napFrame / 2)  // along under the title bar
        default: cat.set(.scratchWallW, napFrame / 2)       // paws on the left edge
        }
        return true
    }

    // MARK: - Food

    /// (A plain loop over a local copy of the bowls: closures mentioning `cat` would copy the
    /// whole playground, and every hungry cat asks every tick.)
    @inline(__always) private func nearestBowlWithFood() -> Int? {
        let bowls = toys.bowls, c = cat.position
        var best: (Int, CGFloat)?
        for i in bowls.indices where bowls[i].food > 0 && bowls[i].prop.isResting {
            let a = bowls[i].prop.body.pos
            let d = hypot(a.x - c.x, a.y - c.y)
            if d < (best?.1 ?? .infinity) { best = (i, d) }   // the first of the nearest, like min(by:)
        }
        return best?.0
    }

    /// Where it sits to eat: beside the bowl (cats take turns on each side), feet level with it.
    private func bowlSpot(_ b: ToyPile.Bowl) -> CGPoint {
        let side: CGFloat = catID % 2 == 0 ? -1 : 1
        return CGPoint(x: b.prop.body.pos.x + side * (b.prop.shape.halfW + 4 * scale),
                       y: b.prop.body.pos.y - b.prop.shape.halfH + catShape.halfH - catShape.foot)
    }

    /// Put bowl `index` at `p`.
    mutating func placeBowl(at p: CGPoint, falling: Bool, index: Int = 0) {
        toys.placeBowl(index, at: p, falling: falling)
    }

    /// Eating from bowl `i`, or on its way to it.
    func usesBowl(_ i: Int) -> Bool {
        switch mode {
        case .goingToBowl(let j), .eating(let j, _): return i == j
        default: return false
        }
    }

    /// Bowl `i` was cleared away (the ones after it move down one).
    mutating func bowlRemoved(_ i: Int) {
        switch mode {
        case .goingToBowl(let j): mode = j == i ? .chasing : .goingToBowl(j > i ? j - 1 : j)
        case .eating(let j, let left): mode = j == i ? .chasing : .eating(j > i ? j - 1 : j, ticksLeft: left)
        default: break
        }
    }

    mutating func removeBowls(keeping n: Int) {
        switch mode {
        case .goingToBowl(let i) where i >= n, .eating(let i, _) where i >= n: mode = .chasing
        default: break
        }
        if toys.bowls.count > n { toys.bowls.removeLast(toys.bowls.count - n) }
    }

    // MARK: - Yarn, catnip, waking up

    /// Put ball of yarn `index` (the first by default) at `p`.
    mutating func placeYarn(at p: CGPoint, falling: Bool, index: Int = 0) {
        toys.placeYarn(index, at: p, falling: falling)
    }

    /// Put every ball of yarn away.
    mutating func removeYarn() { removeYarns(keeping: 0) }

    mutating func removeYarns(keeping n: Int) {
        if case .chasingYarn = mode, yarnIndex >= n { mode = .chasing }
        if toys.yarns.count > n { toys.yarns.removeLast(toys.yarns.count - n) }
        if yarnIndex >= max(n, 1) { yarnIndex = 0 }
    }

    /// The first ball of yarn rolling by fast enough to chase.
    @inline(__always) private func rollingYarn() -> Int? {
        let yarns = toys.yarns   // one read of the shared pile, not one per ball
        let p = cat.position, r = 900 * scale
        for i in yarns.indices {
            let y = yarns[i].prop
            if y.state == .flying && hypot(y.body.vel.dx, y.body.vel.dy) > 250
                && hypot(y.body.pos.x - p.x, y.body.pos.y - p.y) < r { return i }
        }
        return nil
    }

    /// Bat the yarn away (and it rolls off).
    private mutating func batYarn() {
        var y = yarn   // one read and one write of the shared pile
        guard y.isOut, y.state != .held, y.state != .pinned, batCooldown == 0 else { return }
        let dir: CGFloat = y.body.pos.x >= cat.position.x ? 1 : -1
        y.state = .flying
        y.body.vel = CGVector(dx: dir * CGFloat(500 + random(500)), dy: CGFloat(250 + random(400)))
        y.body.spin = -dir * 12
        yarn = y
        batCooldown = 12
        cat.set(.scratchSelf, 0)
        events.append(.batYarn)
    }

    /// Walking or sitting right next to the yarn: give it a pat.
    private mutating func batNearbyYarn() {
        guard !paused, batCooldown == 0, !toys.yarns.isEmpty else { return }
        switch mode {
        case .chasing, .walking, .petted: break
        default: return
        }
        let reach = catShape.halfW + 6 * scale
        let yarns = toys.yarns, p = cat.position
        guard let i = yarns.indices.first(where: {
            let y = yarns[$0].prop
            return y.isResting && abs(y.body.pos.x - p.x) < reach
                && hypot(y.body.pos.x - p.x, y.body.pos.y - p.y) < reach
        }) else { return }
        yarnIndex = i
        batYarn()
    }

    /// How much faster catnip zoomies run than a normal chase (0.6.5: twice the old 3×).
    static let catnipSpeed: CGFloat = 6

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

    private func clampToScreens(_ p: CGPoint) -> CGPoint {
        let c = cat.position   // (a closure mentioning `cat` would copy the whole playground)
        guard let s = lastScreens.first(where: { $0.frame.contains(c) }) ?? lastScreens.first else { return p }
        let r = s.visible.insetBy(dx: catShape.halfW, dy: catShape.halfH)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func randomSpot() -> CGPoint {
        let c = cat.position   // (a closure mentioning `cat` would copy the whole playground)
        guard let s = lastScreens.first(where: { $0.frame.contains(c) }) ?? lastScreens.first else {
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
        if ownsToys {
            for i in toys.bones.indices where toys.bones[i].prop.isResting || toys.bones[i].prop.state == .pinned {
                toys.bones[i].prop.body.pos.x = clamp(toys.bones[i].prop.body.pos.x, toys.bones[i].prop.shape.halfW)
            }
            for i in toys.yarns.indices where toys.yarns[i].prop.isResting || toys.yarns[i].prop.state == .pinned {
                toys.yarns[i].prop.body.pos.x = clamp(toys.yarns[i].prop.body.pos.x, toys.yarns[i].prop.shape.halfW)
            }
            for i in toys.bowls.indices where toys.bowls[i].prop.isResting || toys.bowls[i].prop.state == .pinned {
                toys.bowls[i].prop.body.pos.x = clamp(toys.bowls[i].prop.body.pos.x, toys.bowls[i].prop.shape.halfW)
            }
            for i in toys.boxes.indices where toys.boxes[i].prop.isResting || toys.boxes[i].prop.state == .pinned {
                toys.boxes[i].prop.body.pos.x = clamp(toys.boxes[i].prop.body.pos.x, toys.boxes[i].prop.shape.halfW)
            }
        }
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

    @inline(__always) private func walkTarget(_ world: World) -> CGPoint {
        if paused { return cat.position }
        switch walkGoal {
        case .bone where bone.state == .flying || bone.isResting: return bone.body.pos
        case .nap: return walkBox.flatMap { toys.boxes[safe: $0]?.prop.body.pos } ?? world.cursor
        default: return world.cursor
        }
    }

    private mutating func walk(dt: CGFloat, world: World) {
        walkFrame += 1
        if walkGoal == .bone && (!(bone.state == .flying || bone.isResting) || toys.bones[safe: boneIndex]?.fetcher != catID) {
            walkGoal = .cursor     // gone, or a closer cat took over
        }
        if walkGoal == .nap && !(walkBox.map { toys.isFree($0, for: catID) && toys.boxes[$0].prop.isResting } ?? false) {
            walkGoal = .cursor
            walkBox = nil
        }
        let target = walkTarget(world)
        let dx = target.x - cat.position.x
        let moving = abs(dx) > 6 && !walkArrived
        let speed = cat.speed * 10 * (walkGoal == .bone ? 1.3 : 1)   // same pace as classic oneko
            * (zoomBoost > 0 ? Self.catnipSpeed : 1) * (laser ? 2.2 : 1)
        catBody.pos = cat.position
        catBody.vel.dx = moving ? (dx > 0 ? speed : -speed) : 0
        if moving { hopOntoBox(toward: dx, target: target) }
        let feet = cat.position.y - catShape.halfH + catShape.foot
        let result = Physics.step(&catBody, shape: catShape, dt: dt, world: boxTops(world, above: feet))
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
        if walkGoal == .nap, walkGrounded, let i = walkBox, abs(toys.boxes[i].prop.body.pos.x - cat.position.x) < 8 {
            walkGoal = .cursor
            walkBox = nil
            events.append(.boxHop)
            enterBox(i)
            return
        }

        // Fetch on foot.
        if walkGoal == .bone, abs(bone.body.pos.x - cat.position.x) < 14 * scale,
           abs(bone.body.pos.y - cat.position.y) < 30 * scale {
            bone.state = .carried
            toys.bones[boneIndex].wanted = false
            walkGoal = .bringBack
            events.append(.boneTaken)
        }
        if walkGoal == .bringBack {
            bone.body.pos = cat.position
            if !moving && walkGrounded {
                dropBone(falling: true, toward: world.pointer ?? world.cursor)
                events.append(.fetched)
                walkGoal = .cursor
            }
        }
    }

    // MARK: - Bumping into other cats

    /// How a cat takes part in bumping into other cats.
    enum BodyKind: Equatable {
        case none        // napping, in a box, eating, held, clipped…: others pass by
        case free        // up and about: pushed apart from others any way
        case surface     // on a window, the Dock, the menu bar, the ground: pushed only sideways
        case flying      // thrown or knocked: knocks into others
    }

    var bodyKind: BodyKind {
        if inBox { return .none }
        switch mode {
        case .chasing, .petted, .stretching, .goingToSpot, .fetching, .returningBone, .chasingYarn,
             .zoomies, .goingToBowl:
            return .free
        case .dazed(_, let w): return w == nil ? .free : .surface
        case .staying, .walking: return .surface
        case .exploring(let o):
            switch o.stage {
            case .approach: return .free
            case .stroll: return .surface
            case .scratch, .climb: return .none
            }
        case .flying: return .flying
        default: return .none
        }
    }

    /// How close two cats get before they bump (centre to centre, for this cat's share).
    var bumpRadius: CGFloat { catShape.halfW * 0.85 }

    /// Pushed by another cat it's bumped into (sideways only on a surface).
    mutating func shove(_ d: CGVector) {
        switch bodyKind {
        case .free: cat.position.x += d.dx; cat.position.y += d.dy
        case .surface: cat.position.x += d.dx
        case .none, .flying: return
        }
        // Never shoved off the display. (A plain loop: this runs for every bumped cat.)
        var f = lastScreens.first?.frame
        for s in lastScreens where s.frame.contains(cat.position) { f = s.frame; break }
        if let f {
            let hw = catShape.halfW, hh = catShape.halfH, p = cat.position
            cat.position = CGPoint(x: min(max(p.x, f.minX + hw), f.maxX - hw), y: min(max(p.y, f.minY + hh), f.maxY - hh))
        }
        catBody.pos = cat.position
        if mode == .walking { walkArrived = false }
    }

    /// Hit by a flying cat: knocked flying itself. False if it can't be (held, in a box…).
    @discardableResult
    mutating func knockedByCat(_ v: CGVector, spin: CGFloat = 1) -> Bool {
        guard catCanBeHit, !inBox else { return false }
        if mode == .returningBone || walkGoal == .bringBack { dropBone(falling: true) }
        walkGoal = .cursor
        stayWindow = nil
        let k = Physics.clampSpeed(v)
        startFalling(velocity: k)
        catBody.spin = (-k.dx / 150 + CGFloat(random(200) - 100) / 40) * spin
        if hypot(k.dx, k.dy) > 1500 { angry = true }
        events.append(.catBump)
        return true
    }

    /// A flying cat's new velocity after bumping into another (only while it's flying).
    mutating func setFlightVelocity(_ v: CGVector) {
        guard mode == .flying else { return }
        catBody.vel = Physics.clampSpeed(v)
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
    /// The Docks have been read at least once (so the very first tick isn't "it just appeared").
    private var docksSeen = false

    /// Look at the Dock afresh, as on launch: a Dock now under something lifts it on top
    /// instead of bonking it (the Dock setting went back to "on top").
    mutating func forgetDocks() {
        lastDocks = []
        docksSeen = false
    }

    /// A cat that follows your cursor into a showing Dock gets yeeted up and out of it.
    /// Merely dipping its feet in (chasing a cursor just above the Dock), a Dock appearing
    /// underneath it, or being just after a yeet only nudges it back on top, so it never
    /// glitches on the ground.
    /// Is `screens.compactMap(\.dock)` equal to `docks`? (Without building it.)
    private static func sameDocks(_ screens: [ScreenInfo], _ docks: [CGRect]) -> Bool {
        var k = 0
        for s in screens {
            guard let d = s.dock else { continue }
            guard k < docks.count, docks[k] == d else { return false }
            k += 1
        }
        return k == docks.count
    }

    private mutating func dockBounce(_ world: World) {
        // The same Docks as last tick (nearly always): keep that array instead of a new one.
        let docks = Self.sameDocks(world.screens, lastDocks) ? lastDocks : world.screens.compactMap(\.dock)
        let seen = docksSeen
        defer { lastDocks = docks; docksSeen = true }
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
            func drop(_ p: inout Prop) {
                let bottom = p.body.pos.y - p.shape.halfH + p.shape.foot
                if p.isResting, p.restingWindow == nil, abs(bottom - d.maxY) < 1.5,
                   p.body.pos.x >= d.minX, p.body.pos.x <= d.maxX, gone(p.body.pos.x) {
                    p.state = .flying
                    p.body.vel = .zero
                }
            }
            if ownsToys {
                for i in toys.boxes.indices { drop(&toys.boxes[i].prop) }
                for i in toys.bones.indices { drop(&toys.bones[i].prop) }
                for i in toys.bowls.indices { drop(&toys.bowls[i].prop) }
            }
        }
        for s in world.screens {
            guard let d = s.dock else { continue }
            let left = d.minX <= s.frame.minX + 1 && d.height > d.width
            let right = d.maxX >= s.frame.maxX - 1 && d.height > d.width
            let wasThere = lastDocks.contains { $0.intersects(d) }
            // An auto-hiding Dock just popped up under it: bonk! (Unless that's turned off, or
            // this is the first look at the Dock since launch.)
            let popBonk = !wasThere && dockBonk && seen

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
            // (Following your cursor into the Dock used to yeet it up and out. Now it stands on
            // top of the Dock and waits there; set the Dock to "ground" to walk in front of it.)
            if grounded, popBonk, dockCooldown == 0, feetIn(cat.position, catShape) {
                let v = out()
                startFalling(velocity: v)
                catBody.spin = -v.dx / 150 + CGFloat(random(200) - 100) / 30
                dockCooldown = 20
                events.append(.dockBonk)
            } else if grounded, feetIn(cat.position, catShape) {
                cat.position = onTop(cat.position, catShape)   // just a dip: back on top
                catBody.pos = cat.position
            }
            let launchProps = popBonk
            func shove(_ p: inout Prop, spin: Int) {
                guard p.isResting, feetIn(p.body.pos, p.shape, margin: 2 * scale) else { return }
                if launchProps {
                    p.body.vel = out()
                    if spin > 0 { p.body.spin = CGFloat(random(2 * spin) - spin) }
                    p.state = .flying
                } else {
                    p.body.pos = onTop(p.body.pos, p.shape)
                }
            }
            if ownsToys {
                for i in toys.yarns.indices { shove(&toys.yarns[i].prop, spin: 0) }
                for i in toys.bones.indices { shove(&toys.bones[i].prop, spin: 15) }
                for i in toys.bowls.indices { shove(&toys.bowls[i].prop, spin: 0) }
                for i in toys.boxes.indices where toys.boxes[i].prop.isResting {
                    let b = toys.boxes[i].prop
                    guard feetIn(b.body.pos, b.shape, margin: 2 * scale) else { continue }
                    if launchProps {
                        toys.boxes[i].prop.body.vel = out()
                        toys.boxes[i].prop.body.spin = CGFloat(random(6) - 3)
                        toys.boxes[i].prop.state = .flying
                    } else {
                        toys.boxes[i].prop.body.pos = onTop(b.body.pos, b.shape)
                    }
                }
            }
        }
    }

    // MARK: - Windows: riding along, and getting hit

    /// Delta of a window's top-left since last tick; nil if it vanished.
    private func windowDelta(_ id: Int, _ world: World) -> CGVector? {
        if id < 0 { return world.drawing(id) != nil ? .zero : nil }   // drawings don't move
        guard let now = world.window(id)?.frame else { return nil }
        guard let old = lastWindows[id] else { return .zero }
        // Parked inside a window, on its bottom edge: it rides that edge (a resize moves it).
        var inside = false
        switch mode {
        case .staying, .dazed: inside = stayInside
        default: break
        }
        return CGVector(dx: now.minX - old.minX, dy: inside ? now.minY - old.minY : now.maxY - old.maxY)
    }

    /// A window flicked upward (or yanked hard) while something sits on it launches it.
    private func launch(_ d: CGVector, dt: CGFloat, mouseDown: Bool) -> CGVector? {
        let v = CGVector(dx: d.dx / dt, dy: d.dy / dt)
        guard mouseDown, v.dy > 500 || hypot(v.dx, v.dy) > 1800 else { return nil }
        return Physics.clampSpeed(CGVector(dx: v.dx * 1.6, dy: v.dy * 1.8 + 300))
    }

    // MARK: - Stacking boxes

    /// Drawing ids for box rims (box `i` is `boxTopID - i`).
    static let boxTopID = -1_000_000

    /// `world` plus the rims of the resting boxes as platforms: things land on boxes and
    /// boxes stack. `above`: only rims below those feet (one-way, for climbing cats).
    func boxTops(_ world: World, except j: Int? = nil, above feet: CGFloat? = nil) -> World {
        guard !toys.boxes.isEmpty else { return world }
        var w = world
        let rims = toys.restingRims(scale: scale)   // (built once, shared)
        var grown = false
        for r in rims where r.index != j {
            if let f = feet, f < r.top - 3 * scale { continue }
            if !grown { w.drawings.reserveCapacity(world.drawings.count + rims.count); grown = true }   // one allocation
            w.drawings.append(r.drawing)
        }
        return w
    }

    /// The height of a box's rim (where the next box sits).
    private func rimY(_ b: ToyPile.Box) -> CGFloat { ToyPile.rimY(b, scale: scale) }

    /// A box taken out from under a stack: whatever sat on it falls.
    private mutating func dropUnsupported() {
        let resting = toys.boxes.map(\.prop.isResting)
        func check(_ p: inout Prop) {
            guard let id = p.restingWindow, id <= Self.boxTopID else { return }
            if !(resting[safe: Self.boxTopID - id] ?? false) { p.state = .flying; p.body.vel = .zero }
        }
        for i in toys.boxes.indices { check(&toys.boxes[i].prop) }
        for i in toys.bones.indices { check(&toys.bones[i].prop) }
        for i in toys.yarns.indices { check(&toys.yarns[i].prop) }
        for i in toys.bowls.indices { check(&toys.bowls[i].prop) }
    }

    /// Walking (gravity mode) toward something past or above a box: hop up onto its rim.
    private mutating func hopOntoBox(toward dx: CGFloat, target: CGPoint) {
        guard walkGrounded, abs(dx) > 6 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        let feet = cat.position.y - catShape.halfH + catShape.foot
        let ahead = cat.position.x + dir * (catShape.halfW + 6 * scale)
        for b in toys.boxes where b.prop.isResting {
            let top = rimY(b)
            let rise = top - feet
            guard rise > 4 * scale, rise < 90 * scale, abs(ahead - b.prop.body.pos.x) < b.prop.shape.halfW,
                  target.y > top || abs(target.x - b.prop.body.pos.x) > b.prop.shape.halfW   // it's on the way
            else { continue }
            catBody.vel.dy = (2 * Physics.gravity * (rise + 14 * scale)).squareRoot()
            walkGrounded = false
            return
        }
    }

    private mutating func rideWindows(_ world: World, dt: CGFloat) {
        // Nothing sitting on a window or a drawing: nothing to do (and no box rims to build).
        guard ridesSomething else { return }
        let world = boxTops(world)   // things sitting on boxes ride them
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
        if ownsToys {
            for i in toys.bones.indices where toys.bones[i].prop.restingWindow != nil {
                Self.rideProp(&toys.bones[i].prop, world: world, last: lastWindows, dt: dt, launch: launch)
            }
            for i in toys.yarns.indices where toys.yarns[i].prop.restingWindow != nil {
                Self.rideProp(&toys.yarns[i].prop, world: world, last: lastWindows, dt: dt, launch: launch)
            }
            for i in toys.bowls.indices where toys.bowls[i].prop.restingWindow != nil {
                Self.rideProp(&toys.bowls[i].prop, world: world, last: lastWindows, dt: dt, launch: launch)
            }
            for i in toys.boxes.indices where toys.boxes[i].prop.restingWindow != nil {
                Self.rideProp(&toys.boxes[i].prop, world: world, last: lastWindows, dt: dt, launch: launch)
            }
        }
    }

    /// Is anything this playground moves sitting on a window or a drawing (see `rideWindows`)?
    private var ridesSomething: Bool {
        switch mode {
        case .napping(let s, _): if case .window = s.kind { return true }
        case .goingToSpot(let s): if case .window = s.kind { return true }
        case .staying: if stayWindow != nil { return true }
        case .dazed(_, let w): if w != nil { return true }
        default: break
        }
        guard ownsToys else { return false }
        return toys.bones.contains { $0.prop.restingWindow != nil } || toys.yarns.contains { $0.prop.restingWindow != nil }
            || toys.bowls.contains { $0.prop.restingWindow != nil } || toys.boxes.contains { $0.prop.restingWindow != nil }
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
        case .exploring(let o): return o.windowID
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
            if ownsToys {
                for i in toys.yarns.indices {
                    let y = toys.yarns[i].prop
                    guard y.isResting || y.state == .flying, y.restingWindow != w.id, hits(y.body.pos) else { continue }
                    toys.yarns[i].prop.body.vel = Self.knock(Self.push(old, new, at: y.body.pos, dt: dt))
                    toys.yarns[i].prop.body.spin = -toys.yarns[i].prop.body.vel.dx / 30
                    toys.yarns[i].prop.state = .flying
                }
                for i in toys.bowls.indices {
                    let b = toys.bowls[i].prop
                    guard b.isResting, b.restingWindow != w.id, hits(b.body.pos) else { continue }
                    toys.bowls[i].prop.body.vel = Self.knock(Self.push(old, new, at: b.body.pos, dt: dt))
                    toys.bowls[i].prop.state = .flying
                }
                for i in toys.bones.indices {
                    let b = toys.bones[i].prop
                    guard b.isResting || b.state == .flying, b.restingWindow != w.id, hits(b.body.pos) else { continue }
                    let v = Self.knock(Self.push(old, new, at: b.body.pos, dt: dt))
                    toys.bones[i].prop.body.vel = Physics.clampSpeed(CGVector(dx: v.dx + b.body.vel.dx * 0.3, dy: v.dy))
                    toys.bones[i].prop.body.spin = -toys.bones[i].prop.body.vel.dx / 50
                    toys.bones[i].prop.state = .flying
                }
                for i in toys.boxes.indices {
                    let b = toys.boxes[i]
                    // A box with a cat napping in it (flaps open) stays put; a shut one gets knocked.
                    guard b.prop.isResting, b.prop.restingWindow != w.id, !b.occupied || b.closed,
                          hits(b.prop.body.pos) else { continue }
                    toys.boxes[i].prop.body.vel = Self.knock(Self.push(old, new, at: b.prop.body.pos, dt: dt))
                    toys.boxes[i].prop.body.spin = -toys.boxes[i].prop.body.vel.dx / 400
                    toys.boxes[i].prop.state = .flying
                }
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

// MARK: - Reading in place

extension Playground {
    // A playground is a big struct (about 900 bytes). Calling a getter on one that sits in an
    // array or a class copies all of it first, even when it reads one field. These take it
    // `inout` (by address) with the getter inlined, so the loops over every cat read each
    // one where it is.
    static func pose(_ p: inout Playground) -> CatPose { p.catPose }
    static func needsPhysics(_ p: inout Playground) -> Bool { p.needsPhysics }
    static func needsWindowTracking(_ p: inout Playground) -> Bool { p.needsWindowTracking }
    static func canPlay(_ p: inout Playground) -> Bool { p.canPlay }
    static func isPlaying(_ p: inout Playground) -> Bool { p.isPlaying }
    static func catScale(_ p: inout Playground) -> CGFloat { p.catScale }
    static func inBigBox(_ p: inout Playground) -> Bool { p.inBigBox }
    static func usesBowl(_ p: inout Playground, _ i: Int) -> Bool { p.usesBowl(i) }
    static func body(_ p: inout Playground) -> (pos: CGPoint, kind: Playground.BodyKind) { (p.cat.position, p.bodyKind) }
    static func velocity(_ p: inout Playground) -> CGVector { p.catBody.vel }
    static func bumpRadius(_ p: inout Playground) -> CGFloat { p.bumpRadius }
}
