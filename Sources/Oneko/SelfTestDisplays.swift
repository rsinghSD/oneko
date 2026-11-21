import Foundation

extension SelfTest {
    /// 0.5.5: the real Dock (not the whole strip), and crossing between displays.
    static func displayChecks(_ check: (Bool, String) -> Void) {
        // An ultrawide with a MacBook to its left, bottoms lined up (the layout that glitched).
        let wide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let mac = CGRect(x: -1680, y: 0, width: 1680, height: 1050)
        let both = [wide, mac]

        // Heading for the MacBook from high up on the ultrawide: it walks down the shared edge,
        // hops over once, and never jumps further than a hop.
        var b = NekoBrain(position: CGPoint(x: 300, y: 1350))
        b.random = { _ in 1 }
        let cursor = CGPoint(x: -400, y: 900)
        var biggest: CGFloat = 0, sides: [Bool] = []
        for _ in 0..<400 {
            let before = b.position
            b.tick(cursor: cursor, screens: both)
            biggest = max(biggest, hypot(b.position.x - before.x, b.position.y - before.y))
            let onMac = b.position.x < 0
            if sides.last != onMac { sides.append(onMac) }
        }
        check(biggest <= 2 * b.halfSize + 0.5, "crossing to the other display: no jump bigger than a hop (\(Int(biggest)) pt)")
        check(sides == [false, true], "it crosses over exactly once (\(sides))")
        check(hypot(b.position.x - cursor.x, b.position.y - cursor.y) < 60, "...and reaches the cursor on the MacBook")
        check(both.contains { $0.insetBy(dx: 16, dy: 16).contains(b.position) }, "...staying whole on one display")

        // Cursor parked in the MacBook's top-right corner, cat above it on the ultrawide: it
        // settles instead of flicking between the displays.
        var c = NekoBrain(position: CGPoint(x: 40, y: 1300))
        c.random = { _ in 1 }
        var flips = 0, last = c.position.x < 0
        for _ in 0..<200 {
            c.tick(cursor: CGPoint(x: -5, y: 1045), screens: both)
            if (c.position.x < 0) != last { flips += 1; last = c.position.x < 0 }
        }
        check(flips <= 1, "a cursor in the corner where displays meet doesn't make it flicker (\(flips) flips)")

        // Stacked displays: same rule, through the shared horizontal edge.
        let top = CGRect(x: 600, y: 1440, width: 1680, height: 1050)
        var s = NekoBrain(position: CGPoint(x: 3000, y: 100))
        s.random = { _ in 1 }
        var jump: CGFloat = 0
        for _ in 0..<500 {
            let before = s.position
            s.tick(cursor: CGPoint(x: 1000, y: 2000), screens: [wide, top])
            jump = max(jump, hypot(s.position.x - before.x, s.position.y - before.y))
        }
        check(jump <= 32 + 10 && hypot(s.position.x - 1000, s.position.y - 2000) < 60,
              "stacked displays: it goes up through the shared edge, never more than a hop and a step (\(Int(jump)) pt)")

        // The Dock is the Dock, not the whole strip at the bottom.
        let prefs = WorldReader.DockPrefs(autohide: false, edge: "bottom", tile: 42, delay: 0.3,
                                          icons: 27, separators: 2)
        WorldReader.prefsOverride = prefs
        WorldReader.axOverride = .some(nil)
        defer { WorldReader.prefsOverride = nil; WorldReader.axOverride = nil }
        let len = WorldReader.dockLength(prefs)
        check(abs(len - 1239) < 15, "27 icons at 42 pt make a Dock about 1239 pt long (\(Int(len)))")
        let docked = WorldReader.dockedScreens([(wide, CGRect(x: 0, y: 62, width: 3440, height: 1347)),
                                                (mac, mac)], cursor: .zero)
        let d = docked[0].dock
        check(d.map { abs($0.midX - wide.midX) < 1 && abs($0.width - len) < 1 && $0.maxY == 62 } ?? false,
              "the Dock sits centred at the bottom, as long as its icons (\(String(describing: d)))")
        check(docked[1].dock == nil, "no Dock on the other display")
        check(docked[0].floor(at: wide.midX) == 62 && docked[0].floor(at: 200) == 0,
              "things land on top of the Dock, and beside it on the real bottom of the screen")

        // A MacBook on its own that reports no room for an always-shown Dock: it's still there.
        let alone = WorldReader.dockedScreens([(mac, mac)], cursor: .zero)
        check(alone[0].dock.map { $0.minY == 0 && $0.height == 62 && abs($0.midX - mac.midX) < 1 } ?? false,
              "an always-shown Dock counts even when the display doesn't report room for it")
        WorldReader.prefsOverride = DockPrefs(prefs, autohide: true)
        check(WorldReader.dockedScreens([(mac, mac)], cursor: CGPoint(x: -800, y: 500))[0].dock == nil,
              "...but an auto-hiding one that's hidden doesn't")
        WorldReader.prefsOverride = prefs

        // With Accessibility, the exact frame wins.
        WorldReader.axOverride = .some(CGRect(x: 1000, y: 6, width: 1400, height: 50))
        let exact = WorldReader.dockedScreens([(wide, CGRect(x: 0, y: 62, width: 3440, height: 1347))], cursor: .zero)[0].dock
        check(exact == CGRect(x: 995, y: 0, width: 1410, height: 62), "the exact Dock frame is used when allowed (\(String(describing: exact)))")
        WorldReader.axOverride = .some(nil)

        // Counting what's in the Dock.
        let kept: [[String: Any]] = [
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.Safari"]],
            ["tile-type": "spacer-tile", "tile-data": [:] as [String: Any]],
            ["tile-type": "small-spacer-tile", "tile-data": [:] as [String: Any]],
        ]
        let items = WorldReader.dockItems(persistent: kept, others: 1, recents: ["a", "com.apple.Safari"],
                                          running: ["com.apple.finder", "com.apple.Safari", "b", "a"])
        check(items.icons == 2 + 2.5 + 2 + 1 && items.separators == 2,
              "Dock items: Finder, Trash, kept apps and spacers, running and recent apps once each (\(items))")

        // Floating cat on a Dock-less patch: dropped beside the Dock it falls to the bottom.
        let w = World(screens: docked, windows: [], cursor: CGPoint(x: 3000, y: 800))
        var p = Playground(position: CGPoint(x: 200, y: 400))
        p.spotWindows = false; p.spotMenuBar = false; p.spotDock = false
        p.launch(at: CGPoint(x: 200, y: 400), velocity: .zero)
        for _ in 0..<240 { p.physics(dt: 1.0 / 60, world: w) }
        check(abs(p.cat.position.y - (16 - 3)) < 1, "beside the Dock it lands on the bottom of the screen (y=\(Int(p.cat.position.y)))")
        var q = Playground(position: CGPoint(x: wide.midX, y: 400))
        q.spotWindows = false; q.spotMenuBar = false; q.spotDock = false
        q.launch(at: CGPoint(x: wide.midX, y: 400), velocity: .zero)
        for _ in 0..<240 { q.physics(dt: 1.0 / 60, world: w) }
        check(abs(q.cat.position.y - (62 + 16 - 3)) < 1, "over the Dock it lands on top of it (y=\(Int(q.cat.position.y)))")
    }
}

extension SelfTest {
    /// 0.5.5: how many cats, crowd mode, coats.
    static func catCountChecks(_ check: (Bool, String) -> Void) {
        let suite = "local.oneko.selftest.cats"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let s = Settings(defaults: UserDefaults(suiteName: suite)!)
        check(s.catCount == 1 && !s.crowdMode && s.catBehavior == .swarm && s.coatMode == .rotate,
              "defaults: 1 cat, crowd mode off, swarm, coats take turns")
        s.catCount = 0
        check(s.catCount == 0, "0 cats is allowed (just the toys)")
        s.catCount = 1000
        check(s.catCount == 1000 && s.realCatCount == 1000 && s.crowdCatCount == 0,
              "without crowd mode, 1,000 cats are 1,000 real cats")
        s.catCount = 50_000
        check(s.catCount == 10_000, "real cats stop at 10,000 (\(s.catCount))")
        s.crowdMode = true
        check(s.realCatCount == 50 && s.crowdCatCount == 9_950, "crowd mode: 50 real cats, the rest crowd cats")
        s.catCount = 5_000_000
        check(s.catCount == 1_000_000, "crowd mode goes up to 1,000,000 (\(s.catCount))")
        s.crowdMode = false
        check(s.catCount == 10_000, "turning crowd mode off drops back to 10,000 real cats")
        check(Skin.random(seed: 7).fill == Skin.random(seed: 7).fill && Skin.random(seed: 7).fill != Skin.random(seed: 8).fill,
              "random coats are the same for the same cat and differ between cats")
        let offsets = (0..<49).map { AppDelegate.swarmOffset($0, scale: 1) }
        let closest = offsets.enumerated().flatMap { i, a in offsets[(i + 1)...].map { hypot(a.dx - $0.dx, a.dy - $0.dy) } }.min() ?? 0
        check(closest > 15, "swarm spots don't overlap (closest \(Int(closest)) pt apart)")

        // The crowd's GPU code: compiles, swarms the cursor, and paints cats.
        let crowd = CrowdController()
        check(crowd.isAvailable, "crowd mode's GPU code compiles")
        if let sheet = SpriteSheet.load(),
           let r = crowd.selfCheck(count: 2000, sheets: [sheet, sheet.recolored(Skin.all[2])], ticks: 120,
                                   cursor: CGPoint(x: 600, y: 400), screen: CGRect(x: 0, y: 0, width: 1200, height: 800)) {
            check(r.median < 460, "2,000 crowd cats swarm in from 650 pt away to around the cursor (median \(Int(r.median)) pt away)")
            check(r.pixels > 20_000, "...and get drawn (\(r.pixels) pixels)")
        } else {
            check(false, "crowd self-check ran")
        }
    }
}

private extension WorldReader.DockPrefs {
    init(_ p: WorldReader.DockPrefs, autohide: Bool) {
        self = p
        self.autohide = autohide
    }
}

private typealias DockPrefs = WorldReader.DockPrefs
