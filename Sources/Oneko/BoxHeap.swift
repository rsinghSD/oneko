import AppKit
import Metal
import QuartzCore

/// Every cardboard box past the first 50: a heap in the bottom-right corner of each display,
/// drawn by the graphics chip. The heap never moves, so it's drawn once (one draw call per
/// display) and only drawn again when the count, the size or the displays change. That's
/// what lets it go up to a million toys. Click-through; cats can still nap in the top ones.
final class BoxHeap {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var buffer: MTLBuffer?
    private var count = 0
    private var scale: CGFloat = 1
    private var windows: [CrowdWindow] = []
    private var frames: [CGRect] = []
    private var hidden: Set<Int> = []
    private var visible = true

    private struct DrawParams { var origin: SIMD2<Float>; var size: SIMD2<Float>; var halfSize: Float; var pad: Float = 0 }

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        guard let device else { return }
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "heap_vertex")
            d.fragmentFunction = lib.makeFunction(name: "heap_fragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            texture = Self.makeTexture(PixelArt.box.image, device: device)
        } catch {
            FileHandle.standardError.write("Oneko: box heap unavailable: \(error)\n".data(using: .utf8)!)
        }
    }

    var isAvailable: Bool { pipeline != nil && texture != nil }

    /// Lay out `positions` (box centres, global y-up) and draw them.
    func show(_ positions: [SIMD2<Float>], scale s: CGFloat, screens: [CGRect]) {
        scale = s
        count = positions.count
        guard let device, count > 0 else { stop(); return }
        buffer = positions.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        syncWindows(screens)
        redraw()
    }

    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        if on { redraw() } else { for w in windows { w.orderOut(nil) } }
    }

    /// Hide the heap on displays with a full-screen app in front.
    func setCovered(_ covered: [CGRect]) {
        let now = Set(frames.indices.filter { covered.contains(frames[$0]) })
        guard now != hidden else { return }
        hidden = now
        redraw()
    }

    func stop() {
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        frames = []
        buffer = nil
        count = 0
    }

    private func syncWindows(_ now: [CGRect]) {
        guard now != frames, let device else { return }
        for w in windows { w.orderOut(nil); w.close() }
        windows = now.map {
            let w = CrowdWindow(frame: $0, device: device)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 2)   // under every cat
            return w
        }
        frames = now
        hidden = []
    }

    private func redraw() {
        guard visible, isAvailable, count > 0, let queue, let cb = queue.makeCommandBuffer() else { return }
        for (i, (w, f)) in zip(windows, frames).enumerated() {
            if hidden.contains(i) { if w.isVisible { w.orderOut(nil) }; continue }
            if !w.isVisible { w.orderFrontRegardless() }
            guard let drawable = w.metalLayer.nextDrawable() else { continue }
            encodeDraw(cb, into: drawable.texture, frame: f)
            cb.present(drawable)
        }
        cb.commit()
    }

    private func encodeDraw(_ cb: MTLCommandBuffer, into target: MTLTexture, frame f: CGRect) {
        guard let pipeline, let texture, let buffer else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var p = DrawParams(origin: SIMD2(Float(f.minX), Float(f.minY)), size: SIMD2(Float(f.width), Float(f.height)),
                           halfSize: Float(16 * scale))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count * 6)
        enc.endEncoding()
    }

    /// For `--selftest` and `--heap-png`: draw `positions` offscreen into `frame` with the
    /// real GPU code. BGRA, top row first; nil without Metal.
    func snapshot(_ positions: [SIMD2<Float>], scale s: CGFloat, frame: CGRect) -> [UInt8]? {
        guard let device, let queue, isAvailable, !positions.isEmpty else { return nil }
        scale = s
        count = positions.count
        buffer = positions.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        let w = Int(frame.width), h = Int(frame.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        encodeDraw(cb, into: tex, frame: frame)
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    private static func makeTexture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return t
    }

    // MARK: - Layout

    /// Where heap box `i` of `n` goes: a pyramid in the bottom-right corner of each display
    /// (shared out by width), growing leftwards and upwards. Once a display's heap reaches
    /// most of its width and about half its height, more boxes tumble on top in loose layers.
    /// Box centres, global y-up, in drawing order (later ones on top).
    static func layout(count n: Int, screens: [CGRect], scale s: CGFloat) -> [SIMD2<Float>] {
        guard n > 0, !screens.isEmpty else { return [] }
        let w = 28 * s, h = 13 * s                   // rows stack: each box sits on the front of the ones below
        let total = screens.reduce(0) { $0 + $1.width }
        var shares = screens.map { total > 0 ? Int(CGFloat(n) * $0.width / total) : n / screens.count }
        shares[0] += n - shares.reduce(0, +)
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(n)
        for (f, k) in zip(screens, shares) where k > 0 {
            let maxCols = max(1, Int(f.width * 0.9 / w))
            let maxRows = max(1, Int(f.height * 0.5 / h))
            func capacity(_ c: Int) -> Int { (0..<min(c, maxRows)).reduce(0) { $0 + (c - $1) } }
            var cols = 1
            while cols < maxCols && capacity(cols) < k { cols += 1 }
            let rows = min(cols, maxRows)
            var starts: [Int] = [0]                      // first slot of each row
            for r in 0..<rows { starts.append(starts[r] + cols - r) }
            let layer = starts[rows]
            let right = f.maxX - 8 * s - w / 2
            let floor = f.minY + 15 * s                  // centre of a box standing on the bottom edge
            var row = 0
            for j in 0..<k {
                let l = j / layer, slot = j % layer
                if slot == 0 { row = 0 }
                while slot >= starts[row + 1] { row += 1 }
                var x = right - CGFloat(slot - starts[row]) * w - CGFloat(row) * w / 2
                var y = floor + CGFloat(row) * h
                if l > 0 {                               // a loose layer on top: jumbled a bit
                    var hsh = UInt32(truncatingIfNeeded: j &* 2_654_435_761)
                    hsh ^= hsh >> 13
                    x += (CGFloat(hsh & 0xFF) / 255 - 0.5) * w
                    y += CGFloat((hsh >> 8) & 0x7) * s
                    x = min(max(x, f.minX + w / 2), f.maxX - w / 2)
                }
                out.append(SIMD2(Float(x), Float(y)))
            }
        }
        return out
    }

    // MARK: - GPU

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct DrawParams { float2 origin; float2 size; float halfSize; float pad; };
    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut heap_vertex(uint vid [[vertex_id]], const device float2* boxes [[buffer(0)]],
                            constant DrawParams& p [[buffer(1)]]) {
        float2 center = floor(boxes[vid / 6]) - p.origin;
        uint k = vid % 6;
        float2 corner = float2(k == 1 || k == 3 || k == 4 ? 1.0 : 0.0, k == 2 || k == 4 || k == 5 ? 1.0 : 0.0);
        VOut o;
        if (any(center < -p.halfSize) || any(center > p.size + p.halfSize)) {
            o.pos = float4(-2, -2, 0, 1); o.uv = 0;
            return o;
        }
        float2 local = center + (corner * 2.0 - 1.0) * p.halfSize;
        o.pos = float4(local / p.size * 2.0 - 1.0, 0, 1);
        o.uv = float2(corner.x, 1.0 - corner.y);
        return o;
    }

    fragment float4 heap_fragment(VOut in [[stage_in]], texture2d<float> art [[texture(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        float4 c = art.sample(nearest, in.uv);
        if (c.a < 0.1) discard_fragment();
        return c;
    }
    """
}
