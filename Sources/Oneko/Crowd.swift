import AppKit
import Metal
import QuartzCore

/// Crowd mode (the nuts.wad switch): every cat past the first 50. They live entirely on
/// the GPU: a compute pass moves them 10× a second (classic oneko steps), and one draw
/// call per display paints them all from a texture of coats. They're click-through, so
/// even a million of them can't get in your way, only in your view.
///
/// If the GPU falls behind, ticks are skipped instead of queued, so the rest of the Mac
/// stays responsive; it just gets choppy.
final class CrowdController {
    var paused = false
    var speed: CGFloat = 10
    var scale: CGFloat = 1
    var hideInFullScreen = true
    /// Swarm, conga line or free roam, like the other cats.
    var behavior: Settings.CatBehavior = .swarm
    /// Who the first crowd cat follows in a conga line (the last interactive cat).
    var leader: CGPoint = .zero

    private(set) var count = 0
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var step: MTLComputePipelineState?
    private var draw: MTLRenderPipelineState?
    private var buffers: [MTLBuffer] = []
    private var current = 0
    private var atlas: MTLTexture?
    private var coatCount = 1
    private var windows: [CrowdWindow] = []
    private var frames: [CGRect] = []
    private var visible = true
    private var tickNumber: UInt32 = 0
    private var inFlight = false

    /// Mirrors the Metal structs below.
    private struct Cat { var pos: SIMD2<Float>; var cell: UInt16; var idle: UInt16; var seed: UInt32 }
    private struct Params {
        var cursor: SIMD2<Float>; var leader: SIMD2<Float>
        var count: UInt32; var tick: UInt32; var mode: UInt32; var paused: UInt32
        var speed: Float; var halfSize: Float; var spread: SIMD2<Float>; var screenCount: UInt32; var pad: UInt32 = 0
        var screens: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                      SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }
    private struct DrawParams { var origin: SIMD2<Float>; var size: SIMD2<Float>; var halfSize: Float; var coats: UInt32 }

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        guard let device else { return }
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            if let f = lib.makeFunction(name: "crowd_step") { step = try device.makeComputePipelineState(function: f) }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "crowd_vertex")
            d.fragmentFunction = lib.makeFunction(name: "crowd_fragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            draw = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            FileHandle.standardError.write("Oneko: crowd mode unavailable: \(error)\n".data(using: .utf8)!)
        }
    }

    var isAvailable: Bool { step != nil && draw != nil }

    // MARK: - Setup

    /// `n` crowd cats, bursting out of `origin`. Keeps the ones already out when growing.
    func setCount(_ n: Int, around origin: CGPoint) {
        guard let device, n != count else { return }
        let size = max(1, n) * MemoryLayout<Cat>.stride
        guard let a = device.makeBuffer(length: size, options: .storageModeShared),
              let b = device.makeBuffer(length: size, options: .storageModeShared) else { return }
        let keep = min(count, n)
        let dst = a.contents().bindMemory(to: Cat.self, capacity: max(1, n))
        if keep > 0, let old = buffers[safe: current] {
            dst.update(from: old.contents().bindMemory(to: Cat.self, capacity: count), count: keep)
        }
        let o = SIMD2<Float>(Float(origin.x), Float(origin.y))
        for i in keep..<n {
            var h = UInt32(truncatingIfNeeded: i &* 2_654_435_761)
            h ^= h >> 15
            let jx = Float(h & 0xFF) / 255 - 0.5, jy = Float((h >> 8) & 0xFF) / 255 - 0.5
            dst[i] = Cat(pos: o + SIMD2(jx, jy) * 24, cell: 3 * 8 + 3, idle: 0, seed: UInt32(i))
        }
        memcpy(b.contents(), a.contents(), size)
        buffers = [a, b]
        current = 0
        count = n
    }

    /// The coats the crowd wears (each cat gets one, by its number).
    func setCoats(_ sheets: [SpriteSheet]) {
        guard let device, !sheets.isEmpty else { return }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba8Unorm
        d.width = 256
        d.height = 128
        d.arrayLength = sheets.count
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return }
        for (i, s) in sheets.enumerated() {
            let px = s.rgbaPixels
            guard px.count == 256 * 128 * 4 else { continue }
            px.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0, slice: i,
                          withBytes: raw.baseAddress!, bytesPerRow: 256 * 4, bytesPerImage: 256 * 128 * 4)
            }
        }
        atlas = t
        coatCount = sheets.count
    }

    func setVisible(_ on: Bool) {
        visible = on
        if !on { for w in windows { w.orderOut(nil) } }
    }

    func stop() {
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        frames = []
        buffers = []
        count = 0
    }

    // MARK: - 10 Hz

    func tick(cursor: CGPoint, screens: [ScreenInfo], covered: [CGRect]) {
        guard visible, isAvailable, count > 0, !inFlight, let queue, let cb = queue.makeCommandBuffer() else { return }
        syncWindows(screens.map(\.frame))
        encodeStep(cb, cursor: cursor, screens: screens.map(\.frame))
        for (w, f) in zip(windows, frames) {
            let hide = hideInFullScreen && covered.contains(f)
            if hide { if w.isVisible { w.orderOut(nil) }; continue }
            if !w.isVisible { w.orderFrontRegardless() }
            guard let drawable = w.metalLayer.nextDrawable() else { continue }
            encodeDraw(cb, into: drawable.texture, frame: f)
            cb.present(drawable)
        }
        inFlight = true
        cb.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.inFlight = false }
        }
        cb.commit()
    }

    /// One 10 Hz step for every crowd cat.
    private func encodeStep(_ cb: MTLCommandBuffer, cursor: CGPoint, screens: [CGRect]) {
        guard let step, buffers.count == 2 else { return }
        tickNumber &+= 1
        // Spread the crowd over a disc around the cursor: as dense as the first 50 cats, but
        // never much wider than all the displays together.
        let area = screens.reduce(0) { $0 + $1.width * $1.height }
        let natural = 30 * scale * CGFloat(Double(count + 50).squareRoot())
        // An oval shaped like the display you're on, so a big swarm fills it instead of
        // piling up along its top and bottom edges.
        let home = screens.first { $0.contains(cursor) } ?? screens.first ?? .zero
        let fill = min(natural, (area / .pi).squareRoot() * 1.15)
        let aspect = home.height > 0 ? home.width / home.height : 1
        let spread = SIMD2<Float>(Float(min(fill * aspect.squareRoot(), max(natural, 1))),
                                  Float(min(fill / aspect.squareRoot(), max(natural, 1))))
        var rects = Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: 8)
        for (i, s) in screens.prefix(8).enumerated() {
            rects[i] = SIMD4(Float(s.minX), Float(s.minY), Float(s.maxX), Float(s.maxY))
        }
        var p = Params(
            cursor: SIMD2(Float(cursor.x), Float(cursor.y)), leader: SIMD2(Float(leader.x), Float(leader.y)),
            count: UInt32(count), tick: tickNumber,
            mode: behavior == .swarm ? 0 : behavior == .conga ? 1 : 2, paused: paused ? 1 : 0,
            speed: Float(speed), halfSize: Float(16 * scale), spread: spread,
            screenCount: UInt32(min(8, screens.count)),
            screens: (rects[0], rects[1], rects[2], rects[3], rects[4], rects[5], rects[6], rects[7]))
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(step)
        enc.setBuffer(buffers[current], offset: 0, index: 0)
        enc.setBuffer(buffers[1 - current], offset: 0, index: 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 2)
        let w = step.threadExecutionWidth
        enc.dispatchThreadgroups(MTLSize(width: (count + w - 1) / w, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        current = 1 - current
    }

    /// Paint every cat on display `f` into `target`.
    private func encodeDraw(_ cb: MTLCommandBuffer, into target: MTLTexture, frame f: CGRect) {
        guard let draw, let atlas, buffers.count == 2 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var dp = DrawParams(origin: SIMD2(Float(f.minX), Float(f.minY)), size: SIMD2(Float(f.width), Float(f.height)),
                            halfSize: Float(16 * scale), coats: UInt32(coatCount))
        enc.setRenderPipelineState(draw)
        enc.setVertexBuffer(buffers[current], offset: 0, index: 0)
        enc.setVertexBytes(&dp, length: MemoryLayout<DrawParams>.stride, index: 1)
        enc.setFragmentTexture(atlas, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count * 6)
        enc.endEncoding()
    }

    /// The last self-check frame (BGRA, top row first), for `--crowd-png`.
    private(set) var lastSnapshot: (pixels: [UInt8], width: Int, height: Int)?

    /// For `--selftest`: run the real GPU code offscreen. Returns how close the crowd got
    /// to the cursor (median distance) and how many pixels it painted.
    func selfCheck(count n: Int, sheets: [SpriteSheet], ticks: Int, cursor: CGPoint, screen: CGRect) -> (median: CGFloat, pixels: Int)? {
        guard let device, let queue, isAvailable else { return nil }
        setCoats(sheets)
        setCount(n, around: CGPoint(x: screen.minX + 50, y: screen.minY + 50))
        for _ in 0..<ticks {
            guard let cb = queue.makeCommandBuffer() else { return nil }
            encodeStep(cb, cursor: cursor, screens: [screen])
            cb.commit()
            cb.waitUntilCompleted()
        }
        let cats = buffers[current].contents().bindMemory(to: Cat.self, capacity: n)
        let d = (0..<n).map { hypot(CGFloat(cats[$0].pos.x) - cursor.x, CGFloat(cats[$0].pos.y) - cursor.y) }.sorted()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(screen.width),
                                                          height: Int(screen.height), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        encodeDraw(cb, into: tex, frame: screen)
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: Int(screen.width * screen.height) * 4)
        tex.getBytes(&px, bytesPerRow: Int(screen.width) * 4, from: MTLRegionMake2D(0, 0, Int(screen.width), Int(screen.height)), mipmapLevel: 0)
        let painted = stride(from: 3, to: px.count, by: 4).reduce(0) { $0 + (px[$1] > 0 ? 1 : 0) }
        lastSnapshot = (px, Int(screen.width), Int(screen.height))
        return (d[n / 2], painted)
    }

    /// One click-through overlay per display, rebuilt when displays change.
    private func syncWindows(_ now: [CGRect]) {
        guard now != frames, let device else { return }
        for w in windows { w.orderOut(nil); w.close() }
        windows = now.map { CrowdWindow(frame: $0, device: device) }
        frames = now
        for w in windows { w.orderFrontRegardless() }
    }

    // MARK: - GPU

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Cat { float2 pos; ushort cell; ushort idle; uint seed; };
    struct Params {
        float2 cursor; float2 leader;
        uint count; uint tick; uint mode; uint paused;
        float speed; float halfSize; float2 spread; uint screenCount; uint pad;
        float4 screens[8];
    };
    struct DrawParams { float2 origin; float2 size; float halfSize; uint coats; };

    static uint hash(uint x) {
        x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
        return x;
    }
    static float unit(uint x) { return float(hash(x) & 0xFFFFFF) / 16777216.0; }

    // Cells (row * 8 + col) of the classic sheet, two frames each: N NE E SE S SW W NW.
    constant ushort runCells[8][2] = {
        {17, 25}, {16, 24}, {3, 11}, {13, 21}, {30, 23}, {29, 14}, {20, 28}, {1, 9}
    };
    constant ushort idleCell = 27, tiredCell = 19, sleepA = 2, sleepB = 10;

    static float2 keepInside(float2 p, constant Params& u, float m) {
        float best = 1e30; float2 out = p;
        for (uint i = 0; i < u.screenCount; i++) {
            float4 s = u.screens[i];
            float2 lo = s.xy + m, hi = s.zw - m;
            float2 q = clamp(p, lo, hi);
            float d = distance_squared(p, q);
            if (d < best) { best = d; out = q; }
        }
        return out;
    }

    kernel void crowd_step(const device Cat* src [[buffer(0)]], device Cat* dst [[buffer(1)]],
                           constant Params& u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        if (i >= u.count) return;
        Cat c = src[i];
        uint n = i + 50;                       // continues the first 50 cats' sunflower
        float2 target;
        if (u.mode == 1) {                     // conga: follow the one in front
            target = i == 0 ? u.leader : src[i - 1].pos;
        } else if (u.mode == 2) {              // free roam: somewhere new every 20-40 s
            uint epoch = (u.tick + hash(c.seed) % 300) / 300;
            uint k = hash(c.seed * 7919u + epoch);
            float4 s = u.screens[k % max(u.screenCount, 1u)];
            target = s.xy + (s.zw - s.xy) * float2(unit(k + 1), unit(k + 2));
        } else {                               // swarm: a disc around the cursor
            float r = sqrt((float(n) + 0.5) / float(u.count + 50));
            float a = float(n) * 2.399963;
            target = u.cursor + r * u.spread * float2(cos(a), sin(a));
        }
        target = keepInside(target, u, u.halfSize);

        float2 d = target - c.pos;
        float dist = length(d);
        float stop = u.halfSize + 32.0;
        float speed = u.speed * (0.8 + 0.4 * unit(c.seed * 31u));
        if (u.paused != 0) {
            c.cell = (u.tick / 4) % 2 == 0 ? sleepA : sleepB;
        } else if (dist < max(stop, speed)) {
            c.idle = min(c.idle + 1, 60000);
            uint nap = 40 + hash(c.seed) % 120;
            if (c.idle < nap) c.cell = idleCell;
            else if (c.idle < nap + 8) c.cell = tiredCell;
            else c.cell = ((c.idle - nap) / 4) % 2 == 0 ? sleepA : sleepB;
        } else {
            c.idle = 0;
            float2 dir = d / dist;
            int ns = dir.y > 0.5 ? 0 : dir.y < -0.5 ? 2 : 1;      // N / - / S
            int ew = dir.x > 0.5 ? 0 : dir.x < -0.5 ? 2 : 1;      // E / - / W
            const int pick[3][3] = { {1, 0, 7}, {2, 0, 6}, {3, 4, 5} };
            int k = pick[ns][ew];
            c.cell = runCells[k][(u.tick + c.seed) % 2];
            c.pos = keepInside(c.pos + dir * speed, u, u.halfSize);
        }
        dst[i] = c;
    }

    struct VOut { float4 pos [[position]]; float2 uv; uint coat [[flat]]; };

    vertex VOut crowd_vertex(uint vid [[vertex_id]], const device Cat* cats [[buffer(0)]],
                             constant DrawParams& p [[buffer(1)]]) {
        Cat c = cats[vid / 6];
        uint k = vid % 6;
        float2 corner = float2(k == 1 || k == 3 || k == 4 ? 1.0 : 0.0, k == 2 || k == 4 || k == 5 ? 1.0 : 0.0);
        VOut o;
        float2 center = floor(c.pos) - p.origin;
        if (any(center < -p.halfSize) || any(center > p.size + p.halfSize)) {
            o.pos = float4(-2, -2, 0, 1); o.uv = 0; o.coat = 0;
            return o;
        }
        float2 local = center + (corner * 2.0 - 1.0) * p.halfSize;
        o.pos = float4(local / p.size * 2.0 - 1.0, 0, 1);
        float col = float(c.cell % 8), row = float(c.cell / 8);
        o.uv = float2((col + corner.x) * 32.0 / 256.0, (row + 1.0 - corner.y) * 32.0 / 128.0);
        o.coat = hash(c.seed * 13u) % max(p.coats, 1u);
        return o;
    }

    fragment float4 crowd_fragment(VOut in [[stage_in]], texture2d_array<float> atlas [[texture(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        float4 c = atlas.sample(nearest, in.uv, in.coat);
        if (c.a < 0.1) discard_fragment();
        return c;
    }
    """
}

/// A full-display, click-through overlay that the crowd is drawn into.
final class CrowdWindow: NSPanel {
    let metalLayer = CAMetalLayer()

    init(frame: CGRect, device: MTLDevice) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)   // under the real cats
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        let scale = NSScreen.screens.first { $0.frame == frame }?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = view.bounds
        metalLayer.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        view.layer = metalLayer
        contentView = view
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
