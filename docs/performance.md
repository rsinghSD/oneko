# Performance: what each feature costs

Measured with `build/Oneko.app/Contents/MacOS/Oneko --bench` on this Mac (Apple silicon), 2026-11-21.
The bench runs the real simulation headless: every cat shares one set of toys, chasing a cursor
that circles two displays with 10 app windows. It measures Oneko's own CPU work only. Each real
cat and toy is also a little window, and moving those costs WindowServer time, which the bench
can't see.

"CPU %" is one core: 10 ticks a second, plus 60 physics frames a second while anything moves.

## Simulation (CPU)

| cats | 0.5.7 tick | 0.5.8 tick | 0.5.7 everyone-thrown frame | 0.5.8 everyone-thrown frame |
|---:|---:|---:|---:|---:|
| 1 | 0.002 ms | 0.004 ms | 0.001 ms | 0.002 ms |
| 50 | 0.036 ms | 0.062 ms | 0.022 ms | 0.117 ms |
| 500 | 0.337 ms | 0.608 ms | 0.248 ms | 0.551 ms |
| 5,000 | 3.45 ms (6.2 %) | 5.32 ms (7.5 %) | 2.99 ms (18 %) | 5.20 ms (31 %) |

The 0.5.8 bench is a busier desktop than 0.5.7's: 10 boxes (one big), 10 bones all wanted,
10 balls of yarn, 3 bowls, 10 mice, a quarter of the cats hungry, and cat pairing every 2 s.
(Toy mice were removed after the optimization pass; the bench no longer has them.)

Step by step (5,000 cats, idle tick):

| step | tick | what it added |
|---|---:|---|
| 0.5.7 baseline (10 boxes, 1 bone, 1 yarn) | 3.45 ms | |
| + bones, yarn, laser for every cat; 10 of each | 5.27 ms | every cat looks for a wanted bone and a rolling ball each tick |
| + toy mice and food bowls | 5.27 ms | about nothing (the owner moves 10 mice; cats look only now and then) |
| + play pairing, big box, stacking, crowd heap naps | 5.32 ms | pairing 20,000 cats takes ~25 ms, once every 2 s |

## GPU

| work | time |
|---|---:|
| draw a heap of 10,000 boxes (once; then only when it changes) | 5.4 ms |
| draw a heap of 1,000,000 boxes (once) | 60 ms (+6 ms layout on the CPU) |
| 20,000 crowd cats, 10 ticks + a frame | 11.5 ms |
| 100,000 crowd cats, 10 ticks + a frame | 29.3 ms |

Crowd cats napping in the heap add a second instanced draw (box fronts) per display: the same
vertex count as the cats, but almost all of it is culled.

## Cheap by design

- **Weather:** a Core Animation emitter per display, drawn by the window server. The piles on
  window tops only change when the window list changes (checked once a second).
- **Box heap:** drawn once, not every frame.
- **Names and per-cat stats:** saved every 5 s at most, never per event.
- **Update check:** one HTTPS request a day, 20 s after launch.
- **Idle cats:** skip the 60 fps clock entirely (only moving cats get physics, drawing and event work).

## Where to look next (for the optimization session; see "After optimization" below)

1. **Everyone-thrown frame got 74 % slower** (3.0 → 5.2 ms at 5,000 cats). The likely causes:
   every flying cat scans every box in `dropsIntoBox`, calls `syncClaims` and `myBoxPos` each
   frame, and every access to the shared `ToyPile` class runs a dynamic exclusivity check.
2. **Tick +54 %** from `wantedBone()` and the rolling-yarn scan per cat per tick. A per-tick
   "any bone wanted / any yarn rolling" flag on the pile would skip almost all of it.
3. **`boxTops(world)`** builds a new `[Drawing]` (with point arrays) for every moving prop each
   frame; it could be cached once per frame.
4. **WindowServer cost** of real toy windows (up to 50 each of boxes, bones and yarn) isn't
   measured here; an in-app `ONEKO_DEBUG` timing of `render()` would show it.

## After optimization

Same Mac (M1), same day, `--bench` medians of 5 runs. The "before" column is 0.5.8 as it was
at the start of the pass. It runs a little slower than the table above, because the desktop
was busier (the installed Oneko was running).

| scenario | cats | before | after | |
|---|---:|---:|---:|---:|
| idle tick | 1 | 0.004 ms | 0.001 ms | |
| idle tick | 50 | 0.062 ms | 0.008 ms | 7.8× |
| idle tick | 500 | 0.570 ms | 0.078 ms | 7.3× |
| idle tick | 5,000 | 5.82 ms (8.5 %) | 0.753 ms (1.0 %) | 7.7× |
| everyone-thrown frame | 1 | 0.002 ms | 0.001 ms | |
| everyone-thrown frame | 50 | 0.057 ms | 0.006 ms | 9.5× |
| everyone-thrown frame | 500 | 0.587 ms (3.5 %) | 0.053 ms (0.3 %) | 11× |
| everyone-thrown frame | 5,000 | 5.84 ms (35 %) | 0.542 ms (3.3 %) | 10.8× |

New rows (added in this pass, so their "before" is from the middle of it):

| scenario | before | after |
|---|---:|---:|
| owner's frame, 50 boxes + 50 bones + 50 yarn + 3 bowls falling | 0.211 ms | 0.050 ms |
| gravity mode, 500 cats walking | 0.50 ms | 0.20 ms |
| gravity mode, 5,000 cats walking | 4.53 ms | 2.02 ms |

GPU and memory didn't change (they weren't touched).

### Step by step (5,000 cats unless noted, cumulative)

| step | idle tick | thrown frame |
|---|---:|---:|
| 0.5.8 as given | 5.82 | 5.84 |
| 1. `[safe:]` specialized | 3.67 | 2.87 |
| 2. `NekoBrain.direction` as a switch; `updateWindows` skips unchanged work | 2.73 | 1.64 |
| 3. extra cats read in place, not copied (app loops, and the bench's) | 2.37 | 0.94 |
| 4. tick: cached screen frames and Docks, one pile read per yarn/bone scan | 1.38 | 0.85 |
| 5. `inout` getters: no 905-byte memcpy per call | 1.25 | 0.67 |
| 6. `batYarn`: one read and one write | 1.22 | 0.66 |
| 7. bench harness only: `world(t)` once per tick, not twice per cat | 0.90 | 0.59 |
| 8. `dropsIntoBox`, rims once per frame, no `segments` arrays | 0.89 | 0.58 |
| 9. AppDelegate window loops (not in the bench) | 0.90 | 0.60 |
| 10. `Dice` instead of the system random generator | 0.85 | 0.60 |
| 11. `syncClaims` looks at bones only after claiming one | 0.84 | 0.555 |
| 12. box rims cached on the pile (gravity 4.53 → 2.18 ms) | 0.85 | 0.55 |
| 13. no copies of `self` in the tick's helpers (gravity → 2.02 ms) | 0.77 | 0.546 |

Step 7 changes only the bench, not the app. The harness built its `World` twice per cat
per tick; the app doesn't. That overhead (0.33 ms per idle tick at 5,000 cats) was also in
the "before" numbers, so about 0.3 of the 5.1 ms saved on the idle tick is the harness, and
the rest is the app. Step 3 changes the app's loops, and the bench was changed the same way
to keep driving cats the way the app does.

### What changed, and why it was slow

The build has no whole-module optimization (Swift 6.4.2 hangs on it). So the optimizer only
sees one file at a time, and most of the cost came from two effects of that:

- **Generic helpers aren't specialized across files.** `Array[safe:]` lived in
  AppDelegate.swift and was called from Playground.swift, so every call (dozens per cat, per
  tick and frame) ran as unspecialized generic code: a runtime metadata lookup, then
  `indices.contains`. It now sits in Playground.swift with a plain bounds check. That was
  step 1, worth half of everything.
- **A `Playground` is about 900 bytes, and calling a getter on it from another file copies
  it.** `x.play.catPose` and `x.play.needsPhysics` on an `ExtraCat` copied all of it, with a
  retain and release for every reference inside, for every cat, every frame. Even after that
  was fixed, the call itself did a 905-byte `memcpy`. Now:
  - `ExtraCat.pose`, `.needsPhysics`, `.catScale`, `.canPlay` and `.isPlaying` go through
    `Playground.pose(&play)` and its siblings. These take the playground `inout` (by address),
    and the getter is inlined into them.
  - Inside Playground.swift, helpers that a mutating method calls (`bone`, `yarn`,
    `boxClosed`, `rollingYarn`, `walkTarget`, `nearestBowlWithFood`) are
    `@inline(__always)`.
  - Closures no longer mention `cat.position` directly (which captures, and copies, all of
    `self`); they use a local copy of the position.
- **Smaller things, per cat:**
  - `NekoBrain.direction` built a `String` and parsed it back into an enum on every step.
  - `updateWindows` rebuilt its window dictionary, and a box-rim `World`, on every call,
    even when nothing rode a window and the windows hadn't moved.
  - Each tick built new arrays of screen frames and Docks.
  - Yarn and bone scans did one exclusivity-checked access to the shared pile per toy,
    instead of one per scan.
  - `syncClaims` looked up a bone every frame for cats that never claimed one.
  - Every random roll went through the system's cryptographic generator, which reads the
    clock on each call. It's now `Dice`, a wyrand generator seeded once from the system one.
    The rolls have the same distribution; they're just cheap.
- **Box rims** (lead 3), which other things land on:
  - `ToyPile.restingRims(scale:)` builds them once and keeps them until a box changes
    (`boxes` has a `didSet`).
  - Bones, yarn and bowls share one rim `World` per frame.
  - `boxTops` reserves its array once.
  - `Physics.collideDrawings` walks a drawing's points directly instead of building its
    `segments` array on every step.
- **`dropsIntoBox`** (lead 1) reads the pile once and tests the cheap geometry first. It was
  never the main cost; the generic `[safe:]` inside `isFree` was.

**`-enforce-exclusivity=unchecked` isn't used.** Measured at the end, it saves another
0.13 ms per idle tick at 5,000 cats (about 15 %, or 0.13 % of a core) and about 1 % on the
thrown frame. In return, a future bug that overlaps two accesses to the shared `ToyPile`
(say, a closure that reads `toys.boxes` while `toys.boxes[i]` is being modified) would
silently corrupt memory instead of stopping with a clear "simultaneous access" trap. It
isn't worth that. Most of what it would have saved is already gone, because the hot loops
now read the pile once per scan.

### WindowServer (lead 4)

The bench can't see this. Run with `ONEKO_DEBUG=1` and every 10 s the app prints how long
`render()` (including `updateVisibility`) and `updateClickThrough()` take. That includes
WindowServer calls. It also prints how many restacks happened and how many windows each one
moved. Changed:

- `PropWindow.setArt` is called on every render for bowls and boxes. With the same art
  it still resized the window (a WindowServer call) and rewrote a layer. Now it returns
  straight away.
- On every mouse move, `updateClickThrough` worked out the pose of each extra cat until one
  was under the pointer: 5,000 poses when none was. It now checks the cat's position first,
  using the same box `catHit` checks.
- `render`, `updateVisibility` and `handleEvents` no longer build an array of every extra
  cat's index on every call.

- **The restack.** Whenever any of Oneko's windows became visible (a box emptying, a
  fetched bone being dropped), `updateVisibility` called `orderFrontRegardless` on
  **every** visible window, up to 5,000 cats plus the toys. Now only the windows that are
  appearing move. Each one goes `order(.below, relativeTo:)` its nearest visible neighbour
  above it in the stacking order (toys, extra cats, the first cat, the big box's front, the
  laser dot), or `orderFrontRegardless` if it has none on its level. The laser dot is one
  level up, so nothing stacks against it. On a 60 fps frame that only looked at the cats
  that moved, the other cats still count as neighbours, so a toy that appears goes under
  every cat. (Before, those frames brought toys in front of every cat that wasn't moving.)
  Clicking a window can bring it to the front of its level, and the old restack happened to
  undo that. So on mouse-up the clicked window is put back in its place, with one call.

Measured with `ONEKO_DEBUG=1` on a real desktop, on a test copy of the app with its own
bundle ID and preferences: 1,000 real cats (no spawn dialog under 1,000) plus 10 boxes and
5 bones. Sampling started once every cat was on screen and ran for 75 s:

| per restack (steady state, 1,000 cats) | before | after |
|---|---|---|
| windows moved | 1,018–1,019 | 1 |
| `updateVisibility` time | 0.21–0.23 s | 0.2–0.65 ms per render, restack included |

A standalone program timed the calls with nothing else running. With 2,000 windows on
screen, showing a new window costs 0.8 ms with either call, and moving an existing one to
the front costs 0.3 ms (0.17 ms at 1,000). So the old restack cost about 0.3 ms per cat on
screen, every time any window appeared: 0.6 s at 2,000 cats.

While cats spawn (100 new windows a tick), the cost is showing those new windows, not the
restack. With 2,000 cats, a batch took 1.6–2.2 s before and 1.5–2.7 s after, and neither
run got past about 1,300 windows in 75 s.

Stacking against other apps: `CGWindowListCopyWindowInfo` snapshots were taken every 5 s,
60 in all across both builds at 1,000 and 2,000 cats. In every one, all toys were behind
all cats, and Oneko's windows were one block in front of the other app's status-level
windows (Control Center's menu-bar items), never mixed in among them. In one early 1-cat
run, toy windows ended up in front of the cat partway through. Clicks are the likely cause,
which is why mouse-up now puts the window back. That fix hasn't been checked with real
clicks.

### Bench additions

- `toys:` the owner's frame with every toy falling at once.
- `gravity mode:` 500 and 5,000 walking cats.
- `ONEKO_BENCH_LOOP=physics:5000` (or `idle:500`, and so on) repeats one scenario for 20 s,
  long enough to attach `sample <pid>`. That's how every step above was found.

### Where to look next

- Moving the windows, now that the restack is gone. In the 1,000-cat run, once the cats got
  going together, `render` took about 1 s a frame. Only 0.2 ms of that was
  `updateVisibility`; the rest was the cat windows' frame updates.
- Spawning: each new cat window costs 5–25 ms to show the first time with 1,000+ windows
  up, against 0.8 ms in an empty test program. Spawning 2,000 real cats doesn't finish in
  75 s.
- Gravity mode is now the heaviest simulated case (2 ms a frame for 5,000 walkers).
  Most of what's left is `Physics.step` against the box rims and windows. A walker standing
  still already skips physics.
- What's left of the idle tick is spread thin: `NekoBrain` movement, about 10 % exclusivity
  checks, and the window-list comparison in `updateWindows`.
