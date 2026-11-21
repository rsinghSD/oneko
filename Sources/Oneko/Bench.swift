import Foundation
import QuartzCore

/// `Oneko --bench`: headless timing of the simulation (no windows, so it measures only
/// Oneko's own CPU work, not WindowServer's). Prints a table you can compare between builds.
///
/// Scenarios, each with 1 / 50 / 500 / 5,000 real cats sharing one set of toys:
/// - idle: chasing a cursor that circles the screen (the 10 Hz tick, plus window reads)
/// - physics: every cat thrown at once (the 60 fps clock)
/// Then the owner's frame with every toy falling, and gravity mode's walking cats.
enum Bench {
    struct Result { var name: String; var cats: Int; var tickMs: Double; var frameMs: Double; var cpu: Double }

    static func run(counts: [Int] = [1, 50, 500, 5000]) {
        // For profiling (`sample`, Instruments): ONEKO_BENCH_LOOP=physics:5000 (or idle:500)
        // repeats just that scenario for 20 s.
        if let spec = ProcessInfo.processInfo.environment["ONEKO_BENCH_LOOP"] {
            let parts = spec.split(separator: ":")
            let n = parts.count > 1 ? Int(parts[1]) ?? 5000 : 5000
            let end = CACurrentMediaTime() + 20
            var runs = 0
            while CACurrentMediaTime() < end { _ = parts.first == "idle" ? idle(n) : physics(n); runs += 1 }
            print("\(spec): \(runs) runs")
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        print("Oneko \(version) bench (headless simulation; ms per call, CPU = 10 ticks + 60 frames per second)")
        print("scenario".padding(toLength: 35, withPad: " ", startingAt: 0) + "   cats    tick ms   frame ms    CPU %")
        for n in counts {
            for r in [idle(n), physics(n)] {
                print(r.name.padding(toLength: 35, withPad: " ", startingAt: 0) + String(format: "%7d %10.3f %10.3f %7.1f%%", r.cats, r.tickMs, r.frameMs, r.cpu))
            }
        }
        print(String(format: "toys: 50 boxes, 50 bones, 50 yarn and 3 bowls falling: %.3f ms a frame", toysThrown()))
        for n in [500, 5000] {
            print(String(format: "gravity mode: %d cats walking after the cursor: %.3f ms a frame", n, gravity(n)))
        }
        gpu()
        print("memory: \(residentMB()) MB resident")
    }

    /// GPU work, timed offscreen: the box heap (drawn once, then only when it changes) and
    /// one crowd tick (step + draw).
    static func gpu() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for n in [10_000, 1_000_000] {
            let heap = BoxHeap()
            let pos = BoxHeap.layout(count: n, screens: [screen], scale: 1)
            _ = heap.snapshot(pos, scale: 1, frame: screen)               // warm up
            let t0 = CACurrentMediaTime()
            _ = heap.snapshot(pos, scale: 1, frame: screen)
            print(String(format: "GPU: draw a heap of %@ boxes once: %.1f ms (layout %.1f ms on the CPU)",
                         n.formatted() as NSString, (CACurrentMediaTime() - t0) * 1000, layoutMs(n, screen)))
        }
        if let sheet = SpriteSheet.load() {
            for n in [20_000, 100_000] {
                let crowd = CrowdController()
                crowd.setHeap(BoxHeap.layout(count: 5000, screens: [screen], scale: 1))
                let t0 = CACurrentMediaTime()
                _ = crowd.selfCheck(count: n, sheets: [sheet], ticks: 10, cursor: CGPoint(x: 700, y: 400), screen: screen)
                print(String(format: "GPU: %@ crowd cats, 10 ticks + 1 frame: %.1f ms", n.formatted() as NSString,
                             (CACurrentMediaTime() - t0) * 1000))
            }
        }
    }

    static func layoutMs(_ n: Int, _ screen: CGRect) -> Double {
        let t0 = CACurrentMediaTime()
        _ = BoxHeap.layout(count: n, screens: [screen], scale: 1)
        return (CACurrentMediaTime() - t0) * 1000
    }

    // MARK: - Scenarios

    static let screens = [
        ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 949),
                   dock: CGRect(x: 400, y: 0, width: 700, height: 70)),
        ScreenInfo(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), visible: CGRect(x: 1512, y: 0, width: 2560, height: 1415)),
    ]
    static let windows = (0..<10).map { i in
        WindowInfo(id: 100 + i, pid: 1, frame: CGRect(x: 120 + i * 260, y: 200 + (i % 3) * 180, width: 600, height: 420))
    }

    /// A pile, `n` cats around the cursor, and the toys of a busy desktop (wired like the app).
    static func make(_ n: Int) -> [Playground] {
        let pile = ToyPile()
        var cats: [Playground] = []
        for i in 0..<n {
            let o = AppDelegate.swarmOffset(i, scale: 1)
            var p = Playground(position: CGPoint(x: 700 + o.dx * 0.3, y: 500 + o.dy * 0.3))
            p.toys = pile
            p.catID = i
            p.ownsToys = i == 0
            p.spotWindows = i == 0; p.spotMenuBar = i == 0; p.spotDock = i == 0
            p.random = { Dice.roll($0) }   // the app's default
            cats.append(p)
        }
        Setup.toys(&cats)
        return cats
    }

    /// Feature hooks: each feature adds its toys here so the bench always runs the whole app.
    enum Setup {
        static func toys(_ cats: inout [Playground]) {
            guard !cats.isEmpty else { return }
            for i in 0..<10 { cats[0].placeBox(at: CGPoint(x: 200 + CGFloat(i) * 60, y: 15), falling: false, index: i) }
            cats[0].toys.heap = BoxHeap.layout(count: 5000, screens: screens.map(\.frame), scale: 1)
            for i in 0..<10 { cats[0].placeBone(at: CGPoint(x: 900 + CGFloat(i) * 30, y: 5), falling: false, index: i) }
            for i in 0..<10 { cats[0].placeYarn(at: CGPoint(x: 1300 + CGFloat(i) * 30, y: 8), falling: false, index: i) }
            for i in 0..<10 { cats[0].toys.bones[i].wanted = true }   // everyone wants to fetch
            for i in 0..<3 { cats[0].placeBowl(at: CGPoint(x: 150 + CGFloat(i) * 300, y: 3.5), falling: false, index: i) }
            for i in cats.indices where i % 4 == 0 { cats[i].makeHungry() }   // a quarter want dinner
            cats[0].toys.setBig(0, true)
            for i in cats.indices { cats[i].laser = false }
        }
    }

    static func world(_ t: Int, mouseDown: Bool = false) -> World {
        let a = Double(t) * 0.05
        let cursor = CGPoint(x: 1500 + cos(a) * 900, y: 600 + sin(a) * 300)
        return World(screens: screens, windows: windows, cursor: cursor, mouseDown: mouseDown)
    }

    static func idle(_ n: Int) -> Result {
        var cats = make(n)
        let ticks = n >= 5000 ? 60 : 200
        let start = CACurrentMediaTime()
        for t in 0..<ticks { tick(&cats, t) }
        let tickMs = (CACurrentMediaTime() - start) / Double(ticks) * 1000
        // Idle cats need no 60 fps frames; time one frame anyway (the app skips them).
        let f0 = CACurrentMediaTime()
        frame(&cats, ticks, onlyMoving: true)
        let frameMs = (CACurrentMediaTime() - f0) * 1000
        let moving = cats.contains { $0.needsPhysics }
        return Result(name: "idle: chase a circling cursor", cats: n, tickMs: tickMs, frameMs: frameMs,
                      cpu: (tickMs * 10 + (moving ? frameMs * 60 : 0)) / 10)
    }

    static func physics(_ n: Int) -> Result {
        var cats = make(n)
        for i in cats.indices {
            let p = cats[i].cat.position
            cats[i].launch(at: p, velocity: CGVector(dx: CGFloat((i * 37) % 1200) - 600, dy: 1400))
        }
        let frames = n >= 5000 ? 30 : 120
        let start = CACurrentMediaTime()
        for t in 0..<frames {
            frame(&cats, t, onlyMoving: true)
            if t % 6 == 0 { tick(&cats, t / 6) }
        }
        let total = (CACurrentMediaTime() - start) / Double(frames) * 1000
        return Result(name: "physics: everyone thrown at once", cats: n, tickMs: 0, frameMs: total, cpu: total * 60 / 10)
    }

    /// The most toys the app allows, all dropped at once from different heights onto the floor
    /// and each other (boxes stack, the rest land on their rims): the first cat's frame, which
    /// moves them. Averaged over the first second, while they fall and settle.
    static func toysThrown() -> Double {
        var total = 0.0
        let runs = 5
        for _ in 0..<runs {
            var cats = make(1)
            for i in 0..<50 {
                let x = 60 + CGFloat(i % 25) * 56, y = 300 + CGFloat(i / 25) * 220 + CGFloat(i % 7) * 30
                cats[0].placeBox(at: CGPoint(x: x, y: y), falling: true, index: i)
                cats[0].placeBone(at: CGPoint(x: x + 10, y: y + 120), falling: true, index: i)
                cats[0].placeYarn(at: CGPoint(x: x - 10, y: y + 200), falling: true, index: i)
            }
            for i in 0..<3 { cats[0].placeBowl(at: CGPoint(x: 300 + CGFloat(i) * 400, y: 700), falling: true, index: i) }
            let start = CACurrentMediaTime()
            for t in 0..<60 { frame(&cats, t, onlyMoving: false) }
            total += (CACurrentMediaTime() - start) / 60 * 1000
        }
        return total / Double(runs)
    }

    /// Toolbox (gravity) mode: every cat walks along the floor, the Dock and the box rims
    /// after the circling cursor. A frame (60 fps), with a tick every sixth.
    static func gravity(_ n: Int) -> Double {
        var cats = make(n)
        for i in cats.indices { cats[i].gravityMode = true }
        for t in 0..<3 { tick(&cats, t) }   // off they go
        let frames = n >= 5000 ? 60 : 120
        let start = CACurrentMediaTime()
        for t in 0..<frames {
            frame(&cats, t, onlyMoving: true)
            if t % 6 == 0 { tick(&cats, 3 + t / 6) }
        }
        return (CACurrentMediaTime() - start) / Double(frames) * 1000
    }

    static func tick(_ cats: inout [Playground], _ t: Int) {
        if t % 20 == 0 {   // pairing cats up to play, every 2 s like the app
            let pairs = PlayMatcher.pairs(cats.map(\.cat.position), free: cats.indices.map { Playground.canPlay(&cats[$0]) }, radius: 50,
                                          chance: { Dice.roll($0) })
            for (a, b) in pairs {
                cats[a].startPlay(.groom, with: cats[b].cat.position, leader: true)
                cats[b].startPlay(.groom, with: cats[a].cat.position, leader: false)
            }
        }
        var w = world(t)
        let cursor = w.cursor   // (not world(t) again per cat: the app doesn't rebuild its World either)
        let squash: CGFloat = 1
        for i in cats.indices {
            if i % 10 == 0 || Playground.needsWindowTracking(&cats[i]) { cats[i].updateWindows(w, dt: 0.1) }
            let o = AppDelegate.swarmOffset(i, scale: 1)
            w.cursor = CGPoint(x: cursor.x + o.dx * squash, y: cursor.y + o.dy * squash)
            cats[i].tick10(world: w)
            _ = cats[i].drainEvents()
            _ = Playground.pose(&cats[i])   // in place, like the app's ExtraCat.pose
        }
    }

    static func frame(_ cats: inout [Playground], _ t: Int, onlyMoving: Bool) {
        let w = world(t)
        for i in cats.indices where !onlyMoving || Playground.needsPhysics(&cats[i]) || i == 0 {
            cats[i].physics(dt: 1.0 / 60, world: w)
            _ = cats[i].drainEvents()
            _ = Playground.pose(&cats[i])   // in place, like the app's ExtraCat.pose
        }
    }


    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : 0
    }
}
