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
        var wrolls = [0, 999, 1]  // start; no doze; choices = [scratchSelf, scratchWallE]
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
        // 0.6.5: sleepiness, the Dock, exploring, sizes per cat.
        let s3 = Settings(defaults: defaults)
        defaults.removeObject(forKey: "sleepiness"); defaults.removeObject(forKey: "catSizes")
        check(s3.sleepiness == .sometimes && s3.sleepiness.factor < 1, "cats sleep less than classic oneko by default (Now and Then)")
        check(s3.dockFloor == .top && s3.explores, "defaults: cats stand on top of the Dock, and explore on their own")
        s3.size = .medium
        s3.catSizes = [0, 3, 1] + Array(repeating: 2, count: 20)
        check(s3.size(ofCat: 0) == 2 && s3.size(ofCat: 1) == 3 && s3.size(ofCat: 2) == 1 && s3.size(ofCat: 9) == 2
              && s3.size(ofCat: 10) == 2 && s3.catSizes.count == Settings.maxSizedCats,
              "the first 10 cats can each have a size of their own; the rest use the Size setting")
        s3.size = .large
        check(s3.size(ofCat: 0) == 3 && s3.size(ofCat: 2) == 1 && s3.size(ofCat: 10) == 3, "...and keep it when the Size setting changes")
        UserDefaults().removePersistentDomain(forName: suite)

        check(Settings.Speed.zoomies.rawValue == 2 * 24, "zoomies is twice as fast as before (48 pt/tick)")

        playgroundChecks(check)
        toolboxChecks(check)
        touchBarChecks(check)
        extrasChecks(check)
        displayChecks(check)
        catCountChecks(check)
        boxChecks(check)
        sharedToyChecks(check)

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

        // O. 0.6.5: following your cursor into the Dock, it stands on top of the Dock and waits
        // there. It's never yeeted up out of it (that used to happen even with the bonk off).
        var o = Playground(position: CGPoint(x: 500, y: 90))
        quiet(&o)
        o.spotMenuBar = false; o.spotDock = false; o.spotWindows = false
        var docked = scr
        docked.dock = CGRect(x: 0, y: 0, width: 1440, height: 60)
        let wo = World(screens: [docked], windows: [], cursor: CGPoint(x: 500, y: 20))
        var oFlew = false
        for i in 0..<360 {
            o.physics(dt: 1.0 / 60, world: wo)
            if i % 6 == 0 { o.tick10(world: wo) }
            if o.mode == .flying { oFlew = true }
        }
        check(!oFlew && !o.drainEvents().contains(.dockYeet), "following your cursor into the Dock never yeets the cat")
        check(abs(o.cat.position.y - (60 + 16 - 3)) < 0.5, "...it waits on top of the Dock (y=\(Int(o.cat.position.y)))")
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
        // With the Dock bonk off, a Dock that appears under a resting cat lifts it instead.
        var lift = Playground(position: CGPoint(x: 500, y: 40))
        quiet(&lift)
        lift.dockBonk = false
        lift.mouseDown(on: .cat, at: lift.cat.position, time: 0)
        lift.mouseUp(at: lift.cat.position, time: 0.05, clickCount: 2)   // stay
        lift.tick10(world: World(screens: [scr], windows: [], cursor: .zero))
        lift.tick10(world: World(screens: [docked], windows: [], cursor: .zero))
        check(lift.mode != .flying && abs(lift.cat.position.y - 73) < 0.01, "Dock bonk off: a Dock appearing under a resting cat lifts it onto the Dock")
        // On (the default): an auto-hiding Dock popping up under it bonks it into the air.
        var bonk = Playground(position: CGPoint(x: 500, y: 40))
        quiet(&bonk)
        bonk.placeBone(at: CGPoint(x: 560, y: 13 + 3.5), falling: false)
        bonk.mouseDown(on: .cat, at: bonk.cat.position, time: 0)
        bonk.mouseUp(at: bonk.cat.position, time: 0.05, clickCount: 2)   // stay
        bonk.tick10(world: World(screens: [scr], windows: [], cursor: .zero))
        _ = bonk.drainEvents()
        bonk.tick10(world: World(screens: [docked], windows: [], cursor: .zero))
        check(bonk.mode == .flying && bonk.catBody.vel.dy > 1000 && bonk.drainEvents().contains(.dockBonk),
              "Dock bonk on: the Dock popping up under a cat bonks it up into the air")
        check(bonk.bone.state == .flying, "...and the toys sitting there too")
        // ...but not on the very first look at the Dock (just launched, Dock already up).
        var first = Playground(position: CGPoint(x: 500, y: 40))
        quiet(&first)
        first.mouseDown(on: .cat, at: first.cat.position, time: 0)
        first.mouseUp(at: first.cat.position, time: 0.05, clickCount: 2)
        first.tick10(world: World(screens: [docked], windows: [], cursor: .zero))
        check(first.mode != .flying, "...and never on the first tick after launch")
        // Bonk off: nothing launches it off the Dock. Not following a cursor along the Dock
        // and down into it, not the Dock popping up under it while it walks, not sitting
        // above a cursor that dips into the Dock.
        var calm = Playground(position: CGPoint(x: 200, y: 73))
        quiet(&calm)
        calm.dockBonk = false
        calm.spotMenuBar = false; calm.spotDock = false; calm.spotWindows = false
        var calmFlew = false
        let cursors = [CGPoint(x: 900, y: 30), CGPoint(x: 520, y: 120), CGPoint(x: 520, y: 30), CGPoint(x: 100, y: 5)]
        for i in 0..<1200 {
            let c = cursors[(i / 300) % cursors.count]
            let screen = (i / 50) % 2 == 0 ? docked : scr     // an auto-hiding Dock, in and out
            let w = World(screens: [screen], windows: [], cursor: c)
            calm.physics(dt: 1.0 / 60, world: w)
            if i % 6 == 0 { calm.tick10(world: w) }
            if calm.mode == .flying, calm.catBody.vel.dy > 0 { calmFlew = true }
        }
        let calmEvents = calm.drainEvents()
        check(!calmFlew && !calmEvents.contains(.dockYeet) && !calmEvents.contains(.dockBonk),
              "Dock bonk off: the Dock never launches the cat, whatever your cursor and the Dock do")

        // Dock on the ground: the Dock isn't there for the cats. It walks right down to a
        // cursor in front of the Dock and lands on the real bottom of the screen.
        var gnd = Playground(position: CGPoint(x: 500, y: 300))
        quiet(&gnd)
        gnd.spotMenuBar = false; gnd.spotDock = false; gnd.spotWindows = false
        let wg = World(screens: [docked], windows: [], cursor: CGPoint(x: 500, y: 20)).ignoringDock()
        check(wg.screens[0].dock == nil && wg.screens[0].visible.minY == 0, "Dock on the ground: the floor is the bottom of the screen")
        var gndFlew = false
        for _ in 0..<80 { gnd.tick10(world: wg); if gnd.mode == .flying { gndFlew = true } }
        check(!gndFlew && gnd.cat.position.y < 72, "...the cat walks down in front of the Dock (y=\(Int(gnd.cat.position.y)))")
        var gdrop = Playground(position: CGPoint(x: 500, y: 400))
        quiet(&gdrop)
        gdrop.launch(at: CGPoint(x: 500, y: 400), velocity: CGVector(dx: 0, dy: -100))
        for _ in 0..<600 { gdrop.physics(dt: 1.0 / 60, world: wg); if case .landing = gdrop.mode { break } }
        check(abs(gdrop.cat.position.y - 13) < 0.5, "...and a dropped cat lands on the real bottom (y=\(Int(gdrop.cat.position.y)))")
        // A slam still counts for the Touch Bar trip: it lands on the floor (no window) hard.
        var slam = Playground(position: CGPoint(x: 500, y: 600))
        quiet(&slam)
        slam.launch(at: CGPoint(x: 500, y: 600), velocity: CGVector(dx: 0, dy: -3000))
        var slamImpact: CGFloat = 0, slamWin: Int? = -1
        for _ in 0..<120 {
            slam.physics(dt: 1.0 / 60, world: wg)
            for e in slam.drainEvents() { if case .landed(let imp, let win, _) = e, slamImpact == 0 { slamImpact = imp; slamWin = win } }
        }
        check(slamWin == nil && slamImpact >= AppDelegate.touchBarDropImpact,
              "...and slamming it down still drops it into the Touch Bar (impact \(Int(slamImpact)))")

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
        check(!(q.chooseSpot(world(.zero))?.kind.isBox ?? false), "an empty closed box isn't a nap spot")

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
        // 0.6.5: twice as fast as before (6× a normal chase, it was 3×).
        var nip = make(CGPoint(x: 900, y: 600))
        nip.tick10(world: world(CGPoint(x: 900, y: 600)))
        nip.giveCatnip()
        let n0 = nip.cat.position
        nip.tick10(world: world(CGPoint(x: 900, y: 600)))
        let nipStep = hypot(nip.cat.position.x - n0.x, nip.cat.position.y - n0.y)
        check(Playground.catnipSpeed == 6 && abs(nipStep - 6 * nip.cat.speed) < 0.5,
              "catnip zoomies run twice as fast as before (\(Int(nipStep)) pt a tick)")

        // Dinner on demand: click a bowl and every cat comes to eat, hungry or not.
        var din = make(CGPoint(x: 900, y: 500))
        din.placeBowl(at: CGPoint(x: 400, y: 63.5), falling: false)
        din.toys.bowls[0].food = 2
        din.tick10(world: world(CGPoint(x: 900, y: 500)))
        check(!din.isHungry && din.mode == .chasing, "(a cat that isn't hungry)")
        din.mouseDown(on: .bowl, at: CGPoint(x: 400, y: 63.5), time: 0, index: 0)
        din.mouseUp(at: CGPoint(x: 400, y: 63.5), time: 0.05)
        check(din.drainEvents().contains(.dinnerBell) && din.toys.bowls[0].food == ToyPile.Bowl.full,
              "clicking a bowl fills it and rings the dinner bell")
        din.callToDinner()
        var ate = false, bubble = false
        for _ in 0..<200 where !ate {
            din.tick10(world: world(CGPoint(x: 900, y: 500)))
            bubble = bubble || din.catPose.eating
            ate = din.drainEvents().contains(.ate)
        }
        check(ate, "...and the cat comes and eats, even though it wasn't hungry")
        check(bubble && !din.catPose.eating, "a little fish bobs over a cat while it eats (and goes when it's done)")
        check(din.toys.bowls[0].finished && !din.usesBowl(0), "...and its bowl is done with, to be cleared away")
        var shift = make(CGPoint(x: 900, y: 500))
        for k in 0..<3 { shift.placeBowl(at: CGPoint(x: 300 + CGFloat(k) * 100, y: 63.5), falling: false, index: k) }
        shift.makeHungry()
        shift.tick10(world: world(CGPoint(x: 900, y: 500)))
        let headed: Int? = { if case .goingToBowl(let j) = shift.mode { return j }; return nil }()
        shift.bowlRemoved(0)
        let now: Int? = { if case .goingToBowl(let j) = shift.mode { return j }; return nil }()
        check(headed == 2 && now == 1, "...and a cat heading for a later bowl still heads for the same one")
        var sleeper = make(CGPoint(x: 900, y: 500))
        sleeper.placeBowl(at: CGPoint(x: 400, y: 63.5), falling: false)
        sleeper.mouseDown(on: .cat, at: sleeper.cat.position, time: 0)
        sleeper.mouseUp(at: sleeper.cat.position, time: 0.05, clickCount: 2)   // stay
        sleeper.callToDinner()
        sleeper.tick10(world: world(CGPoint(x: 900, y: 500)))
        check({ if case .goingToBowl = sleeper.mode { return true }; return false }(), "...a cat dozing in place gets up for dinner too")

        // Sleepiness: the same idle moment ends in a doze for a sleepy cat, not a wide-awake one.
        func dozes(_ k: CGFloat) -> Bool {
            var b = NekoBrain(position: CGPoint(x: 600, y: 400))
            b.sleepiness = k
            b.random = { n in n == 1000 ? 200 : 0 }
            var seen = false
            for _ in 0..<20 { b.tick(cursor: CGPoint(x: 600, y: 400), screens: [scr.frame]); seen = seen || b.sprite == .tired }
            return seen
        }
        check(dozes(1) && dozes(2) && !dozes(0.25), "sleepiness: a sleepier cat dozes off more readily")
        var nap1 = make(CGPoint(x: 600, y: 400)), nap2 = make(CGPoint(x: 600, y: 400))
        nap1.sleepiness = 0.25; nap2.sleepiness = 2
        check(nap1.cat.sleepiness == 0.25 && nap2.cat.sleepiness == 2, "...set on the cat's brain too")

        // Exploring: left alone, it climbs up the side of a window, strolls along its title
        // bar, and naps up there.
        func explorer(_ at: CGPoint) -> Playground {
            var p = make(at)
            p.random = { _ in 0 }        // every whim, at once
            p.explores = true
            return p
        }
        let win = WindowInfo(id: 7, pid: 1, frame: CGRect(x: 300, y: 200, width: 600, height: 400))
        let still = CGPoint(x: 200, y: 300)
        let ww = World(screens: [scr], windows: [win], cursor: still)
        var ex = explorer(still)
        var climbed = false, strolled = false, napped = false
        for _ in 0..<400 {
            ex.tick10(world: ww)
            if case .exploring(let o) = ex.mode {
                if o.stage == .climb, ex.cat.sprite == .scratchWallE, abs(ex.cat.position.x - 287) < 0.5 { climbed = true }
                if o.stage == .stroll, abs(ex.cat.position.y - 613) < 0.5,
                   ex.cat.position.x >= 300, ex.cat.position.x <= 900 { strolled = true }
            }
            if case .napping(let spot, _) = ex.mode, spot.kind == .window(7) { napped = true; break }
        }
        check(climbed, "exploring: it climbs up the side of a window, paws on the edge")
        check(strolled, "...strolls along the window's title bar")
        check(napped, "...and naps up there")
        // Move the mouse and it comes running.
        var ex2 = explorer(still)
        for _ in 0..<60 { ex2.tick10(world: ww) }
        let wasOut: Bool = { if case .exploring = ex2.mode { return true }; return false }()
        ex2.tick10(world: World(screens: [scr], windows: [win], cursor: CGPoint(x: 1200, y: 700)))
        let back: Bool = { switch ex2.mode { case .chasing, .flying: return true; default: return false } }()
        check(wasOut && back, "...and drops it to come running when you move the mouse")
        // No windows: a stroll along the menu bar.
        var mbx = explorer(CGPoint(x: 700, y: 400))
        var onMenuBar = false
        for _ in 0..<300 where !onMenuBar {
            mbx.tick10(world: World(screens: [scr], windows: [], cursor: CGPoint(x: 700, y: 400)))
            if case .exploring(let o) = mbx.mode, o.place == .menuBar, o.stage == .stroll,
               abs(mbx.cat.position.y - 887) < 0.5 { onMenuBar = true }
        }
        check(onMenuBar, "exploring: it walks along the menu bar")
        // Scratching post: it scratches the window's edge before it climbs.
        var scr1 = explorer(still)
        scr1.scratchesWindows = true
        var scratchedEdge = false, scratchPose = false
        for _ in 0..<300 where !scratchedEdge {
            scr1.tick10(world: ww)
            if case .exploring(let o) = scr1.mode, o.stage == .scratch, scr1.cat.sprite == .scratchWallE { scratchPose = true }
            scratchedEdge = scr1.drainEvents().contains(.scratched)
        }
        check(scratchPose && scratchedEdge, "exploring: it gives a window's edge a good scratch (with Scratches Windows on)")
        // Round the inside of a window's border: along the bottom edge, a scratch in the
        // corner, up the side and along under the title bar.
        let tall = WindowInfo(id: 9, pid: 1, frame: CGRect(x: 200, y: 100, width: 800, height: 760))
        let wt = World(screens: [scr], windows: [tall], cursor: CGPoint(x: 600, y: 400))
        var inn = make(CGPoint(x: 600, y: 400))
        inn.explores = true
        inn.scratchesWindows = true
        inn.random = { n in n == 300 || n == 3 ? 0 : min(1, n - 1) }
        var bottom = false, side = false, top = false, cornerScratch = false, wentInside = false
        for _ in 0..<3000 {
            inn.tick10(world: wt)
            if case .exploring(let o) = inn.mode, o.place == .inside(9) {
                wentInside = true
                let p = inn.cat.position
                if o.stage == .stroll, abs(p.y - 113) < 0.5, p.x > 212, p.x < 988 { bottom = true }
                if abs(p.x - 213) < 0.5 || abs(p.x - 987) < 0.5, p.y > 200, p.y < 800,
                   [.scratchWallW, .scratchWallE].contains(inn.cat.sprite) { side = true }
                if abs(p.y - (860 - 28 - 16)) < 0.5 { top = true }
            }
            if inn.drainEvents().contains(.scratched) { cornerScratch = true }
            if top && cornerScratch { break }
        }
        check(wentInside && bottom, "exploring: it walks along the inside of a window's bottom edge")
        check(cornerScratch, "...scratches the corner")
        check(side && top, "...and climbs up the inside of the border and along under the title bar")
        // Sleepiness decides what it does up there: a wide-awake cat runs about on the menu
        // bar, a very sleepy one curls up for a nap.
        func menuBarDay(_ k: CGFloat) -> (napped: Bool, ran: CGFloat) {
            var c = make(CGPoint(x: 700, y: 400))
            c.explores = true
            c.sleepiness = k
            c.random = { n in n == 100 ? 50 : 0 }   // a middling roll for every "nap or not?"
            var ran: CGFloat = 0, last: CGPoint?
            for _ in 0..<1500 {
                c.tick10(world: World(screens: [scr], windows: [], cursor: CGPoint(x: 700, y: 400)))
                if case .exploring(let o) = c.mode, o.place == .menuBar, o.stage == .stroll {
                    if let l = last { ran += abs(c.cat.position.x - l.x) }
                    last = c.cat.position
                } else { last = nil }
                if case .napping(let spot, _) = c.mode, spot.kind == .menuBar { return (true, ran) }
            }
            return (false, ran)
        }
        let awake = menuBarDay(0.25), drowsy = menuBarDay(2)
        check(!awake.napped && awake.ran > 400, "sleepiness Rarely: it runs around the menu bar instead of napping (\(Int(awake.ran)) pt)")
        check(drowsy.napped, "...Very Sleepy: it naps up there")
        func headsUp(_ k: CGFloat) -> CatMode {
            var c = make(CGPoint(x: 700, y: 400))
            c.explores = true
            c.spotMenuBar = true
            c.sleepiness = k
            c.random = { n in n == 100 ? 50 : 0 }
            for _ in 0..<60 {
                c.tick10(world: World(screens: [scr], windows: [], cursor: CGPoint(x: 700, y: 400)))
                if c.mode != .chasing { break }
            }
            return c.mode
        }
        check({ if case .exploring = headsUp(0.25) { return true }; return false }()
              && { if case .goingToSpot = headsUp(2) { return true }; return false }(),
              "...off to the menu bar: a wide-awake cat goes up to run about, a sleepy one to nap")
        // Not sleepy: parked (or told to stay) it sits there awake. Sleepy: it dozes off.
        func parked(_ k: CGFloat) -> Playground {
            var c = make(CGPoint(x: 600, y: 400))
            c.sleepiness = k
            c.mouseDown(on: .cat, at: c.cat.position, time: 0)
            c.mouseUp(at: c.cat.position, time: 0.05, clickCount: 2)   // stay
            for _ in 0..<200 { c.tick10(world: world(CGPoint(x: 600, y: 400))) }
            return c
        }
        let awakeP = parked(0.5), sleepyP = parked(2)
        check(awakeP.isStaying && !awakeP.isSleeping && awakeP.cat.sprite != .sleeping && awakeP.cat.sprite != .tired,
              "Now and Then: a parked cat sits there awake (\(awakeP.cat.sprite))")
        check(sleepyP.isStaying && sleepyP.isSleeping && sleepyP.cat.sprite == .sleeping, "...Very Sleepy: it dozes off")
        // Put it inside a window: let go gently over a window and it drops onto the window's
        // inside bottom edge, stays there (riding the window), and, not sleepy, runs up and down it.
        let box1 = WindowInfo(id: 11, pid: 1, frame: CGRect(x: 300, y: 200, width: 600, height: 400))
        func inWin(_ f: CGRect) -> World { World(screens: [scr], windows: [WindowInfo(id: 11, pid: 1, frame: f)], cursor: CGPoint(x: 1300, y: 800)) }
        var drop = make(CGPoint(x: 500, y: 450))
        drop.sleepiness = 0.5
        drop.updateWindows(inWin(box1.frame), dt: 0.1)
        drop.mouseDown(on: .cat, at: CGPoint(x: 500, y: 450), time: 0)
        drop.mouseDragged(to: CGPoint(x: 510, y: 450), time: 0.01)
        drop.mouseUp(at: CGPoint(x: 510, y: 450), time: 0.5)
        for i in 0..<300 {
            drop.physics(dt: 1.0 / 60, world: inWin(box1.frame))
            if i % 6 == 0 { drop.tick10(world: inWin(box1.frame)) }
        }
        for _ in 0..<20 { drop.tick10(world: inWin(box1.frame)) }
        check(drop.isStaying && abs(drop.cat.position.y - 213) < 1,
              "let go over a window, it drops in and lands on the window's inside bottom edge (y=\(Int(drop.cat.position.y)), \(drop.mode))")
        var xs: [CGFloat] = []
        for _ in 0..<150 { drop.tick10(world: inWin(box1.frame)); xs.append(drop.cat.position.x) }
        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
        check(drop.isStaying && spread > 150 && xs.allSatisfy { $0 >= 313 - 0.01 && $0 <= 887 + 0.01 }
              && abs(drop.cat.position.y - 213) < 1,
              "...and, not sleepy, runs up and down in there (\(Int(spread)) pt, never past the sides)")
        let moved = box1.frame.offsetBy(dx: 40, dy: 60)
        drop.updateWindows(inWin(moved), dt: 0.1)
        drop.tick10(world: inWin(moved))
        check(abs(drop.cat.position.y - 273) < 1, "...riding along when you move the window (y=\(Int(drop.cat.position.y)))")
        let grown = CGRect(x: moved.minX, y: moved.minY - 100, width: moved.width, height: moved.height + 100)
        drop.updateWindows(inWin(grown), dt: 0.1)
        drop.tick10(world: inWin(grown))
        check(abs(drop.cat.position.y - 173) < 1, "...and staying on the bottom edge when you resize it (y=\(Int(drop.cat.position.y)))")
        // Thrown hard down through a window, it doesn't stop there (slams still reach the Touch Bar).
        var hard = make(CGPoint(x: 500, y: 500))
        hard.updateWindows(inWin(box1.frame), dt: 0.1)
        hard.mouseDown(on: .cat, at: CGPoint(x: 500, y: 500), time: 0)
        for k in 1...5 { hard.mouseDragged(to: CGPoint(x: 500, y: 500 - CGFloat(k) * 30), time: Double(k) * 0.01) }
        hard.mouseUp(at: CGPoint(x: 500, y: 330), time: 0.06)
        var firstHit: CGPoint?
        for _ in 0..<300 where firstHit == nil {
            hard.physics(dt: 1.0 / 60, world: inWin(box1.frame))
            for e in hard.drainEvents() { if case .landed(_, _, let at) = e, firstHit == nil { firstHit = at } }
        }
        check((firstHit?.y ?? 999) < 150, "...but thrown down hard, it goes straight through to the floor (hit at y=\(Int(firstHit?.y ?? -1)))")
        // Parked on a window's title bar, the menu bar or the Dock: the same.
        var tbar = make(CGPoint(x: 500, y: 700))
        tbar.sleepiness = 0.25
        tbar.updateWindows(inWin(box1.frame), dt: 0.1)
        tbar.mouseDown(on: .cat, at: CGPoint(x: 500, y: 700), time: 0)
        tbar.mouseDragged(to: CGPoint(x: 510, y: 700), time: 0.01)
        tbar.mouseUp(at: CGPoint(x: 510, y: 700), time: 0.5)
        for i in 0..<300 {
            tbar.physics(dt: 1.0 / 60, world: inWin(box1.frame))
            if i % 6 == 0 { tbar.tick10(world: inWin(box1.frame)) }
        }
        var txs: [CGFloat] = []
        for _ in 0..<150 { tbar.tick10(world: inWin(box1.frame)); txs.append(tbar.cat.position.x) }
        check(tbar.isStaying && abs(tbar.cat.position.y - 613) < 1 && (txs.max()! - txs.min()!) > 150,
              "put on a window's title bar, a wide-awake cat runs up and down it")
        // Cats bump into each other.
        var grid: [CGPoint] = []
        var seed: UInt64 = 7
        for _ in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            grid.append(CGPoint(x: CGFloat(seed >> 40 & 1023), y: CGFloat(seed >> 20 & 511)))
        }
        var brute = 0
        for i in grid.indices { for j in grid.indices where j > i && hypot(grid[i].x - grid[j].x, grid[i].y - grid[j].y) < 25 { brute += 1 } }
        check(CatCollisions.overlaps(grid, skip: grid.map { _ in false }, reach: 25).count == brute,
              "finding cats that touch: the grid finds exactly the pairs a full search does (\(brute))")
        var duo = [make(CGPoint(x: 600, y: 400)), make(CGPoint(x: 604, y: 400))]
        for k in duo.indices { duo[k].tick10(world: world(duo[k].cat.position)) }
        CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil) { k, f in f(&duo[k]) }
        let apart = hypot(duo[0].cat.position.x - duo[1].cat.position.x, duo[0].cat.position.y - duo[1].cat.position.y)
        check(apart >= 2 * duo[0].bumpRadius - 0.01 && duo[0].cat.position.x < 600 && duo[1].cat.position.x > 604,
              "two cats that walk into each other are pushed apart, half each (\(Int(apart)) pt)")
        var stay2 = [make(CGPoint(x: 600, y: 73)), make(CGPoint(x: 610, y: 80))]
        for k in stay2.indices {
            stay2[k].mouseDown(on: .cat, at: stay2[k].cat.position, time: 0)
            stay2[k].mouseUp(at: stay2[k].cat.position, time: 0.05, clickCount: 2)
            stay2[k].tick10(world: world(.zero))
        }
        CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil) { k, f in f(&stay2[k]) }
        check(stay2[0].cat.position.y == 73 && stay2[1].cat.position.y == 80 && stay2[1].cat.position.x - stay2[0].cat.position.x > 10,
              "...only sideways for cats sitting on something (they stay on it)")
        var clipped = [make(CGPoint(x: 600, y: 400)), make(CGPoint(x: 604, y: 400))]
        clipped[1].rightClick(.cat)
        CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil) { k, f in f(&clipped[k]) }
        check(clipped[0].cat.position.x == 600 && clipped[1].cat.position.x == 604, "...and a clipped (or napping, or boxed) cat isn't bumped")
        // Throw a cat at another: it knocks it flying.
        var pins = [make(CGPoint(x: 400, y: 400)), make(CGPoint(x: 520, y: 400))]
        pins[1].tick10(world: world(CGPoint(x: 520, y: 400)))
        pins[0].launch(at: CGPoint(x: 400, y: 400), velocity: CGVector(dx: 1800, dy: 200))
        var hitPin: [Int] = [], thrownBefore: CGFloat = 0
        for _ in 0..<40 where hitPin.isEmpty {
            thrownBefore = pins[0].catBody.vel.dx
            pins[0].physics(dt: 1.0 / 60, world: world(.zero))
            hitPin = CatCollisions.bump(flyers: [0], count: 2, skipFirst: false) { k, f in f(&pins[k]) }
        }
        check(hitPin == [1] && pins[1].mode == .flying && pins[1].catBody.vel.dx > 300 && pins[1].catBody.vel.dy > 0
              && pins[1].drainEvents().contains(.catBump),
              "a cat thrown into another knocks it flying (\(Int(pins[1].catBody.vel.dx)), \(Int(pins[1].catBody.vel.dy)))")
        check(pins[0].catBody.vel.dx < thrownBefore * 0.6, "...and loses speed doing it (\(Int(thrownBefore)) -> \(Int(pins[0].catBody.vel.dx)), \(pins[0].mode))")
        // Even a full-speed yeet doesn't fly straight through a cat between two frames.
        var bullet = [make(CGPoint(x: 300, y: 400)), make(CGPoint(x: 560, y: 400))]
        bullet[1].tick10(world: world(CGPoint(x: 560, y: 400)))
        bullet[0].launch(at: CGPoint(x: 300, y: 400), velocity: CGVector(dx: 6500, dy: 0))
        var shot = false
        for _ in 0..<20 where !shot {
            bullet[0].physics(dt: 1.0 / 60, world: world(.zero))
            shot = !CatCollisions.bump(flyers: [0], count: 2, skipFirst: false) { k, f in f(&bullet[k]) }.isEmpty
        }
        check(shot && bullet[1].mode == .flying, "...even thrown at full speed (it can't fly straight through)")
        // Bumping levels (Settings › Cats › Bumping).
        func knockSpeed(_ style: CatCollisions.Style, throwSpeed: CGFloat = 1800, gap: CGFloat = 120) -> CGFloat? {
            var c = [make(CGPoint(x: 400, y: 400)), make(CGPoint(x: 400 + gap, y: 400))]
            c[1].tick10(world: world(CGPoint(x: 400 + gap, y: 400)))
            c[0].launch(at: CGPoint(x: 400, y: 400), velocity: CGVector(dx: throwSpeed, dy: 100))
            for _ in 0..<60 {
                c[0].physics(dt: 1.0 / 60, world: world(.zero))
                if !CatCollisions.bump(flyers: [0], count: 2, skipFirst: false, style: style) { k, f in f(&c[k]) }.isEmpty {
                    return hypot(c[1].catBody.vel.dx, c[1].catBody.vel.dy)
                }
            }
            return nil
        }
        let normalHit = knockSpeed(.normal) ?? 0, crazyHit = knockSpeed(.crazy) ?? 0, chaosHit = knockSpeed(.chaos) ?? 0
        check(crazyHit > normalHit * 1.5 && chaosHit > crazyHit,
              "bumping Crazy and Total Chaos knock cats much harder (\(Int(normalHit)) → \(Int(crazyHit)) → \(Int(chaosHit)) pt/s)")
        check(knockSpeed(.off) == nil, "...Off: a thrown cat flies straight through the others")
        check(knockSpeed(.gentle, throwSpeed: 450, gap: 50) == nil && knockSpeed(.normal, throwSpeed: 450, gap: 50) != nil,
              "...Gentle: only a proper throw knocks a cat over")
        var ghosts = [make(CGPoint(x: 600, y: 400)), make(CGPoint(x: 604, y: 400))]
        CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil, style: .off) { k, f in f(&ghosts[k]) }
        check(ghosts[0].cat.position.x == 600 && ghosts[1].cat.position.x == 604, "...and cats walk through each other")
        var pinball = [make(CGPoint(x: 600, y: 400)), make(CGPoint(x: 606, y: 400))]
        let launchedPair = CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil, style: .chaos,
                                                  roll: { _ in 0 }) { k, f in f(&pinball[k]) }
        check(launchedPair.count == 2 && pinball.allSatisfy { $0.mode == .flying && $0.catBody.vel.dy > 500 }
              && pinball[0].catBody.vel.dx < 0 && pinball[1].catBody.vel.dx > 0,
              "...Total Chaos: two cats running into each other launch each other like pinballs")
        var calmPair = [make(CGPoint(x: 600, y: 400)), make(CGPoint(x: 606, y: 400))]
        let none = CatCollisions.separate(count: 2, skipFirst: false, swarmSpacing: nil, style: .crazy,
                                          roll: { _ in 0 }) { k, f in f(&calmPair[k]) }
        check(none.isEmpty && calmPair.allSatisfy { $0.mode != .flying }, "...(Crazy just pushes them apart)")
        // Two flying cats bounce off each other.
        var air = [make(CGPoint(x: 500, y: 500)), make(CGPoint(x: 518, y: 500))]
        air[0].launch(at: CGPoint(x: 500, y: 500), velocity: CGVector(dx: 900, dy: 0))
        air[1].launch(at: CGPoint(x: 518, y: 500), velocity: CGVector(dx: -900, dy: 0))
        _ = CatCollisions.bump(flyers: [0, 1], count: 2, skipFirst: false) { k, f in f(&air[k]) }
        check(air[0].catBody.vel.dx < 0 && air[1].catBody.vel.dx > 0, "two flying cats bounce off each other")
        var odds = make(.zero)
        let chances: [CGFloat] = [0.25, 0.5, 1, 2].map { odds.sleepiness = $0; return odds.outingNapChance }
        check(zip(chances, chances.dropFirst()).allSatisfy { $0 < $1 } && chances[0] < 0.05 && chances[3] > 0.8,
              "...and the sleepier, the likelier a nap up there (\(chances.map { Int($0 * 100) }) %)")
        // Off by default in the engine (the app turns it on from Settings).
        var tame = make(still)
        tame.random = { _ in 0 }
        for _ in 0..<200 { tame.tick10(world: ww) }
        check({ if case .exploring = tame.mode { return false }; return true }(), "...and never explores with it turned off")

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
        // Every pattern but Solid marks part of the sitting cat, and never the outline or the "Z z".
        let idle = SpriteName.idle.cell(at: 0)
        func accentPixels(_ p: CoatPattern) -> Int {
            let s = sheet.recolored(Skin(id: "t", title: "", outline: RGBA(r: 0, g: 0, b: 0), fill: RGBA(r: 245, g: 161, b: 66),
                                         accent: RGBA(r: 0, g: 0, b: 255), pattern: p, accent2: RGBA(r: 0, g: 0, b: 255)))
            var n = 0
            for y in 0..<32 { for x in 0..<32 {
                let i = ((idle.row * 32 + y) * 256 + idle.col * 32 + x) * 4
                if s.rgbaPixels[i + 2] == 255 && s.rgbaPixels[i] == 0 { n += 1 }
            } }
            return n
        }
        let counts = CoatPattern.allCases.map(accentPixels)
        check(counts[0] == 0 && counts.dropFirst().allSatisfy { $0 > 0 },
              "every coat pattern marks the cat (\(counts.map(String.init).joined(separator: " ")))")
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
        check(lengths.count == 6 && lengths.allSatisfy { $0 > 0.1 },
              "all six sounds load (\(lengths.map { String(format: "%.2fs", $0) }.joined(separator: ", ")))")
        check(SoundBox.recordedMeow != nil && abs(lengths[1] - 0.8) < 0.05,
              "the meow is the recording in the app bundle (meow.m4a, \(String(format: "%.2fs", lengths[1])))")
    }
}

extension SelfTest {
    /// Shared cardboard boxes: any cat, any box, up to a million.
    static func boxChecks(_ check: (Bool, String) -> Void) {
        let scr = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 60, width: 1440, height: 815))
        func world(_ cursor: CGPoint) -> World { World(screens: [scr], windows: [], cursor: cursor) }
        func cat(_ id: Int, at p: CGPoint, pile: ToyPile) -> Playground {
            var c = Playground(position: p)
            c.cat.random = { _ in 1 }; c.random = { _ in 0 }
            c.spotWindows = false; c.spotMenuBar = false; c.spotDock = false
            c.toys = pile
            c.catID = id
            c.ownsToys = id == 0
            return c
        }

        // Two cats, two boxes: each naps in its own, and the second never squeezes into the first's.
        let pile = ToyPile()
        var a = cat(0, at: CGPoint(x: 300, y: 300), pile: pile)
        var b = cat(1, at: CGPoint(x: 900, y: 300), pile: pile)
        a.placeBox(at: CGPoint(x: 400, y: 75), falling: false, index: 0)
        a.placeBox(at: CGPoint(x: 1000, y: 75), falling: false, index: 1)
        for _ in 0..<400 where !(a.inBox && b.inBox) {
            a.tick10(world: world(CGPoint(x: 300, y: 300)))
            b.tick10(world: world(CGPoint(x: 900, y: 300)))
        }
        check(a.inBox && b.inBox && a.boxIndex != b.boxIndex, "two cats nap in two boxes, one each (\(String(describing: a.boxIndex)), \(String(describing: b.boxIndex)))")
        check(pile.boxes.allSatisfy { $0.napper != nil }, "...and the pile knows who's in which")

        // One box, two cats: the second cat to want it doesn't get in.
        let one = ToyPile()
        var c = cat(0, at: CGPoint(x: 300, y: 75), pile: one)
        var d = cat(1, at: CGPoint(x: 300, y: 75), pile: one)
        c.placeBox(at: CGPoint(x: 300, y: 75), falling: false)
        for _ in 0..<400 where !c.inBox { c.tick10(world: world(CGPoint(x: 300, y: 75))) }
        for _ in 0..<400 { d.tick10(world: world(CGPoint(x: 300, y: 75))) }
        check(c.inBox && !d.inBox, "a box with a cat in it is taken: the other cat finds somewhere else")
        check(d.chooseSpot(world(.zero)).map { !$0.kind.isBox } ?? true, "...it isn't even a nap spot for it")
        // The extra (not the box owner) dropped over a free box lands in it.
        let drop = ToyPile()
        var owner = cat(0, at: CGPoint(x: 100, y: 500), pile: drop)
        var extra = cat(5, at: CGPoint(x: 700, y: 400), pile: drop)
        owner.placeBox(at: CGPoint(x: 700, y: 75), falling: false)
        extra.mouseDown(on: .cat, at: CGPoint(x: 700, y: 400), time: 0)
        extra.mouseDragged(to: CGPoint(x: 700, y: 406), time: 0.01)
        extra.mouseUp(at: CGPoint(x: 700, y: 406), time: 0.5)
        for _ in 0..<240 where !extra.inBox { extra.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(extra.inBox && drop.boxes[0].napper == 5, "any cat dropped over a box lands in it, not just the first")
        // Carrying the box carries whichever cat is inside.
        owner.mouseDown(on: .box, at: CGPoint(x: 700, y: 75), time: 1)
        owner.mouseDragged(to: CGPoint(x: 800, y: 300), time: 1.05)
        extra.physics(dt: 1.0 / 60, world: world(.zero))
        check(extra.needsPhysics && extra.cat.position == drop.boxes[0].prop.body.pos, "...and carrying that box carries it along")
        owner.mouseUp(at: CGPoint(x: 800, y: 300), time: 1.5)
        // Shutting it from the box (the owner's side) and opening it again lets the cat out.
        extra.mouseUp(at: .zero, time: 2)
        for _ in 0..<240 { owner.physics(dt: 1.0 / 60, world: world(.zero)); extra.physics(dt: 1.0 / 60, world: world(.zero)) }
        owner.rightClick(.box, index: 0)
        for _ in 0..<1300 where extra.catPose.rattle == 0 { extra.tick10(world: world(.zero)) }
        check(extra.inBox && extra.catPose.boxClosed && extra.catPose.rattle != 0, "shut a box with any cat inside: it rattles to get out")
        owner.rightClick(.box, index: 0)
        extra.tick10(world: world(.zero))
        check(!extra.inBox && extra.mode == .flying, "...and pops out when you open it")
        // Fewer boxes: a cat napping in one that's gone wakes up.
        let few = ToyPile()
        var e = cat(0, at: CGPoint(x: 300, y: 75), pile: few)
        var f = cat(1, at: CGPoint(x: 900, y: 75), pile: few)
        e.placeBox(at: CGPoint(x: 300, y: 75), falling: false, index: 0)
        e.placeBox(at: CGPoint(x: 900, y: 75), falling: false, index: 1)
        for _ in 0..<400 where !e.inBox { e.tick10(world: world(CGPoint(x: 300, y: 75))) }
        for _ in 0..<400 where !f.inBox { f.tick10(world: world(CGPoint(x: 900, y: 75))) }
        check(f.boxIndex == 1, "with the first box taken, the next cat naps in the other one")
        e.removeBoxes(keeping: 1)
        f.tick10(world: world(CGPoint(x: 900, y: 75)))
        check(few.boxes.count == 1 && !f.inBox, "taking boxes away wakes the cats napping in them")

        // The heap: past 50, boxes pile up in the corner, drawn by the GPU.
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let small = BoxHeap.layout(count: 10, screens: [screens[0]], scale: 1)
        check(small.count == 10 && small.allSatisfy { $0.x > 1100 && $0.y < 130 }, "a small heap sits in the bottom-right corner")
        check(Set(small.map { "\($0.x),\($0.y)" }).count == 10, "...with no two boxes in the same spot")
        let big = BoxHeap.layout(count: 1_000_000, screens: screens, scale: 2)
        let inside = big.allSatisfy { p in screens.contains { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) } }
        check(big.count == 1_000_000 && inside, "a million boxes fit, every one on a display")
        check(big.map(\.y).max()! < 1080 * 0.75, "...piled no higher than about half the display")
        let heapFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        if let px = BoxHeap().snapshot(BoxHeap.layout(count: 200, screens: [heapFrame], scale: 1), scale: 1, frame: heapFrame) {
            // Rows top-first: the heap is in the bottom-right, so paint is there and not top-left.
            func painted(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
                var n = 0
                for y in y0..<y1 { for x in x0..<x1 where px[(y * 1440 + x) * 4 + 3] > 0 { n += 1 } }
                return n
            }
            let corner = painted(1000, 600, 1440, 900), elsewhere = painted(0, 0, 700, 500)
            check(corner > 20_000 && elsewhere == 0, "the heap's GPU code draws it in the bottom-right corner (\(corner) px)")
        } else {
            check(false, "the box heap's GPU code compiles")
        }
        var g = cat(0, at: CGPoint(x: 1300, y: 300), pile: ToyPile())
        g.toys.heap = BoxHeap.layout(count: 30, screens: [screens[0]], scale: 1)
        var heapNap = false
        for _ in 0..<2000 where !heapNap { g.tick10(world: world(CGPoint(x: 1300, y: 300))); heapNap = g.heapIndex != nil }
        check(heapNap && g.catPose.inBox, "a cat naps in a box on the heap, too")
        g.toys.heap = []
        g.tick10(world: world(.zero))
        check(!g.inBox, "...and wakes when the heap is put away")

        // Settings: a count up to a million; old single-box settings carry over.
        let suite = "local.oneko.selftest.boxes"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "boxOut")
        defaults.set(120.0, forKey: "boxX"); defaults.set(80.0, forKey: "boxY")
        let s = Settings(defaults: defaults)
        check(s.boxCount == 1 && s.boxPositions == [CGPoint(x: 120, y: 80)], "an old box (0.5.5) carries over as 1 box, where it was")
        check(s.dockBonk, "the Dock bonk is on by default")
        s.boxCount = 5_000_000
        check(s.boxCount == 1_000_000 && s.realBoxCount == 50 && s.heapBoxCount == 999_950, "boxes go up to 1,000,000: 50 real, the rest the heap")
        s.boxCount = 0
        check(!s.boxOut && s.lastBoxCount == 1_000_000, "turning boxes off remembers how many there were")
        // What's New: once per update, never on a fresh install (that gets How to Play).
        let fresh = Settings(defaults: defaults)
        defaults.removeObject(forKey: "seenWelcome"); defaults.removeObject(forKey: "lastSeenVersion")
        check(!fresh.shouldShowWhatsNew(current: "0.5.7"), "a fresh install doesn't get What's New")
        fresh.seenWelcome = true
        check(fresh.shouldShowWhatsNew(current: "0.5.7"), "updating from 0.5.5 shows What's New")
        fresh.lastSeenVersion = "0.5.7"
        check(!fresh.shouldShowWhatsNew(current: "0.5.7") && fresh.shouldShowWhatsNew(current: "0.5.8"),
              "...once per version")
        check(WhatsNewWindow.releases.first?.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
              || Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") == nil,
              "What's New has notes for this version")
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

extension SelfTest {
    /// Bones, yarn and the laser for every cat.
    static func sharedToyChecks(_ check: (Bool, String) -> Void) {
        let scr = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 60, width: 1440, height: 815))
        func world(_ cursor: CGPoint, pointer: CGPoint? = nil) -> World {
            var w = World(screens: [scr], windows: [], cursor: cursor)
            w.pointer = pointer
            return w
        }
        func cat(_ id: Int, at p: CGPoint, pile: ToyPile) -> Playground {
            var c = Playground(position: p)
            c.cat.random = { _ in 1 }; c.random = { _ in 0 }
            c.spotWindows = false; c.spotMenuBar = false; c.spotDock = false
            c.cat.sleepEnabled = false
            c.toys = pile
            c.catID = id
            c.ownsToys = id == 0
            return c
        }

        // A bone tossed near the second cat: that cat fetches it, not the first.
        let pile = ToyPile()
        var a = cat(0, at: CGPoint(x: 200, y: 300), pile: pile)
        var b = cat(1, at: CGPoint(x: 1200, y: 300), pile: pile)
        a.placeBone(at: CGPoint(x: 1150, y: 64), falling: false)
        a.mouseDown(on: .bone, at: CGPoint(x: 1150, y: 64), time: 0)
        a.mouseUp(at: CGPoint(x: 1150, y: 64), time: 0.05)              // a click: a little toss
        for _ in 0..<3 {
            a.tick10(world: world(CGPoint(x: 200, y: 300))); b.tick10(world: world(CGPoint(x: 1200, y: 300)))
            for _ in 0..<6 { a.physics(dt: 1.0 / 60, world: world(.zero)) }
        }
        check(b.mode == .fetching && a.mode != .fetching, "the closest cat goes for a tossed bone (not just the first cat)")
        var fetched = false
        for _ in 0..<300 where !fetched {
            a.tick10(world: world(CGPoint(x: 200, y: 300)))
            b.tick10(world: world(CGPoint(x: 1200, y: 300), pointer: CGPoint(x: 700, y: 400)))
            for _ in 0..<6 { a.physics(dt: 1.0 / 60, world: world(.zero)) }
            fetched = b.drainEvents().contains(.fetched)
        }
        check(fetched && hypot(b.cat.position.x - 700, b.cat.position.y - 400) < 60,
              "...and brings it back to you (your cursor, not its spot in the swarm)")
        check(pile.bones[0].fetcher == nil && !pile.bones[0].wanted, "...and lets go of it")

        // A closer cat takes over on the way.
        let race = ToyPile()
        var far = cat(0, at: CGPoint(x: 100, y: 300), pile: race)
        var near = cat(1, at: CGPoint(x: 1300, y: 600), pile: race)
        far.placeBone(at: CGPoint(x: 700, y: 64), falling: false)
        race.bones[0].wanted = true
        far.tick10(world: world(CGPoint(x: 100, y: 300)))
        check(far.mode == .fetching, "the only cat near enough goes for the bone")
        near.cat.position = CGPoint(x: 720, y: 120)
        near.tick10(world: world(CGPoint(x: 720, y: 120)))
        far.tick10(world: world(CGPoint(x: 100, y: 300)))
        check(near.mode == .fetching && far.mode != .fetching, "...but a much closer cat takes over, and the first gives up")

        // Two bones, two cats: one each.
        let two = ToyPile()
        var c = cat(0, at: CGPoint(x: 300, y: 300), pile: two)
        var d = cat(1, at: CGPoint(x: 1100, y: 300), pile: two)
        c.placeBone(at: CGPoint(x: 350, y: 64), falling: false, index: 0)
        c.placeBone(at: CGPoint(x: 1050, y: 64), falling: false, index: 1)
        two.bones[0].wanted = true; two.bones[1].wanted = true
        c.tick10(world: world(CGPoint(x: 300, y: 300))); d.tick10(world: world(CGPoint(x: 1100, y: 300)))
        check(c.boneIndex == 0 && d.boneIndex == 1 && c.mode == .fetching && d.mode == .fetching, "two bones, two cats: each fetches the one nearest it")

        // Yarn: an extra cat chases a ball rolling past it, and bats one it's sitting next to.
        let yarnPile = ToyPile()
        var owner = cat(0, at: CGPoint(x: 100, y: 800), pile: yarnPile)
        var e = cat(3, at: CGPoint(x: 900, y: 80), pile: yarnPile)
        owner.placeYarn(at: CGPoint(x: 700, y: 66), falling: false)
        yarnPile.yarns[0].prop.state = .flying
        yarnPile.yarns[0].prop.body.vel = CGVector(dx: 600, dy: 0)
        e.tick10(world: world(CGPoint(x: 900, y: 80)))
        check({ if case .chasingYarn = e.mode { return true }; return false }(), "any cat chases a rolling ball of yarn")
        var batted = false
        for _ in 0..<80 where !batted {
            e.tick10(world: world(CGPoint(x: 900, y: 80)))
            for _ in 0..<6 { owner.physics(dt: 1.0 / 60, world: world(.zero)) }
            batted = e.drainEvents().contains(.batYarn)
        }
        check(batted, "...and bats it")
        // Only the owner moves the toys: the extra's physics leaves a flying ball alone.
        let before = yarnPile.yarns[0].prop.body
        e.physics(dt: 1.0 / 60, world: world(.zero))
        check(yarnPile.yarns[0].prop.body == before, "only one cat's playground moves the toys (no double-speed toys)")

        // Laser: extras chase it too (they get the dot as their target).
        var l = cat(4, at: CGPoint(x: 300, y: 300), pile: ToyPile())
        l.laser = true
        for _ in 0..<40 { l.tick10(world: world(CGPoint(x: 800, y: 500))) }
        check(hypot(l.cat.position.x - 800, l.cat.position.y - 500) < 60, "an extra cat dashes after the laser dot")

        // Food: a hungry cat walks to the bowl, eats, and the bowl empties meal by meal.
        let fp = ToyPile()
        var eater = cat(0, at: CGPoint(x: 300, y: 400), pile: fp)
        eater.placeBowl(at: CGPoint(x: 900, y: 63.5), falling: false)
        eater.makeHungry()
        var ate = false, wentToBowl = false
        for _ in 0..<300 where !ate {
            eater.tick10(world: world(CGPoint(x: 300, y: 400)))
            if case .goingToBowl = eater.mode { wentToBowl = true }
            ate = eater.drainEvents().contains(.ate)
        }
        check(wentToBowl && ate && !eater.isHungry, "a hungry cat goes to the food bowl and eats")
        check(fp.bowls[0].food == ToyPile.Bowl.full - 1, "...one meal out of the bowl")
        check(abs(eater.cat.position.x - 900) < 30, "...eating right beside it")
        fp.bowls[0].food = 0
        var picky = cat(1, at: CGPoint(x: 300, y: 400), pile: fp)
        picky.makeHungry()
        for _ in 0..<50 { picky.tick10(world: world(CGPoint(x: 300, y: 400))) }
        check({ if case .goingToBowl = picky.mode { return false }; if case .eating = picky.mode { return false }; return true }(),
              "an empty bowl: nothing to eat")
        eater.mouseDown(on: .bowl, at: CGPoint(x: 900, y: 63.5), time: 0)
        eater.mouseUp(at: CGPoint(x: 900, y: 63.5), time: 0.05)
        check(fp.bowls[0].food == ToyPile.Bowl.full, "click the bowl to fill it up")

        // Playing together: the matcher pairs neighbours only, each cat once.
        let spots = [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 100), CGPoint(x: 900, y: 100), CGPoint(x: 120, y: 120),
                     CGPoint(x: 905, y: 110), CGPoint(x: 2000, y: 100)]
        let pairs = PlayMatcher.pairs(spots, free: [true, true, true, true, true, true], radius: 50, chance: { _ in 0 })
        let used = pairs.flatMap { [$0.0, $0.1] }
        check(pairs.count == 2 && Set(used).count == 4 && !used.contains(5)
              && pairs.allSatisfy { hypot(spots[$0.0].x - spots[$0.1].x, spots[$0.0].y - spots[$0.1].y) < 50 },
              "cats sitting together pair up to play (neighbours only, one partner each)")
        check(PlayMatcher.pairs(spots, free: [false, true, false, false, true, true], radius: 50, chance: { _ in 0 }).isEmpty,
              "...but not cats that are busy")
        let many = (0..<20_000).map { CGPoint(x: CGFloat($0 % 400) * 9, y: CGFloat($0 / 400) * 9) }
        let ms = (0..<3).map { _ -> Double in   // best of 3, so a busy Mac doesn't fail it
            let t0 = Date()
            _ = PlayMatcher.pairs(many, free: many.map { _ in true }, radius: 50, chance: { _ in 1 })
            return Date().timeIntervalSince(t0) * 1000
        }.min()!
        check(ms < 100, "...and finding pairs among 20,000 cats is quick (\(Int(ms)) ms)")
        for kind in PlayKind.allCases {
            let pp = ToyPile()
            var x = cat(0, at: CGPoint(x: 600, y: 300), pile: pp)
            var y = cat(1, at: CGPoint(x: 630, y: 300), pile: pp)
            for _ in 0..<30 { x.tick10(world: world(CGPoint(x: 600, y: 300))); y.tick10(world: world(CGPoint(x: 630, y: 300))) }
            check(x.canPlay && y.canPlay, "idle cats are free to play (\(kind))")
            x.startPlay(kind, with: y.cat.position, leader: true)
            y.startPlay(kind, with: x.cat.position, leader: false)
            var hearts = 0, anger = false, apart: CGFloat = 0
            for _ in 0..<kind.ticks + 2 {
                x.partner = y.cat.position; y.partner = x.cat.position
                x.tick10(world: world(CGPoint(x: 600, y: 300))); y.tick10(world: world(CGPoint(x: 630, y: 300)))
                hearts += x.drainEvents().filter { $0 == .heart }.count
                anger = anger || x.catPose.angry
                apart = max(apart, hypot(x.cat.position.x - 600, x.cat.position.y - 300))
            }
            switch kind {
            case .groom: check(hearts >= 2, "grooming each other: hearts")
            case .fight: check(anger && { if case .dazed = x.mode { return true }; return false }(), "a play-fight: 💢, then they sit it off")
            case .chase: check(apart > 60 && hypot(x.cat.position.x - y.cat.position.x, x.cat.position.y - y.cat.position.y) < 400,
                               "a chase: one runs off, the other follows")
            }
            check(!x.isPlaying && !y.isPlaying, "...and then it's over (\(kind))")
        }

        // Stacking: a box dropped on a box lands on its rim; take the bottom one and it falls.
        let sp = ToyPile()
        var stacker = cat(0, at: CGPoint(x: 100, y: 700), pile: sp)
        stacker.placeBox(at: CGPoint(x: 700, y: 60 + 15), falling: false, index: 0)
        stacker.placeBox(at: CGPoint(x: 704, y: 300), falling: true, index: 1)
        for _ in 0..<240 where !sp.boxes[1].prop.isResting { stacker.physics(dt: 1.0 / 60, world: world(.zero)) }
        let topY = sp.boxes[1].prop.body.pos.y
        check(sp.boxes[1].prop.isResting && topY > 75 + 15, "a box dropped on another stacks on top of it (y=\(Int(topY)))")
        stacker.placeBone(at: CGPoint(x: 700, y: 400), falling: true)
        for _ in 0..<240 where !sp.bones[0].prop.isResting { stacker.physics(dt: 1.0 / 60, world: world(.zero)) }
        check(sp.bones[0].prop.body.pos.y > topY, "...and a bone dropped on the stack lands on top")
        stacker.mouseDown(on: .box, at: CGPoint(x: 700, y: 75), time: 0, index: 0)
        stacker.mouseDragged(to: CGPoint(x: 400, y: 300), time: 0.1)
        stacker.physics(dt: 1.0 / 60, world: world(.zero))
        check(sp.boxes[1].prop.state == .flying, "pull the bottom box out and the one on top falls")
        stacker.mouseUp(at: CGPoint(x: 400, y: 300), time: 1)
        check(!stacker.needsWindowTracking || sp.boxes.contains { $0.prop.state == .flying },
              "boxes sitting on boxes don't keep window reading going")
        // Climbing: in gravity mode a cat hops up onto a box to get to a cursor above it.
        let cp = ToyPile()
        var climber = cat(0, at: CGPoint(x: 500, y: 73), pile: cp)
        climber.placeBox(at: CGPoint(x: 600, y: 60 + 15), falling: false)
        climber.gravityMode = true
        climber.cat.sleepEnabled = false
        var maxFeet: CGFloat = 0
        for _ in 0..<60 {
            climber.tick10(world: world(CGPoint(x: 600, y: 400)))
            for _ in 0..<6 { climber.physics(dt: 1.0 / 60, world: world(CGPoint(x: 600, y: 400))) }
            maxFeet = max(maxFeet, climber.cat.position.y - 13)
        }
        check(climber.cat.position.y - 13 > 75 + 4 && abs(climber.cat.position.x - 600) < 20,
              "a walking cat hops up onto a box to get closer to you (feet at \(Int(climber.cat.position.y - 13)))")

        // The big box: four cats in one box, each in its own seat.
        let bp = ToyPile()
        var bigCats = (0..<5).map { cat($0, at: CGPoint(x: 400 + CGFloat($0) * 10, y: 500), pile: bp) }
        bigCats[0].placeBox(at: CGPoint(x: 500, y: 60 + 31), falling: false)
        bp.setBig(0, true)
        for _ in 0..<120 { bigCats[0].physics(dt: 1.0 / 60, world: world(.zero)) }
        check(bp.boxes[0].prop.isResting && bp.boxes[0].prop.shape.halfW == 28, "a big box is twice the size")
        for i in bigCats.indices {
            bigCats[i].launch(at: CGPoint(x: 500 + CGFloat(i * 4 - 8), y: 200), velocity: .zero)
            for _ in 0..<120 where !bigCats[i].inBox { bigCats[i].physics(dt: 1.0 / 60, world: world(.zero)) }
        }
        let inside = bigCats.filter(\.inBigBox)
        check(inside.count == 4 && bp.boxes[0].nappers.count == 4, "four cats fit in the big box (the fifth doesn't)")
        check(Set(inside.map { "\($0.cat.position.x)" }).count == 4, "...each in its own seat")
        check(inside.allSatisfy { !$0.catPose.inBox && $0.catPose.inBigBox }, "...drawn by the big box, not their own little box")
        bigCats[0].rightClick(.box, index: 0)
        check(!bp.boxes[0].closed, "a big box has no flaps to shut")
        // ...and they nap there until you take them out: long past a nap's end, still in.
        let seated = bigCats.indices.filter { bigCats[$0].inBigBox }
        for _ in 0..<1500 { for i in seated { bigCats[i].tick10(world: world(CGPoint(x: 1200, y: 600))) } }
        check(seated.allSatisfy { bigCats[$0].inBigBox && bigCats[$0].isSleeping },
              "cats in the big box nap on until you take them out")
        let lifted = seated[0], napper = seated[1]
        let head = bigCats[lifted].cat.position
        bigCats[lifted].mouseDown(on: .cat, at: head, time: 0)
        bigCats[lifted].mouseDragged(to: CGPoint(x: head.x + 40, y: head.y + 200), time: 0.1)
        bigCats[lifted].mouseUp(at: CGPoint(x: head.x + 40, y: head.y + 200), time: 0.6)
        bigCats[lifted].tick10(world: world(CGPoint(x: 1200, y: 600)))
        check(!bigCats[lifted].inBigBox && bp.boxes[0].nappers.count == 3, "...you lift one out by dragging it")
        bigCats[napper].mouseDown(on: .cat, at: bigCats[napper].cat.position, time: 1)
        bigCats[napper].mouseUp(at: bigCats[napper].cat.position, time: 1.05, clickCount: 2)
        bigCats[napper].tick10(world: world(CGPoint(x: 1200, y: 600)))
        check(!bigCats[napper].inBigBox, "...or double-click one awake and out it climbs")
        // 0.6.5: lift one out and let go of it right over the box: it doesn't drop straight
        // back in (the big box's wide opening caught every cat you took out).
        let third = seated[2]
        let h3 = bigCats[third].cat.position
        bigCats[third].mouseDown(on: .cat, at: h3, time: 2)
        bigCats[third].mouseDragged(to: CGPoint(x: h3.x, y: h3.y + 60), time: 2.1)
        bigCats[third].mouseDragged(to: CGPoint(x: h3.x, y: h3.y + 60), time: 2.5)
        bigCats[third].mouseUp(at: CGPoint(x: h3.x, y: h3.y + 60), time: 2.6)
        for _ in 0..<240 { bigCats[third].physics(dt: 1.0 / 60, world: world(.zero)) }
        check(!bigCats[third].inBigBox, "...and a cat lifted out and let go right over the big box stays out")
        // ...but pick it up again and drop it in, and in it goes.
        let h4 = bigCats[third].cat.position
        bigCats[third].mouseDown(on: .cat, at: h4, time: 5)
        bigCats[third].mouseDragged(to: CGPoint(x: 500, y: 180), time: 5.1)
        bigCats[third].mouseDragged(to: CGPoint(x: 500, y: 180), time: 5.5)
        bigCats[third].mouseUp(at: CGPoint(x: 500, y: 180), time: 5.6)
        for _ in 0..<240 where !bigCats[third].inBigBox { bigCats[third].physics(dt: 1.0 / 60, world: world(.zero)) }
        check(bigCats[third].inBigBox, "...while one you drop in from outside still goes in")

        // Crowd cats nap in the GPU box heap (real GPU code).
        let crowd = CrowdController()
        if crowd.isAvailable, let sheet = SpriteSheet.load() {
            let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
            crowd.setHeap(BoxHeap.layout(count: 400, screens: [screen], scale: 1))
            _ = crowd.selfCheck(count: 600, sheets: [sheet], ticks: 400, cursor: CGPoint(x: 400, y: 500), screen: screen)
            let napping = crowd.heapNappers()
            check(napping > 50, "crowd cats go and nap in the box heap (\(napping) of 600)")
        } else {
            check(false, "crowd mode's GPU code compiles (with the heap)")
        }

        // Names: the first cat is Neko, the rest have their own names, and renaming sticks.
        check(CatNames.name(0) == "Neko" && CatNames.name(1) == "Mochi" && CatNames.name(2) != CatNames.name(1),
              "every cat has a name (Neko, Mochi, …)")
        check(CatNames.name(CatNames.names.count + 1) == "Mochi II", "...and past the list they get numbered (Mochi II)")
        check(CatNames.name(0, custom: ["0": "Biscuit"]) == "Biscuit", "...and you can rename them")
        let csSuite = "local.oneko.selftest.catstats"
        UserDefaults().removePersistentDomain(forName: csSuite)
        let cs = CatStats(defaults: UserDefaults(suiteName: csSuite)!)
        for _ in 0..<3 { cs.bump(.pets, cat: 2) }
        cs.bump(.yeets, cat: 2); cs.bump(.pets, cat: 0)
        check(cs.summary(cat: 2) == "3 pets · 1 yeets", "each cat keeps its own stats (\(cs.summary(cat: 2)))")
        check(cs.champion(.pets, among: 5)?.id == 2 && cs.champion(.pets, among: 2)?.id == 0, "...with a leaderboard of the cats you have")
        cs.save()
        check(CatStats(defaults: UserDefaults(suiteName: csSuite)!).value(.pets, cat: 2) == 3, "...that survives a relaunch")
        UserDefaults().removePersistentDomain(forName: csSuite)

        // Weather: by the season, or your real weather.
        func day(_ m: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: m, day: 10))! }
        check(SeasonOverlay.weather("auto", date: day(12)) == .snow && SeasonOverlay.weather("auto", date: day(10)) == .leaves
              && SeasonOverlay.weather("auto", date: day(6)) == nil && SeasonOverlay.weather("off", date: day(12)) == nil,
              "seasonal weather: snow in winter, leaves in autumn, nothing in summer")
        check(LiveWeather.weather(code: 95, isDay: true) == .thunder && LiveWeather.weather(code: 63, isDay: false) == .rain
              && LiveWeather.weather(code: 81, isDay: true) == .rain && LiveWeather.weather(code: 73, isDay: true) == .snow
              && LiveWeather.weather(code: 0, isDay: true) == .sunny && LiveWeather.weather(code: 0, isDay: false) == nil
              && LiveWeather.weather(code: 3, isDay: true) == nil,
              "local weather: thunderstorms, rain and snow fall, clear days shine, clouds and clear nights are calm")
        check(SeasonOverlay.weather("live", live: .rain) == .rain && SeasonOverlay.weather("live", live: nil) == nil
              && SeasonOverlay.weather("thunder") == .thunder && SeasonOverlay.weather("sunny") == .sunny,
              "the weather setting: local, or one you pick")

        // Updates: version numbers compared properly, GitHub's release read right.
        check(UpdateChecker.isNewer("v0.5.10", than: "0.5.9") && UpdateChecker.isNewer("0.6", than: "0.5.9")
              && !UpdateChecker.isNewer("0.5.8", than: "0.5.8") && !UpdateChecker.isNewer("v0.5.7", than: "0.5.8"),
              "update check: 0.5.10 is newer than 0.5.9, the same version isn't")
        let json = #"{"tag_name":"v0.5.9","html_url":"https://github.com/rsinghSD/oneko/releases/tag/v0.5.9","body":"cat follow mouse (real)","assets":[{"browser_download_url":"https://github.com/rsinghSD/oneko/releases/download/v0.5.9/Oneko-0.5.9.dmg"}]}"#
        let rel = UpdateChecker.parse(Data(json.utf8))
        check(rel?.version == "0.5.9" && rel?.dmg?.lastPathComponent == "Oneko-0.5.9.dmg", "...and reads GitHub's latest release (the DMG to download)")

        // Settings: counts up to 50, old toggles carry over.
        let suite = "local.oneko.selftest.toys"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "boneOut"); defaults.set(true, forKey: "yarnOut")
        defaults.set(10.0, forKey: "boneX"); defaults.set(20.0, forKey: "boneY")
        let st = Settings(defaults: defaults)
        check(st.boneCount == 1 && st.yarnCount == 1 && st.bonePositions == [CGPoint(x: 10, y: 20)],
              "an old bone and ball of yarn carry over as 1 each")
        st.boneCount = 500; st.yarnCount = 7
        check(st.boneCount == 50 && st.yarnCount == 7, "bones and yarn go up to 50 each")
        st.boneCount = 0
        check(!st.boneOut && st.lastBoneCount == 50, "turning bones off remembers how many")
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
