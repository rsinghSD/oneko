import Foundation

/// Headless checks of the state machine: `Oneko --selftest`.
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            print((cond ? "PASS " : "FAIL ") + msg)
            if !cond { ok = false }
        }

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 1. Cursor far to the north-east: cat looks alert first, then runs NE and closes in.
        var b = NekoBrain(position: CGPoint(x: 100, y: 100))
        b.random = { _ in 1 }
        for _ in 0..<12 { b.tick(cursor: CGPoint(x: 100, y: 100), screens: [screen]) } // build idleTime
        b.tick(cursor: CGPoint(x: 800, y: 800), screens: [screen])
        check(b.sprite == .alert, "alert before running (got \(b.sprite))")
        var seen = Set<SpriteName>()
        for _ in 0..<200 { b.tick(cursor: CGPoint(x: 800, y: 800), screens: [screen]); seen.insert(b.sprite) }
        check(seen.contains(.NE), "ran north-east toward a cursor up and to the right")
        let d = hypot(b.position.x - 800, b.position.y - 800)
        check(d < 48, "caught up with the cursor (distance \(Int(d)))")
        check(b.sprite == .idle, "sits idle next to the cursor (got \(b.sprite))")

        // 2. Direction mapping in y-up space.
        for (cursor, want) in [(CGPoint(x: 500, y: 900), SpriteName.N), (CGPoint(x: 500, y: 0), .S),
                               (CGPoint(x: 0, y: 500), .W), (CGPoint(x: 1000, y: 500), .E)] {
            var c = NekoBrain(position: CGPoint(x: 500, y: 500))
            c.tick(cursor: cursor, screens: [screen])
            check(c.sprite == want, "cursor \(cursor) -> \(want) (got \(c.sprite))")
        }

        // 3. Idle long enough with a forced roll -> tired, then sleeping.
        var s = NekoBrain(position: CGPoint(x: 500, y: 500))
        var rolls = [0, 0]   // first roll: start an idle animation; second: pick "sleeping"
        s.random = { _ in rolls.isEmpty ? 1 : rolls.removeFirst() }
        var states: [SpriteName] = []
        for _ in 0..<40 { s.tick(cursor: CGPoint(x: 500, y: 500), screens: [screen]); states.append(s.sprite) }
        check(states.contains(.tired) && states.last == .sleeping, "gets tired, then falls asleep")

        // 4. Near the right edge, wall scratching becomes possible.
        var w = NekoBrain(position: CGPoint(x: 1430, y: 500))
        var wrolls = [0, 2]  // choices = [sleeping, scratchSelf, scratchWallE]
        w.random = { _ in wrolls.isEmpty ? 1 : wrolls.removeFirst() }
        for _ in 0..<12 { w.tick(cursor: CGPoint(x: 1430, y: 500), screens: [screen]) }
        check(w.sprite == .scratchWallE, "scratches the east wall at the right edge (got \(w.sprite))")

        // 5. Never leaves the screen.
        var e = NekoBrain(position: CGPoint(x: 1400, y: 500))
        for _ in 0..<50 { e.tick(cursor: CGPoint(x: 5000, y: 500), screens: [screen]) }
        check(e.position.x <= screen.maxX - 16, "clamped inside the display (x=\(e.position.x))")

        // 6. Pause: sleeps in place.
        var p = NekoBrain(position: CGPoint(x: 500, y: 500))
        p.paused = true
        for _ in 0..<20 { p.tick(cursor: CGPoint(x: 1000, y: 800), screens: [screen]) }
        check(p.position == CGPoint(x: 500, y: 500) && p.sprite == .sleeping, "paused cat sleeps and stays put")

        // 7. Large cat (3×) stops further from the cursor and stays fully on screen.
        var big = NekoBrain(position: CGPoint(x: 200, y: 200))
        big.halfSize = 48
        big.random = { _ in 1 }   // no random grooming mid-test
        for _ in 0..<200 { big.tick(cursor: CGPoint(x: 900, y: 600), screens: [screen]) }
        let bd = hypot(big.position.x - 900, big.position.y - 600)
        check(bd < 80 && bd >= 70 && big.sprite == .idle, "3× cat sits ~80 pt away (distance \(Int(bd)))")
        for _ in 0..<100 { big.tick(cursor: CGPoint(x: 5000, y: 5000), screens: [screen]) }
        check(big.position.x <= screen.maxX - 48 && big.position.y <= screen.maxY - 48,
              "3× cat stays fully inside the display (\(big.position))")

        // 8. Naps off: the idle roll can't pick sleeping.
        var n = NekoBrain(position: CGPoint(x: 500, y: 500))
        n.sleepEnabled = false
        var nrolls = [0, 0]  // choices = [scratchSelf]
        n.random = { _ in nrolls.isEmpty ? 1 : nrolls.removeFirst() }
        var nstates = Set<SpriteName>()
        for _ in 0..<40 { n.tick(cursor: CGPoint(x: 500, y: 500), screens: [screen]); nstates.insert(n.sprite) }
        check(nstates.contains(.scratchSelf) && !nstates.contains(.sleeping) && !nstates.contains(.tired),
              "with naps off the cat grooms instead of sleeping")

        // 9. Settings persist.
        let suite = "local.oneko.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let s1 = Settings(defaults: defaults)
        check(s1.speed == .normal && s1.size == .small && s1.naps && s1.hideInFullScreen && s1.lastPosition == nil,
              "defaults: normal speed, 1×, naps on, hide in full screen on")
        s1.speed = .zoomies; s1.size = .large; s1.naps = false; s1.lastPosition = CGPoint(x: 12, y: 34)
        let s2 = Settings(defaults: defaults)
        check(s2.speed == .zoomies && s2.size == .large && !s2.naps && s2.lastPosition == CGPoint(x: 12, y: 34),
              "settings and last position survive a relaunch")
        UserDefaults().removePersistentDomain(forName: suite)

        check(Settings.Speed.zoomies.rawValue == 2 * 24, "zoomies is twice as fast as before (48 pt/tick)")

        playgroundChecks(check)
        toolboxChecks(check)
        touchBarChecks(check)
        extrasChecks(check)

        print(ok ? "All checks passed." : "Some checks failed.")
        return ok
    }
}

extension SelfTest {
    /// Toys, physics, nap spots and window collisions, all headless.
    static func playgroundChecks(_ check: (Bool, String) -> Void) {
        let scr = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 60, width: 1440, height: 815))  // Dock 60, menu bar 25
        func world(_ cursor: CGPoint, _ windows: [WindowInfo] = [], mouseDown: Bool = false) -> World {
            World(screens: [scr], windows: windows, cursor: cursor, mouseDown: mouseDown)
        }
        func quiet(_ p: inout Playground) { p.cat.random = { _ in 1 }; p.random = { _ in 0 } }
        func tick(_ p: inout Playground, _ w: World) { p.updateWindows(w, dt: 0.1); p.tick10(world: w) }

        // A. Yeet: a fast throw flies, lands on the Dock, rights itself, and is angry about it.
        var a = Playground(position: CGPoint(x: 700, y: 500))
        quiet(&a)
        let wa = world(CGPoint(x: 700, y: 500))
        a.mouseDown(on: .cat, at: CGPoint(x: 700, y: 500), time: 0)
        a.mouseDragged(to: CGPoint(x: 720, y: 520), time: 0.01)
        a.mouseDragged(to: CGPoint(x: 760, y: 560), time: 0.03)
        a.mouseUp(at: CGPoint(x: 800, y: 600), time: 0.05)
        check(a.mode == .flying, "a fast throw sends the cat flying (got \(a.mode))")
        var spun = false
        for _ in 0..<900 {
            a.physics(dt: 1.0 / 60, world: wa)
            if abs(a.catPose.angle) > 1 { spun = true }
            if case .dazed = a.mode { break }
        }
        check(spun, "it tumbles in the air")
        if case .dazed = a.mode {} else { check(false, "it lands and sits dazed (got \(a.mode))") }
        check(abs(a.cat.position.y - (60 + 16 - 3)) < 0.5, "it lands on top of the Dock (y=\(a.cat.position.y))")
        check(a.catPose.angle == 0 && a.catPose.angry, "it's upright and shows 💢 after a yeet")
        for _ in 0..<30 { a.tick10(world: wa) }
        check(a.mode == .chasing && !a.catPose.angry, "it calms down and goes back to chasing")

        // B. A window dragged into the cat knocks it flying in that direction.
        var b = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&b)
        let w1 = WindowInfo(id: 1, pid: 9, frame: CGRect(x: 100, y: 300, width: 300, height: 300))
        var w2 = w1
        w2.frame.origin.x = 250
        tick(&b, world(CGPoint(x: 500, y: 500), [w1], mouseDown: true))
        tick(&b, world(CGPoint(x: 500, y: 500), [w2], mouseDown: true))
        check(b.mode == .flying && b.catBody.vel.dx > 0, "a window shoved right knocks the cat right (\(b.mode), vx=\(Int(b.catBody.vel.dx)))")
        // ...but a window that moves while the mouse is up (an app animating) does not.
        var b2 = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&b2)
        tick(&b2, world(CGPoint(x: 500, y: 500), [w1]))
        tick(&b2, world(CGPoint(x: 500, y: 500), [w2]))
        check(b2.mode != .flying, "windows moving on their own don't hit the cat")

        // C. Fetch: throw the bone, the cat catches up with it and brings it back to the cursor.
        var c = Playground(position: CGPoint(x: 300, y: 400))
        quiet(&c)
        let cursor = CGPoint(x: 300, y: 400)
        let wc = world(cursor)
        c.placeBone(at: CGPoint(x: 600, y: 63.5), falling: false)
        c.mouseDown(on: .bone, at: CGPoint(x: 600, y: 63.5), time: 0)
        c.mouseDragged(to: CGPoint(x: 620, y: 70), time: 0.01)
        c.mouseUp(at: CGPoint(x: 700, y: 120), time: 0.05)
        var took = false, dropped = false
        for i in 0..<6000 where !dropped {
            c.physics(dt: 1.0 / 60, world: wc)
            if i % 6 == 0 { c.tick10(world: wc) }
            for e in c.drainEvents() {
                if e == .boneTaken { took = true }
                if e == .boneDropped { dropped = true }
            }
        }
        check(took, "the cat picks up the thrown bone")
        check(dropped && c.bone.isResting, "...and drops it back off")
        let dropDist = hypot(c.bone.body.pos.x - cursor.x, c.bone.body.pos.y - cursor.y)
        check(dropDist < 70, "...right next to the cursor (\(Int(dropDist)) pt away)")

        // D. A cardboard box is an irresistible nap spot.
        var d = Playground(position: CGPoint(x: 400, y: 400))
        quiet(&d)
        let wd = world(CGPoint(x: 400, y: 400))
        d.placeBox(at: CGPoint(x: 900, y: 75), falling: false)
        for _ in 0..<300 where !d.inBox { d.tick10(world: wd) }
        for _ in 0..<20 { d.tick10(world: wd) }
        check(d.inBox && d.cat.sprite == .sleeping, "the cat walks over and sleeps in the box")
        check(d.cat.position == d.box.body.pos, "...sitting right inside it")

        // E. Napping on a window's title bar: it rides along, and falls off when the window closes.
        var e = Playground(position: CGPoint(x: 400, y: 400))
        quiet(&e)
        e.spotMenuBar = false
        e.spotDock = false
        let win = WindowInfo(id: 7, pid: 9, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        for _ in 0..<300 {
            tick(&e, world(CGPoint(x: 400, y: 400), [win]))
            if case .napping = e.mode { break }
        }
        let perch = e.cat.position
        check(abs(perch.y - (600 + 16 - 3)) < 0.5, "it naps sitting on the window's top edge (y=\(perch.y))")
        var moved = win
        moved.frame.origin = CGPoint(x: 300, y: 250)
        tick(&e, world(CGPoint(x: 400, y: 400), [moved]))
        check(e.cat.position == CGPoint(x: perch.x + 100, y: perch.y + 50), "it rides along when the window moves")
        tick(&e, world(CGPoint(x: 400, y: 400), []))
        check(e.mode == .flying, "it falls when the window closes")

        // H. Double-click: stay and sleep here, even when the cursor leaves; double-click to wake.
        var h = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&h)
        h.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0)
        h.mouseUp(at: CGPoint(x: 500, y: 500), time: 0.05, clickCount: 1)
        h.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0.2)
        h.mouseUp(at: CGPoint(x: 500, y: 500), time: 0.25, clickCount: 2)
        for _ in 0..<40 { h.tick10(world: world(CGPoint(x: 1200, y: 800))) }
        check(h.cat.sprite == .sleeping && h.cat.position == CGPoint(x: 500, y: 500), "double-clicked cat sleeps in place while the cursor is far away")
        h.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 1)
        h.mouseUp(at: CGPoint(x: 500, y: 500), time: 1.05, clickCount: 2)
        for _ in 0..<20 { h.tick10(world: world(CGPoint(x: 1200, y: 800))) }
        check(h.cat.position.x > 550, "double-click again and it wakes up and chases")

        // I. Throws are boosted: a modest flick still yeets.
        var y = Playground(position: CGPoint(x: 300, y: 300))
        quiet(&y)
        y.mouseDown(on: .cat, at: CGPoint(x: 300, y: 300), time: 0)
        y.mouseDragged(to: CGPoint(x: 310, y: 305), time: 0.01)
        y.mouseUp(at: CGPoint(x: 360, y: 330), time: 0.05)   // ~1300 pt/s of mouse
        check(hypot(y.catBody.vel.dx, y.catBody.vel.dy) > 2000, "a 1300 pt/s flick launches at >2000 pt/s (\(Int(hypot(y.catBody.vel.dx, y.catBody.vel.dy))))")

        // J. Held cat turns with your hand like a Wii remote: upright when still, spins
        //    around the cursor in step when you circle, keeps the spin when you let go.
        var j = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&j)
        let wj = world(CGPoint(x: 500, y: 500))
        j.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0)
        j.mouseDragged(to: CGPoint(x: 506, y: 500), time: 0.01)
        for _ in 0..<90 { j.physics(dt: 1.0 / 60, world: wj) }
        check(abs(j.catPose.angle) < 0.05 && j.cat.position.y < 500, "held still, it hangs upright under the cursor")
        var t = 0.01, turned: CGFloat = 0, last = j.catBody.angle
        for i in 0..<180 {   // circle the mouse counter-clockwise, 3× a second for 3 s
            let phi = Double(i) / 60 * 2 * .pi * 3
            t += 1.0 / 60
            j.mouseDragged(to: CGPoint(x: 506 + 40 * cos(phi), y: 500 + 40 * sin(phi)), time: t)
            j.physics(dt: 1.0 / 60, world: wj)
            turned += j.catBody.angle - last
            last = j.catBody.angle
        }
        check(turned > 2 * .pi * 7, "circling 9 times spins it ~9 times, same direction (\(String(format: "%.1f", turned / (2 * .pi))) turns)")
        let whirl = j.catBody.spin
        j.mouseUp(at: CGPoint(x: 506 + 40, y: 500), time: t + 0.005)
        check(j.mode == .flying && abs(whirl) > 10 && abs(j.catBody.spin - whirl) < 0.01,
              "let go mid-spin and it flies off still spinning (\(Int(whirl)) rad/s)")

        // K. Juggling: flick the window up under a sitting cat, it launches; leave the window
        //    there and it lands back on it; flick again.
        var k = Playground(position: CGPoint(x: 400, y: 400))
        quiet(&k)
        k.spotMenuBar = false
        k.spotDock = false
        let paddle = WindowInfo(id: 3, pid: 9, frame: CGRect(x: 200, y: 200, width: 600, height: 300))
        for _ in 0..<300 {
            tick(&k, world(CGPoint(x: 400, y: 400), [paddle]))
            if case .napping = k.mode { break }
        }
        var up = paddle
        up.frame.origin.y += 120   // 1200 pt/s upward flick
        tick(&k, world(CGPoint(x: 400, y: 400), [paddle], mouseDown: true))
        tick(&k, world(CGPoint(x: 400, y: 400), [up], mouseDown: true))
        check(k.mode == .flying && k.catBody.vel.dy > 1500, "flicking the window up launches the cat (vy=\(Int(k.catBody.vel.dy)))")
        var peak = k.cat.position.y
        for _ in 0..<600 {
            k.physics(dt: 1.0 / 60, world: world(.zero, [up]))
            peak = max(peak, k.cat.position.y)
            if case .landing = k.mode { break }
        }
        check(peak > up.frame.maxY + 200, "it flies way up (\(Int(peak - up.frame.maxY)) pt above the window)")
        check(k.mode == .landing(elapsed: 0, onWindow: 3) || { if case .landing(_, 3?) = k.mode { return true }; return false }(),
              "and comes back down onto the same window (\(k.mode))")
        for _ in 0..<30 { k.physics(dt: 1.0 / 60, world: world(.zero, [up])) }
        var up2 = up
        up2.frame.origin.y += 120
        tick(&k, world(CGPoint(x: 400, y: 400), [up], mouseDown: true))
        tick(&k, world(CGPoint(x: 400, y: 400), [up2], mouseDown: true))
        check(k.mode == .flying, "...and can be launched again")

        // L. A window swung into a flying cat bats it away.
        var l = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&l)
        l.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0)
        l.mouseDragged(to: CGPoint(x: 506, y: 500), time: 0.01)
        l.mouseUp(at: CGPoint(x: 506, y: 500), time: 0.5)   // just let go: it falls
        let bat1 = WindowInfo(id: 4, pid: 9, frame: CGRect(x: 100, y: 400, width: 300, height: 200))
        var bat2 = bat1
        bat2.frame.origin.x = 260
        tick(&l, world(.zero, [bat1], mouseDown: true))
        tick(&l, world(.zero, [bat2], mouseDown: true))
        check(l.mode == .flying && l.catBody.vel.dx > 1500 && l.cat.position.x > bat2.frame.maxX,
              "a window swung into a falling cat bats it away (vx=\(Int(l.catBody.vel.dx)))")

        // M. Drop the cat over the box: it lands inside and naps.
        var m = Playground(position: CGPoint(x: 900, y: 300))
        quiet(&m)
        m.placeBox(at: CGPoint(x: 900, y: 75), falling: false)
        m.mouseDown(on: .cat, at: CGPoint(x: 900, y: 300), time: 0)
        m.mouseDragged(to: CGPoint(x: 906, y: 300), time: 0.01)
        m.mouseUp(at: CGPoint(x: 906, y: 300), time: 0.5)
        for _ in 0..<240 where !m.inBox { m.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(m.inBox && m.cat.position == m.box.body.pos, "dropping the cat over the box puts it in the box")
        for _ in 0..<20 { m.tick10(world: world(CGPoint(x: 100, y: 800))) }
        check(m.inBox && m.cat.sprite == .sleeping, "...where it stays and naps, even when the cursor leaves")

        // N. A held bone twirls with your hand too, and keeps twirling when thrown.
        var n = Playground(position: CGPoint(x: 100, y: 100))
        quiet(&n)
        n.placeBone(at: CGPoint(x: 600, y: 400), falling: false)
        n.mouseDown(on: .bone, at: CGPoint(x: 600, y: 400), time: 0)
        n.mouseDragged(to: CGPoint(x: 606, y: 400), time: 0.01)
        var bt = 0.01, bturn: CGFloat = 0, blast = n.bone.body.angle
        for i in 0..<120 {
            let phi = Double(i) / 60 * 2 * .pi * 2
            bt += 1.0 / 60
            n.mouseDragged(to: CGPoint(x: 606 + 40 * cos(phi), y: 400 + 40 * sin(phi)), time: bt)
            n.physics(dt: 1.0 / 60, world: world(.zero))
            bturn += n.bone.body.angle - blast
            blast = n.bone.body.angle
        }
        check(bturn > 2 * .pi * 3, "circling a held bone twirls it (\(String(format: "%.1f", bturn / (2 * .pi))) turns)")
        let twirl = n.bone.body.spin
        n.mouseUp(at: CGPoint(x: 646, y: 400), time: bt + 0.005)
        check(n.bone.state == .flying && abs(twirl) > 5 && n.bone.body.spin == twirl, "a thrown bone keeps its twirl (\(Int(twirl)) rad/s)")

        // O. The Dock isn't a floor: walk into it and get yeeted out, landing on top of it.
        var o = Playground(position: CGPoint(x: 500, y: 90))
        quiet(&o)
        var docked = scr
        docked.dock = CGRect(x: 0, y: 0, width: 1440, height: 60)
        let wo = World(screens: [docked], windows: [], cursor: CGPoint(x: 500, y: 20))
        var yeeted = false
        for _ in 0..<20 where !yeeted {
            o.tick10(world: wo)
            if o.mode == .flying { yeeted = o.catBody.vel.dy > 1000 }
        }
        check(yeeted, "walking into the Dock yeets the cat up and out")
        for _ in 0..<600 {
            o.physics(dt: 1.0 / 60, world: wo)
            if case .landing = o.mode { break }
        }
        check(abs(o.cat.position.y - (60 + 16 - 3)) < 0.5, "...and it lands on top of the Dock (y=\(Int(o.cat.position.y)))")
        // ...but a cat on top of the Dock chasing a low cursor only dips its feet: no yeet,
        // it's nudged back on top.
        var dip = Playground(position: CGPoint(x: 500, y: 73))
        quiet(&dip)
        dip.spotMenuBar = false; dip.spotDock = false; dip.spotWindows = false
        let wdip = World(screens: [docked], windows: [], cursor: CGPoint(x: 700, y: 70))
        var dipYeets = 0
        for _ in 0..<100 {
            dip.tick10(world: wdip)
            if dip.mode == .flying { dipYeets += 1 }
        }
        check(dipYeets == 0 && dip.cat.position.y >= 60 + 13 - 0.01,
              "chasing a cursor just above the Dock never yeets it (it stays on top, y=\(Int(dip.cat.position.y)))")
        // A Dock that appears under a resting cat lifts it instead of yeeting it.
        var lift = Playground(position: CGPoint(x: 500, y: 40))
        quiet(&lift)
        lift.mouseDown(on: .cat, at: lift.cat.position, time: 0)
        lift.mouseUp(at: lift.cat.position, time: 0.05, clickCount: 2)   // stay
        lift.tick10(world: World(screens: [scr], windows: [], cursor: .zero))
        lift.tick10(world: World(screens: [docked], windows: [], cursor: .zero))
        check(lift.mode != .flying && abs(lift.cat.position.y - 73) < 0.01, "a Dock appearing under a resting cat lifts it onto the Dock")
        // After a Dock yeet there's a grace period: no yeet loop.
        var loop = Playground(position: CGPoint(x: 500, y: 30))
        quiet(&loop)
        loop.spotMenuBar = false; loop.spotDock = false; loop.spotWindows = false
        loop.tick10(world: wo)
        loop.tick10(world: wo)
        var starts: [Int] = [], wasFlying = false
        for i in 0..<360 {
            loop.physics(dt: 1.0 / 60, world: wo)
            if i % 6 == 0 { loop.tick10(world: wo) }
            let f = loop.mode == .flying
            if f && !wasFlying { starts.append(i) }
            wasFlying = f
        }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        check(gaps.allSatisfy { $0 >= 120 }, "Dock yeets are always at least 2 s apart (\(starts.count) in 6 s)")

        // Leading it along the Dock top towards a cursor in the Dock yeets it (small dips count).
        var lead = Playground(position: CGPoint(x: 200, y: 73))
        quiet(&lead)
        lead.spotMenuBar = false; lead.spotDock = false; lead.spotWindows = false
        let wlead = World(screens: [docked], windows: [], cursor: CGPoint(x: 900, y: 30))
        lead.tick10(world: wlead)
        var led = false
        for _ in 0..<80 where !led { lead.tick10(world: wlead); led = lead.mode == .flying }
        check(led, "following a cursor that's down in the Dock, it gets yeeted")

        // Sitting on the Dock right above a cursor that goes into the Dock: yeeted at once.
        var above = Playground(position: CGPoint(x: 500, y: 73))
        quiet(&above)
        above.spotMenuBar = false; above.spotDock = false; above.spotWindows = false
        above.tick10(world: World(screens: [docked], windows: [], cursor: CGPoint(x: 520, y: 120)))
        above.tick10(world: World(screens: [docked], windows: [], cursor: CGPoint(x: 520, y: 30)))
        check(above.mode == .flying, "a cat waiting on the Dock is yeeted as soon as your cursor goes into the Dock")

        // Auto-hide: a cat parked on the Dock falls when the Dock hides.
        var hide = Playground(position: CGPoint(x: 500, y: 73))
        quiet(&hide)
        hide.mouseDown(on: .cat, at: hide.cat.position, time: 0)
        hide.mouseUp(at: hide.cat.position, time: 0.05, clickCount: 2)   // stay right there
        hide.tick10(world: World(screens: [docked], windows: [], cursor: .zero))
        let gone = ScreenInfo(frame: scr.frame, visible: CGRect(x: 0, y: 4, width: 1440, height: 871))
        let wgone = World(screens: [gone], windows: [], cursor: .zero)
        hide.tick10(world: wgone)
        check(hide.mode == .flying, "when an auto-hiding Dock hides, the cat on top of it falls")
        for _ in 0..<240 { hide.physics(dt: 1.0 / 60, world: wgone) }
        check(abs(hide.cat.position.y - (4 + 13)) < 1, "...down to the real bottom of the screen (y=\(Int(hide.cat.position.y)))")
        // ...and so does a box sitting on it.
        var hbox = Playground(position: CGPoint(x: 900, y: 500))
        quiet(&hbox)
        hbox.placeBox(at: CGPoint(x: 500, y: 60 + 15), falling: false)
        hbox.tick10(world: World(screens: [docked], windows: [], cursor: CGPoint(x: 900, y: 500)))
        hbox.tick10(world: World(screens: [gone], windows: [], cursor: CGPoint(x: 900, y: 500)))
        check(hbox.box.state == .flying, "...and so does a box left on it")

        // A hidden Dock is just the bottom of the screen.
        var hidden = Playground(position: CGPoint(x: 500, y: 300))
        quiet(&hidden)
        hidden.spotMenuBar = false
        hidden.spotDock = false
        hidden.spotWindows = false
        let flat = ScreenInfo(frame: scr.frame, visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let wh = World(screens: [flat], windows: [], cursor: CGPoint(x: 500, y: 10))
        for _ in 0..<60 { hidden.tick10(world: wh) }
        check(hidden.mode == .chasing && hidden.cat.position.y < 60, "with the Dock hidden it walks right down to the bottom (\(hidden.mode), y=\(Int(hidden.cat.position.y)))")
        check(WorldReader.dockStrip(frame: scr.frame, visible: scr.visible, cursor: .zero) == CGRect(x: 0, y: 0, width: 1440, height: 60),
              "an always-visible Dock is found from the screen's visible frame")
        // Auto-hide follows macOS's rule: hovering near the bottom does nothing; pressing the
        // cursor against the bottom edge reveals it after the delay; leaving hides it.
        WorldReader.prefsOverride = .init(autohide: true, edge: "bottom", tile: 42, delay: 0.3)
        let ff = scr.frame, vv = CGRect(x: 0, y: 4, width: 1440, height: 871)
        let near = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 500, y: 30), now: 100)
        let touch0 = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 500, y: 0), now: 101)
        let touch1 = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 500, y: 0), now: 101.5)
        let over = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 600, y: 40), now: 102)
        let away = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 600, y: 300), now: 103)
        let back = WorldReader.dockStrip(frame: ff, visible: vv, cursor: CGPoint(x: 600, y: 40), now: 104)
        WorldReader.prefsOverride = nil
        check(near == nil && touch0 == nil, "auto-hide: a cursor near the bottom doesn't count as the Dock showing")
        check(touch1 != nil && over != nil, "...pushed against the bottom edge it does (after the delay), and stays while over it")
        check(away == nil && back == nil, "...and once you move away it's hidden again")

        check(o.mode != .staying(frame: 0) && { if case .staying = o.mode { return false }; return true }(),
              "a cat that wandered into the Dock doesn't park there")
        for _ in 0..<40 { o.tick10(world: wo) }
        if case .staying = o.mode { check(false, "...it goes back to chasing after being yeeted out") }

        // Q2. Put the cat on the Dock yourself and it stays there, not moving.
        var park = Playground(position: CGPoint(x: 500, y: 300))
        quiet(&park)
        park.mouseDown(on: .cat, at: CGPoint(x: 500, y: 300), time: 0)
        park.mouseDragged(to: CGPoint(x: 506, y: 300), time: 0.01)
        park.mouseUp(at: CGPoint(x: 506, y: 300), time: 0.5)
        let far = World(screens: [docked], windows: [], cursor: CGPoint(x: 1300, y: 800))
        for i in 0..<600 {
            park.physics(dt: 1.0 / 60, world: far)
            if i % 6 == 0 { park.tick10(world: far) }
        }
        for _ in 0..<20 { park.tick10(world: far) }
        let parkedAt = park.cat.position
        for _ in 0..<100 { park.tick10(world: far) }
        check({ if case .staying = park.mode { return true }; return false }() && park.cat.position == parkedAt
              && abs(parkedAt.y - (60 + 13)) < 1, "dropped on the Dock, it stays there and doesn't move (\(park.mode))")

        // Q4. Put it on a window and it stays there, riding along, not following the cursor.
        var pw = Playground(position: CGPoint(x: 500, y: 700))
        quiet(&pw)
        let ww = WindowInfo(id: 21, pid: 9, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        let wpw = World(screens: [scr], windows: [ww], cursor: CGPoint(x: 1300, y: 800))
        pw.updateWindows(wpw, dt: 0.1)
        pw.mouseDown(on: .cat, at: CGPoint(x: 500, y: 700), time: 0)
        pw.mouseDragged(to: CGPoint(x: 506, y: 700), time: 0.01)
        pw.mouseUp(at: CGPoint(x: 506, y: 700), time: 0.5)
        for i in 0..<300 {
            pw.physics(dt: 1.0 / 60, world: wpw)
            if i % 6 == 0 { tick(&pw, wpw) }
        }
        for _ in 0..<40 { tick(&pw, wpw) }
        let onWin = pw.cat.position
        check({ if case .staying = pw.mode { return true }; return false }() && abs(onWin.y - (600 + 13)) < 1,
              "dropped on a window, it stays on its title bar (\(pw.mode))")
        var moved2 = ww
        moved2.frame.origin = CGPoint(x: 260, y: 230)
        let wpw2 = World(screens: [scr], windows: [moved2], cursor: CGPoint(x: 1300, y: 800))
        tick(&pw, wpw2)
        for _ in 0..<40 { tick(&pw, wpw2) }
        check(pw.cat.position == CGPoint(x: onWin.x + 60, y: onWin.y + 30), "...rides along when the window moves, ignoring the cursor")
        tick(&pw, World(screens: [scr], windows: [], cursor: CGPoint(x: 1300, y: 800)))
        check(pw.mode == .flying, "...and falls when the window closes")

        // Q3. Dropped gently into the menu bar, it parks there too.
        var mb = Playground(position: CGPoint(x: 700, y: 885))
        quiet(&mb)
        mb.tick10(world: world(CGPoint(x: 700, y: 885)))
        mb.mouseDown(on: .cat, at: CGPoint(x: 700, y: 885), time: 0)
        mb.mouseDragged(to: CGPoint(x: 706, y: 886), time: 0.01)
        mb.mouseUp(at: CGPoint(x: 706, y: 886), time: 0.5)
        for _ in 0..<60 { mb.tick10(world: world(CGPoint(x: 100, y: 100))) }
        check({ if case .staying = mb.mode { return true }; return false }() && mb.cat.position.y > 875,
              "dropped in the menu bar, it stays up there (y=\(Int(mb.cat.position.y)))")

        // Q5. A 2× cat is too big for the menu bar: no naps there, and dropping it there drops it.
        var big2 = Playground(position: CGPoint(x: 700, y: 870))
        quiet(&big2)
        big2.setScale(2)
        big2.spotWindows = false
        big2.spotDock = false
        check(big2.chooseSpot(world(.zero)) == nil, "a 2× cat never picks the menu bar for a nap")
        big2.tick10(world: world(CGPoint(x: 700, y: 870)))
        big2.mouseDown(on: .cat, at: CGPoint(x: 700, y: 870), time: 0)
        big2.mouseDragged(to: CGPoint(x: 706, y: 871), time: 0.01)
        big2.mouseUp(at: CGPoint(x: 706, y: 871), time: 0.5)
        check(big2.mode == .flying, "...and dropped up there, it falls instead of parking")

        // P. Right-click closes the box: the cat stays in, rides along, rattles to get out.
        var q = Playground(position: CGPoint(x: 900, y: 300))
        quiet(&q)
        q.placeBox(at: CGPoint(x: 900, y: 75), falling: false)
        q.mouseDown(on: .cat, at: CGPoint(x: 900, y: 300), time: 0)
        q.mouseDragged(to: CGPoint(x: 906, y: 300), time: 0.01)
        q.mouseUp(at: CGPoint(x: 906, y: 300), time: 0.5)
        for _ in 0..<240 where !q.inBox { q.physics(dt: 1.0 / 60, world: world(.zero)) }
        q.toggleBoxLid()
        check(q.boxClosed && q.catPose.boxClosed && q.inBox, "right-click shuts the box with the cat inside")
        q.mouseDown(on: .box, at: CGPoint(x: 900, y: 75), time: 1)
        q.mouseDragged(to: CGPoint(x: 1000, y: 300), time: 1.05)
        q.mouseUp(at: CGPoint(x: 1000, y: 300), time: 1.6)
        check(q.inBox && q.cat.position == q.box.body.pos, "carrying the closed box carries the cat")
        for _ in 0..<240 { q.physics(dt: 1.0 / 60, world: world(.zero)) }
        for _ in 0..<1300 { q.tick10(world: world(CGPoint(x: 100, y: 800))) }
        q.tick10(world: world(CGPoint(x: 100, y: 800)))
        check(q.inBox && q.catPose.rattle != 0, "when its nap is over, the closed box rattles")
        q.toggleBoxLid()
        check(!q.boxClosed && q.mode == .flying, "open it and the cat pops out")
        q.toggleBoxLid()
        for _ in 0..<600 where q.mode != .chasing {
            q.physics(dt: 1.0 / 60, world: world(.zero))
            q.tick10(world: world(CGPoint(x: 100, y: 800)))
        }
        check(q.chooseSpot(world(.zero)) == nil || q.chooseSpot(world(.zero))?.kind != .box, "an empty closed box isn't a nap spot")

        // R. Throw the cat, then catch it in the box you're holding, and carry it off.
        var r = Playground(position: CGPoint(x: 700, y: 600))
        quiet(&r)
        r.placeBox(at: CGPoint(x: 300, y: 75), falling: false)
        r.mouseDown(on: .cat, at: CGPoint(x: 700, y: 600), time: 0)
        r.mouseDragged(to: CGPoint(x: 706, y: 605), time: 0.01)
        r.mouseUp(at: CGPoint(x: 720, y: 640), time: 0.05)   // toss it up a bit
        // Grab the box (a second "hand": the playground tracks one grab at a time, so the
        // cat is already flying when the box is picked up).
        r.mouseDown(on: .box, at: CGPoint(x: 300, y: 75), time: 0.06)
        r.mouseDragged(to: CGPoint(x: 400, y: 200), time: 0.07)
        var caught = false
        for i in 0..<300 where !caught {
            // Chase the falling cat with the box, keeping it just under it.
            let below = CGPoint(x: r.cat.position.x, y: r.cat.position.y - 40)
            r.mouseDragged(to: below, time: 0.07 + Double(i) / 60)
            r.physics(dt: 1.0 / 60, world: world(.zero))
            caught = r.inBox
        }
        check(caught && r.box.state == .held, "a thrown cat lands in the box you're holding")
        r.mouseDragged(to: CGPoint(x: 1000, y: 500), time: 6)
        check(r.inBox && r.cat.position == r.box.body.pos, "...and you can carry it off in the box")
        r.mouseUp(at: CGPoint(x: 1000, y: 500), time: 6.5)
        for _ in 0..<300 { r.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(r.inBox && r.box.isResting, "set the box down and the cat is still in it")

        // S. Right-click clips the cat in mid-air (even mid-throw); right-click again drops it.
        var u = Playground(position: CGPoint(x: 600, y: 300))
        quiet(&u)
        u.mouseDown(on: .cat, at: CGPoint(x: 600, y: 300), time: 0)
        u.mouseDragged(to: CGPoint(x: 610, y: 310), time: 0.01)
        u.mouseUp(at: CGPoint(x: 650, y: 380), time: 0.05)
        for _ in 0..<10 { u.physics(dt: 1.0 / 60, world: world(.zero)) }
        u.rightClick(.cat)
        let clippedAt = u.cat.position
        for _ in 0..<120 { u.physics(dt: 1.0 / 60, world: world(.zero)) }
        for _ in 0..<50 { u.tick10(world: world(CGPoint(x: 100, y: 800))) }
        check(u.catPose.clipped && u.cat.position == clippedAt && clippedAt.y > 200,
              "right-click mid-throw clips the cat in the air, and it stays put")
        check(u.cat.sprite == .sleeping, "...eventually dozing on its clip")
        u.rightClick(.cat)
        check(u.mode == .flying, "right-click again and it drops")
        // Mid-drag right-click clips it there too.
        var u2 = Playground(position: CGPoint(x: 600, y: 300))
        quiet(&u2)
        u2.mouseDown(on: .cat, at: CGPoint(x: 600, y: 300), time: 0)
        u2.mouseDragged(to: CGPoint(x: 700, y: 500), time: 0.1)
        u2.rightClick(.cat)
        u2.mouseUp(at: CGPoint(x: 700, y: 500), time: 0.3)
        check(u2.catPose.clipped && !u2.isDragging, "right-clicking while dragging clips the cat where you hold it")

        // T. Same for the box: clip it mid-drag, it floats; a thrown cat can land in it.
        var v = Playground(position: CGPoint(x: 700, y: 800))
        quiet(&v)
        v.placeBox(at: CGPoint(x: 300, y: 75), falling: false)
        v.mouseDown(on: .box, at: CGPoint(x: 300, y: 75), time: 0)
        v.mouseDragged(to: CGPoint(x: 700, y: 500), time: 0.2)
        v.rightClick(.box)
        v.mouseUp(at: CGPoint(x: 700, y: 500), time: 0.4)
        for _ in 0..<120 { v.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(v.box.state == .pinned && v.box.body.pos == CGPoint(x: 700, y: 500), "right-click while dragging the box clips it in the air")
        v.mouseDown(on: .cat, at: CGPoint(x: 700, y: 800), time: 1)
        v.mouseDragged(to: CGPoint(x: 706, y: 800), time: 1.01)
        v.mouseUp(at: CGPoint(x: 706, y: 800), time: 1.5)
        for _ in 0..<240 where !v.inBox { v.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(v.inBox, "a cat dropped above a clipped box lands in it")
        v.rightClick(.box)
        check(v.box.state == .flying, "right-click the clipped box and it drops")

        // F. Things that fall land on window title bars too.
        var f = Prop(shape: Shape(halfW: 8, halfH: 3.5, foot: 0, bounce: 0.45), uprightStep: .pi)
        f.body = Body(pos: CGPoint(x: 400, y: 800))
        var result = StepResult.flying
        for _ in 0..<600 {
            result = Physics.step(&f.body, shape: f.shape, dt: 1.0 / 60, world: world(.zero, [win]))
            if case .rested = result { break }
        }
        check(result == .rested(onWindow: 7, impact: result.impactForTest) && abs(f.body.pos.y - 603.5) < 0.5,
              "a dropped bone lands on a title bar (\(result), y=\(f.body.pos.y))")
    }
}

extension StepResult {
    var impactForTest: CGFloat {
        if case .rested(_, let i) = self { return i }
        return -1
    }
}

extension SelfTest {
    /// Toolbox mode: Paint drawings as solid shapes, and what the tools do to Neko.
    static func toolboxChecks(_ check: (Bool, String) -> Void) {
        let scr = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 60, width: 1440, height: 815))
        func world(_ cursor: CGPoint, _ drawings: [Drawing] = []) -> World {
            var w = World(screens: [scr], windows: [], cursor: cursor)
            w.drawings = drawings
            return w
        }
        func quiet(_ p: inout Playground) { p.cat.random = { _ in 1 }; p.random = { _ in 1 } }
        func drop(_ p: inout Playground, at pt: CGPoint) {
            p.mouseDown(on: .cat, at: pt, time: 0)
            p.mouseDragged(to: CGPoint(x: pt.x + 6, y: pt.y), time: 0.01)
            p.mouseUp(at: CGPoint(x: pt.x + 6, y: pt.y), time: 0.5)
        }

        // 1. A drawn line catches a falling cat; erase the line and it falls.
        let shelf = Drawing(id: -2, kind: .line, points: [CGPoint(x: 300, y: 400), CGPoint(x: 800, y: 400)],
                            closed: false, color: RGBA(r: 0, g: 0, b: 0))
        var a = Playground(position: CGPoint(x: 500, y: 650))
        quiet(&a)
        drop(&a, at: CGPoint(x: 500, y: 650))
        for _ in 0..<300 {
            a.physics(dt: 1.0 / 60, world: world(.zero, [shelf]))
            if case .landing = a.mode { break }
        }
        let feet = a.cat.position.y - 16 + 3
        check(abs(feet - 400) < 4, "a Pencil line catches a falling cat (feet at \(Int(feet)))")
        for _ in 0..<30 { a.physics(dt: 1.0 / 60, world: world(.zero, [shelf])) }
        a.updateWindows(world(.zero, [shelf]), dt: 0.1)
        a.updateWindows(world(.zero, []), dt: 0.1)
        check(a.mode == .flying, "erase the line and the cat falls")

        // 2. A steep line is a wall: a cat thrown at it bounces back.
        let wall = Drawing(id: -3, kind: .line, points: [CGPoint(x: 700, y: 100), CGPoint(x: 700, y: 800)],
                           closed: false, color: RGBA(r: 0, g: 0, b: 0))
        var b = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&b)
        b.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0)
        b.mouseDragged(to: CGPoint(x: 510, y: 500), time: 0.01)
        b.mouseUp(at: CGPoint(x: 560, y: 500), time: 0.05)
        var bounced = false
        for _ in 0..<60 {
            b.physics(dt: 1.0 / 60, world: world(.zero, [wall]))
            if b.catBody.vel.dx < 0 { bounced = true; break }
        }
        check(bounced && b.cat.position.x < 700, "a drawn wall bounces a thrown cat back")

        // 3. Drawing a line right through the cat knocks it away.
        var c = Playground(position: CGPoint(x: 500, y: 500))
        quiet(&c)
        c.drawingAdded(Drawing(id: -4, kind: .line, points: [CGPoint(x: 400, y: 495), CGPoint(x: 600, y: 495)],
                               closed: false, color: RGBA(r: 0, g: 0, b: 0)))
        check(c.mode == .flying && c.catBody.vel.dy > 1000, "drawing a line through the cat launches it")

        // 4. Toolbox mode is peaceful: an angry cat sits it off and never charges you.
        var d = Playground(position: CGPoint(x: 300, y: 300))
        quiet(&d)
        d.painted()
        check(d.catPose.angry, "painting the cat annoys it (💢)")
        for _ in 0..<40 { d.tick10(world: world(CGPoint(x: 900, y: 600))) }
        check(!d.catPose.angry && d.mode == .chasing, "...then it calms down and just follows you again")

        // 5. Petting an angry cat calms it straight away.
        var e = Playground(position: CGPoint(x: 300, y: 300))
        quiet(&e)
        e.painted()
        e.tick10(world: world(CGPoint(x: 300, y: 300)))
        let wasMad = e.catPose.angry
        e.mouseDown(on: .cat, at: e.cat.position, time: 0)
        e.mouseUp(at: e.cat.position, time: 0.05)
        check(wasMad && !e.catPose.angry, "petting a mad cat removes its 💢")

        // G. Toolbox gravity: Neko falls and walks along the ground to the cursor; it can't fly.
        func run(_ p: inout Playground, _ w: World, seconds: Double) {
            for i in 0..<Int(seconds * 60) {
                p.physics(dt: 1.0 / 60, world: w)
                if i % 6 == 0 { p.tick10(world: w) }
            }
        }
        var gw = Playground(position: CGPoint(x: 400, y: 600))
        quiet(&gw)
        gw.gravityMode = true
        gw.cat.speed = 10
        let high = world(CGPoint(x: 900, y: 700))
        run(&gw, high, seconds: 10)
        check(abs(gw.cat.position.x - 900) < 8 && abs(gw.cat.position.y - (60 + 13)) < 1,
              "gravity Neko walks along the floor under a cursor it can't reach (\(Int(gw.cat.position.x)), \(Int(gw.cat.position.y)))")
        check(!gw.needsPhysics, "...and stops using physics once it's waiting there")

        // Draw it a ramp and it walks up.
        let ramp = Drawing(id: -10, kind: .line, points: [CGPoint(x: 300, y: 50), CGPoint(x: 800, y: 350)],
                           closed: false, color: RGBA(r: 0, g: 0, b: 0))
        var gr = Playground(position: CGPoint(x: 150, y: 80))
        quiet(&gr)
        gr.gravityMode = true
        gr.cat.speed = 10
        run(&gr, world(CGPoint(x: 780, y: 420), [ramp]), seconds: 12)
        check(gr.cat.position.x > 700 && gr.cat.position.y > 300, "draw a ramp and it walks up it (\(Int(gr.cat.position.x)), \(Int(gr.cat.position.y)))")

        // Erase the ramp under it and it drops.
        gr.groundChanged()
        run(&gr, world(CGPoint(x: 780, y: 420)), seconds: 2)
        check(abs(gr.cat.position.y - (60 + 13)) < 1, "erase what it's standing on and it falls to the ground")

        // A steep line is a wall it can't walk through.
        let wall2 = Drawing(id: -11, kind: .line, points: [CGPoint(x: 600, y: 40), CGPoint(x: 600, y: 400)],
                            closed: false, color: RGBA(r: 0, g: 0, b: 0))
        var gx = Playground(position: CGPoint(x: 300, y: 73))
        quiet(&gx)
        gx.gravityMode = true
        gx.cat.speed = 10
        run(&gx, world(CGPoint(x: 1000, y: 100), [wall2]), seconds: 8)
        check(gx.cat.position.x < 600, "a drawn wall blocks it (x=\(Int(gx.cat.position.x)))")

        // 6. Eraser: rubbing fades the cat out; fully erased it scores big and respawns furious.
        var f = Playground(position: CGPoint(x: 600, y: 500))
        quiet(&f)
        var rubs = 0
        while rubs < 40 {
            if case .erased = f.mode { break }
            f.erase(at: f.cat.position, radius: 10)
            rubs += 1
        }
        check(f.catPose.opacity == 0, "rubbing it out with the Eraser fades it away (\(rubs) rubs)")
        for _ in 0..<25 { f.tick10(world: world(CGPoint(x: 700, y: 400))) }
        check(f.mode == .flying && f.catPose.opacity == 1, "...then it respawns from the top")

        // 7. Select around the cat captures it; drag moves it; deselect drops it.
        var g = Playground(position: CGPoint(x: 600, y: 500))
        quiet(&g)
        g.capture()
        g.moveCaptured(to: CGPoint(x: 700, y: 600))
        for _ in 0..<60 { g.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(g.mode == .captured && g.cat.position == CGPoint(x: 700, y: 600), "a selection grabs the cat and moves it")
        g.releaseCaptured()
        check(g.mode == .flying, "deselecting drops it")

        // 8. Magnifier: a giant cat grows from its feet.
        var h = Playground(position: CGPoint(x: 600, y: 300))
        quiet(&h)
        let feetBefore = h.cat.position.y - 13
        h.setCatSize(3)
        check(h.catScale == 3 && abs((h.cat.position.y - 39) - feetBefore) < 0.01, "the Magnifier makes it 3× bigger, feet planted")
    }
}

extension SelfTest {
    /// Touch Bar mode: the playground in a 1000 × 30 pt strip with a tall invisible sky.
    static func touchBarChecks(_ check: (Bool, String) -> Void) {
        let f = CGRect(x: 0, y: 0, width: 1000, height: 600)
        func bar(_ x: CGFloat) -> World { World(screens: [ScreenInfo(frame: f, visible: f)], windows: [], cursor: CGPoint(x: x, y: 13)) }
        func make() -> Playground {
            var p = Playground(position: CGPoint(x: 100, y: 13))
            p.cat.random = { _ in 1 }
            p.random = { _ in 1 }
            p.gravityMode = true
            p.spotWindows = false; p.spotMenuBar = false; p.spotDock = false
            p.throwLift = TouchBarCat.hopLift
            p.cat.speed = 6
            return p
        }
        func run(_ p: inout Playground, _ w: World, _ seconds: Double, until: ((Playground) -> Bool)? = nil) {
            for i in 0..<Int(seconds * 60) {
                p.physics(dt: 1.0 / 60, world: w)
                if i % 6 == 0 { p.tick10(world: w) }
                if let u = until, u(p) { return }
            }
        }

        // 1. It walks along the bar to where your cursor maps.
        var a = make()
        run(&a, bar(700), 12)
        check(abs(a.cat.position.x - 700) < 8 && abs(a.cat.position.y - 13) < 1, "on the Touch Bar it trots along to the cursor (\(Int(a.cat.position.x)))")

        // 2. A sideways flick hops it along the bar: it stays on the Touch Bar.
        var b = make()
        run(&b, bar(100), 1)
        b.mouseDown(on: .cat, at: CGPoint(x: 100, y: 13), time: 0)
        b.mouseDragged(to: CGPoint(x: 110, y: 13), time: 0.01)
        b.mouseUp(at: CGPoint(x: 150, y: 14), time: 0.05)          // ~1000 pt/s sideways
        var peak: CGFloat = 0, escaped = false
        run(&b, bar(100), 6) { p in
            peak = max(peak, p.cat.position.y)
            if TouchBarCat.isEscaping(p) { escaped = true }
            if case .dazed = p.mode { return true }
            return false
        }
        check(!TouchBarCat.goesToDesktop(b) && !escaped && peak < 60 && b.cat.position.x > 300,
              "a sideways flick hops it along the bar and it stays (peak \(Int(peak)) pt, slid to x=\(Int(b.cat.position.x)))")

        // 3. Fetch on the bar: flick the bone, it trots over, picks it up and brings it back.
        var c = make()
        c.placeBone(at: CGPoint(x: 400, y: 3.5), falling: false)
        c.mouseDown(on: .bone, at: CGPoint(x: 400, y: 3.5), time: 0)
        c.mouseDragged(to: CGPoint(x: 420, y: 5), time: 0.01)
        c.mouseUp(at: CGPoint(x: 480, y: 8), time: 0.05)
        var took = false, dropped = false
        for i in 0..<(60 * 40) where !dropped {
            c.physics(dt: 1.0 / 60, world: bar(100))
            if i % 6 == 0 { c.tick10(world: bar(100)) }
            for e in c.drainEvents() {
                if e == .boneTaken { took = true }
                if e == .boneDropped { dropped = true }
            }
        }
        check(took && dropped, "fetch works on the bar: it brings the bone back")
        check(abs(c.bone.body.pos.x - 100) < 60, "...to where you are (bone at x=\(Int(c.bone.body.pos.x)))")

        // 5. Stray off the visible ends and it's pulled back; toys too.
        var e = make()
        e.placeBox(at: CGPoint(x: 990, y: 15), falling: false)
        e.keepInside(0...700)
        check(e.box.body.pos.x <= 700 - 14, "a box past the visible end of the bar is pulled back")
        e.launch(at: CGPoint(x: 950, y: 13), velocity: .zero)
        run(&e, World(screens: [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 700, height: 600),
                                           visible: CGRect(x: 0, y: 0, width: 700, height: 600))],
                      windows: [], cursor: CGPoint(x: 650, y: 13)), 3)
        check(e.cat.position.x <= 700 - 13, "...and so is the cat (x=\(Int(e.cat.position.x)))")

        // 6. Only an upward flick, or a very hard one, sends it to the desktop.
        func flick(_ dx: CGFloat, _ dy: CGFloat) -> Playground {
            var p = make()
            run(&p, bar(100), 1)
            p.mouseDown(on: .cat, at: CGPoint(x: 100, y: 13), time: 0)
            p.mouseDragged(to: CGPoint(x: 100 + dx * 0.5, y: 13 + dy * 0.5), time: 0.025)
            p.mouseUp(at: CGPoint(x: 100 + dx, y: 13 + dy), time: 0.05)
            return p
        }
        check(TouchBarCat.goesToDesktop(flick(5, 12)), "an upward flick sends it to the desktop")
        check(TouchBarCat.goesToDesktop(flick(90, 0)), "...and so does a very hard sideways one (1800 pt/s)")
        check(!TouchBarCat.goesToDesktop(flick(60, 0)) && !TouchBarCat.goesToDesktop(flick(-60, 1)),
              "...but normal left/right flicks keep it on the bar")

        // 7. Arriving on the desktop: it flies up from where it left the bar.
        var desk = Playground(position: .zero)
        desk.cat.random = { _ in 1 }; desk.random = { _ in 1 }
        desk.launch(at: CGPoint(x: 500, y: 80), velocity: CGVector(dx: 100, dy: 1800))
        var top: CGFloat = 0
        let wd = World(screens: [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                            visible: CGRect(x: 0, y: 60, width: 1440, height: 815))], windows: [], cursor: .zero)
        for _ in 0..<240 { desk.physics(dt: 1.0 / 60, world: wd); top = max(top, desk.cat.position.y) }
        check(top > 600, "yeeted onto the desktop, it flies way up the screen (\(Int(top)) pt)")

        // 4. Left alone near the box, it walks over and climbs in for a nap.
        var d = make()
        d.placeBox(at: CGPoint(x: 300, y: 15), falling: false)
        d.random = { _ in 0 }
        run(&d, bar(260), 30) { $0.inBox }
        check(d.inBox, "idle near the box on the bar, it climbs in for a nap")
    }
}

extension SelfTest {
    /// Yarn, catnip, laser, waking up, events, painted coats, hats, stats.
    static func extrasChecks(_ check: (Bool, String) -> Void) {
        let scr = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 60, width: 1440, height: 815))
        func world(_ cursor: CGPoint) -> World { World(screens: [scr], windows: [], cursor: cursor) }
        func make(_ at: CGPoint) -> Playground {
            var p = Playground(position: at)
            p.cat.random = { _ in 1 }
            p.random = { _ in 1 }
            p.spotWindows = false; p.spotMenuBar = false; p.spotDock = false
            return p
        }

        // Yarn rolls along the floor, slowing down, then stops.
        var a = make(CGPoint(x: 1300, y: 800))
        a.placeYarn(at: CGPoint(x: 200, y: 66), falling: true)
        a.yarn.body.vel = CGVector(dx: 600, dy: 0)
        var rolled = false
        for _ in 0..<600 {
            a.physics(dt: 1.0 / 60, world: world(CGPoint(x: 1300, y: 800)))
            if a.yarn.state == .flying && abs(a.yarn.body.pos.y - 66) < 1 && a.yarn.body.pos.x > 300 { rolled = true }
        }
        check(rolled && a.yarn.isResting && a.yarn.body.pos.x > 350, "the yarn rolls along the floor and comes to a stop (x=\(Int(a.yarn.body.pos.x)))")

        // Walk next to a resting ball: it gets batted.
        var b = make(CGPoint(x: 500, y: 300))
        b.placeYarn(at: CGPoint(x: 505, y: 300), falling: false)
        b.tick10(world: world(CGPoint(x: 500, y: 300)))
        check(b.yarn.state == .flying && b.drainEvents().contains(.batYarn), "the cat bats a ball of yarn next to it")
        // ...and chases it while it rolls.
        for _ in 0..<3 { b.tick10(world: world(CGPoint(x: 500, y: 300))) }
        let chasing: Bool = { if case .chasingYarn = b.mode { return true }; return false }()
        check(chasing || b.yarn.isResting, "...and chases it while it's rolling (\(b.mode))")

        // Catnip: zoomies.
        var c = make(CGPoint(x: 600, y: 400))
        c.tick10(world: world(CGPoint(x: 600, y: 400)))
        c.giveCatnip()
        let start = c.cat.position
        var far: CGFloat = 0
        for _ in 0..<30 { c.tick10(world: world(CGPoint(x: 600, y: 400))); far = max(far, hypot(c.cat.position.x - start.x, c.cat.position.y - start.y)) }
        check({ if case .zoomies = c.mode { return true }; return false }() && far > 100, "catnip sets off the zoomies (\(Int(far)) pt of running)")

        // Laser pointer: it runs right onto the dot and pounces.
        var d = make(CGPoint(x: 200, y: 400))
        d.laser = true
        for _ in 0..<60 { d.tick10(world: world(CGPoint(x: 700, y: 500))) }
        check(d.cat.position == CGPoint(x: 700, y: 500) && d.cat.sprite == .scratchSelf, "with the laser pointer it catches the dot and pounces on it")

        // Back from being away: a big stretch, then up.
        var e = make(CGPoint(x: 600, y: 400))
        e.stretchAwake()
        let stretching: Bool = { if case .stretching = e.mode { return true }; return false }()
        check(stretching && e.drainEvents().contains(.woke), "when you're back it stretches awake")
        for _ in 0..<12 { e.tick10(world: world(CGPoint(x: 600, y: 400))) }
        check(e.mode == .chasing, "...then it's back to normal")

        // A yeet reports its throw, its peak and its landing (for sounds and stats).
        var f = make(CGPoint(x: 600, y: 300))
        f.mouseDown(on: .cat, at: CGPoint(x: 600, y: 300), time: 0)
        f.mouseDragged(to: CGPoint(x: 610, y: 320), time: 0.01)
        f.mouseUp(at: CGPoint(x: 640, y: 380), time: 0.05)
        var evs: [PlaygroundEvent] = f.drainEvents()
        for _ in 0..<300 { f.physics(dt: 1.0 / 60, world: world(.zero)); evs += f.drainEvents() }
        let thrown = evs.contains { if case .thrown = $0 { return true }; return false }
        let apex = evs.compactMap { e -> CGFloat? in if case .apex(let h) = e { return h }; return nil }.first ?? 0
        let landed = evs.contains { if case .landed = $0 { return true }; return false }
        check(thrown && apex > 50 && landed, "a yeet reports throw, peak (\(Int(apex)) pt) and landing")

        // Painted coats: the pattern shows up in the accent colour.
        guard let sheet = SpriteSheet.load() else { check(false, "sprite sheet loads"); return }
        let accent = RGBA(r: 255, g: 255, b: 255)
        let tabby = sheet.recolored(Skin(id: Skin.paintedID, title: "", outline: RGBA(r: 0, g: 0, b: 0),
                                         fill: RGBA(r: 245, g: 161, b: 66), accent: accent, pattern: .tabby))
        check(tabby !== sheet, "a painted coat makes a new sheet")
        check(CoatPattern.tabby.accent(x: 0, y: 5) && !CoatPattern.tabby.accent(x: 3, y: 5)
              && CoatPattern.socks.accent(x: 10, y: 28) && !CoatPattern.solid.accent(x: 10, y: 28),
              "coat patterns put the accent where they should")
        check(RGBA(hex: "F5A142") == RGBA(r: 245, g: 161, b: 66) && RGBA(r: 1, g: 2, b: 3).hex == "010203",
              "coat colours save and load as hex")

        // Hats sit on top of the head.
        let a1 = sheet.headAnchor(.idle, frame: 0)
        check(abs(a1.x - 16) < 2 && a1.y >= 3 && a1.y <= 5, "the hat anchor is the top of the sitting cat's head (\(a1))")

        // Stats.
        let suite = "local.oneko.selftest.stats"
        UserDefaults().removePersistentDomain(forName: suite)
        let st = Stats(defaults: UserDefaults(suiteName: suite)!)
        st.bump(.pets); st.bump(.pets); st.record(.highestYeet, max: 420); st.record(.highestYeet, max: 100)
        check(st[.pets] == 2 && st[.highestYeet] == 420 && st.line(.highestYeet) == "Highest yeet: 420 pt", "stats count and keep records")
        st.reset()
        check(st[.pets] == 0, "...and can be reset")
        UserDefaults().removePersistentDomain(forName: suite)

        // Dropping into the Touch Bar: thrown down hard onto the floor, judged on the first impact.
        var slam = make(CGPoint(x: 700, y: 500))
        slam.mouseDown(on: .cat, at: CGPoint(x: 700, y: 500), time: 0)
        slam.mouseDragged(to: CGPoint(x: 700, y: 480), time: 0.01)
        slam.mouseUp(at: CGPoint(x: 700, y: 440), time: 0.05)          // a hard downward flick
        var first: (CGFloat, Int?)?
        for _ in 0..<120 where first == nil {
            slam.physics(dt: 1.0 / 60, world: world(.zero))
            for e in slam.drainEvents() { if case .landed(let i, let w, _) = e, first == nil { first = (i, w) } }
        }
        check(first != nil && first!.1 == nil && AppDelegate.slamsIntoTouchBar(impact: first!.0, thrown: slam.lastThrow),
              "a hard downward throw onto the floor counts as a Touch Bar drop (first impact \(Int(first?.0 ?? 0)) pt/s)")
        var plop = make(CGPoint(x: 700, y: 800))
        plop.mouseDown(on: .cat, at: CGPoint(x: 700, y: 800), time: 0)
        plop.mouseDragged(to: CGPoint(x: 706, y: 800), time: 0.01)
        plop.mouseUp(at: CGPoint(x: 706, y: 800), time: 0.5)           // just let go from high up
        var firstPlop: CGFloat = 0
        for _ in 0..<240 where firstPlop == 0 {
            plop.physics(dt: 1.0 / 60, world: world(.zero))
            for e in plop.drainEvents() { if case .landed(let i, _, _) = e, firstPlop == 0 { firstPlop = i } }
        }
        check(!AppDelegate.slamsIntoTouchBar(impact: firstPlop, thrown: plop.lastThrow),
              "...but just dropping it from high up doesn't (\(Int(firstPlop)) pt/s, not thrown)")

        // The sounds are built in: every one synthesises and has a length.
        let lengths = SoundBox().durations()
        check(lengths.count == 5 && lengths.allSatisfy { $0 > 0.1 },
              "all five sounds are synthesised in the app (\(lengths.map { String(format: "%.2fs", $0) }.joined(separator: ", ")))")
    }
}
