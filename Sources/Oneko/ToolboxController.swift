import AppKit

/// What the toolbox needs from the app.
protocol ToolboxHost: AnyObject {
    var catPlay: Playground { get }
    var catFillColor: RGBA { get }
    func paintCat(_ c: RGBA)
    func magnifyCat(_ giant: Bool)
    func withPlay(_ f: (inout Playground) -> Void)
    func toolboxToolChanged()
}

extension RGBA {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// Toolbox mode: the Paint tools and the drawings on screen, for playing with Neko.
final class ToolboxController {
    weak var host: ToolboxHost?
    let toolbar = ToolbarPanel()
    private(set) var tool: PaintTool = .pointer
    private(set) var color = RGBA(r: 0, g: 0, b: 0)
    private(set) var drawings: [Drawing] = []

    private var canvases: [CanvasWindow] = []
    private var nextID = -1

    // In-progress gestures
    private var start: CGPoint?
    private var stroke: [CGPoint] = []
    private var preview: Drawing?
    private var polygon: [CGPoint] = []
    private var curveLine: (CGPoint, CGPoint)?
    private var spray: Drawing?
    private var lastSpray: Double = 0
    private var textPanel: TextEntryPanel?

    // Selection (marching ants)
    private var selection: [CGPoint]?
    private var selecting = false
    private var captured = false
    private var lastDrag: CGPoint?
    private var antsPhase: CGFloat = 0

    init(host: ToolboxHost) {
        self.host = host
        toolbar.onTool = { [weak self] in self?.setTool($0) }
        toolbar.onColor = { [weak self] in self?.setColor($0) }
        toolbar.onClear = { [weak self] in
            self?.drawings.removeAll()
            self?.host?.withPlay { $0.groundChanged() }
            self?.redraw()
        }
        toolbar.setTool(.pointer)
        toolbar.setColor(color)
        rebuildCanvases()
    }

    func show() {
        for c in canvases { c.orderFrontRegardless() }
        if let main = NSScreen.main {
            let v = main.visibleFrame
            toolbar.setFrameOrigin(NSPoint(x: v.minX + 12, y: v.midY - toolbar.frame.height / 2))
        }
        toolbar.orderFrontRegardless()
    }

    func hide() {
        releaseSelection()
        textPanel?.close()
        for c in canvases { c.close() }
        canvases = []
        toolbar.orderOut(nil)
    }

    func rebuildCanvases() {
        let wasVisible = canvases.first?.isVisible ?? false
        for c in canvases { c.orderOut(nil) }
        canvases = NSScreen.screens.map { CanvasWindow(screen: $0, controller: self) }
        applyToolToCanvases()
        if wasVisible { for c in canvases { c.orderFrontRegardless() } }
    }

    // MARK: - Tools

    func setTool(_ t: PaintTool) {
        if t != .select && t != .freeSelect { releaseSelection() }
        if t != .polygon { polygon = [] }
        if t != .curve { curveLine = nil }
        preview = nil
        tool = t
        toolbar.setTool(t)
        applyToolToCanvases()
        redraw()
        host?.toolboxToolChanged()
    }

    private func setColor(_ c: RGBA) {
        color = c
        toolbar.setColor(c)
    }

    private func applyToolToCanvases() {
        for c in canvases { c.ignoresMouseEvents = tool == .pointer }   // pointer: clicks go to the desktop
    }

    private func newID() -> Int {
        nextID -= 1
        return nextID
    }

    private func catHit(_ p: CGPoint, slop: CGFloat = 4) -> Bool {
        host?.catPlay.catContains(p, slop: slop) ?? false
    }

    // MARK: - Mouse (from any canvas, global coordinates)

    func mouseDown(_ p: CGPoint, clicks: Int) {
        switch tool {
        case .pointer:
            break
        case .eraser:
            eraseAt(p)
        case .fill:
            if catHit(p) {
                host?.paintCat(color)
                host?.withPlay { $0.painted() }
            } else if let i = drawings.lastIndex(where: { $0.contains(p) }) {
                drawings[i].fill = color
            }
        case .pickColor:
            if catHit(p), let c = host?.catFillColor {
                setColor(c)
            } else if let d = drawings.last(where: { $0.contains(p) || $0.isNear(p, within: 6) }) {
                setColor(d.fill ?? d.color)
            }
        case .magnifier:
            if catHit(p, slop: 8) { host?.magnifyCat(true) }
        case .pencil, .brush:
            stroke = [p]
            preview = Drawing(id: 0, kind: .stroke, points: [p], closed: false, color: color, width: tool == .pencil ? 2 : 8)
        case .airbrush:
            spray = Drawing(id: newID(), kind: .spray, points: [], closed: false, color: color, width: 2)
            sprayAt(p)
        case .text:
            openText(at: p)
        case .line, .rectangle, .ellipse, .roundedRect:
            start = p
        case .curve:
            if curveLine == nil { start = p } else { bend(toward: p) }
        case .polygon:
            if polygon.isEmpty {
                polygon = [p]
            } else if clicks >= 2 || (polygon.count >= 3 && hypot(p.x - polygon[0].x, p.y - polygon[0].y) < 10) {
                if polygon.count >= 3 {
                    commit(Drawing(id: 0, kind: .polygon, points: polygon, closed: true, color: color))
                }
                polygon = []
            } else {
                polygon.append(p)
            }
        case .select, .freeSelect:
            if let sel = selection, captured, Geometry.polygon(sel, contains: p) {
                lastDrag = p                       // drag the selection (and Neko in it)
            } else {
                releaseSelection()
                selecting = true
                start = p
                stroke = [p]
            }
        }
        redraw()
    }

    func mouseDragged(_ p: CGPoint) {
        switch tool {
        case .eraser:
            eraseAt(p)
        case .pencil, .brush:
            if let l = stroke.last, hypot(p.x - l.x, p.y - l.y) >= 2 { stroke.append(p) }
            preview?.points = stroke
        case .airbrush:
            sprayAt(p)
        case .line:
            if let a = start { preview = Drawing(id: 0, kind: .line, points: [a, p], closed: false, color: color) }
        case .rectangle:
            if let a = start { preview = Drawing(id: 0, kind: .rectangle, points: Geometry.rectangle(Geometry.rect(a, p)), closed: true, color: color) }
        case .ellipse:
            if let a = start { preview = Drawing(id: 0, kind: .ellipse, points: Geometry.ellipse(Geometry.rect(a, p)), closed: true, color: color) }
        case .roundedRect:
            if let a = start { preview = Drawing(id: 0, kind: .roundedRect, points: Geometry.roundedRect(Geometry.rect(a, p)), closed: true, color: color) }
        case .curve:
            if curveLine != nil {
                bend(toward: p)
            } else if let a = start {
                preview = Drawing(id: 0, kind: .line, points: [a, p], closed: false, color: color)
            }
        case .select, .freeSelect:
            if let last = lastDrag, captured, let sel = selection {
                let d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
                selection = sel.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
                host?.withPlay { play in
                    play.moveCaptured(to: CGPoint(x: play.cat.position.x + d.dx, y: play.cat.position.y + d.dy))
                }
                lastDrag = p
            } else if selecting, let a = start {
                if tool == .select {
                    selection = Geometry.rectangle(Geometry.rect(a, p))
                } else {
                    stroke.append(p)
                    selection = stroke
                }
            }
        default:
            break
        }
        redraw()
    }

    func mouseUp(_ p: CGPoint) {
        switch tool {
        case .pencil, .brush:
            if stroke.count == 1 { stroke.append(CGPoint(x: p.x + 0.5, y: p.y)) }
            if var d = preview { d.points = stroke; commit(d) }
        case .airbrush:
            if let s = spray, !s.points.isEmpty { drawings.append(s) }
            spray = nil
        case .line, .rectangle, .ellipse, .roundedRect:
            if let d = preview, let a = start, hypot(p.x - a.x, p.y - a.y) > 3 { commit(d) }
        case .curve:
            if let line = curveLine {
                if let d = preview, d.kind == .curve { commit(d) } else {
                    commit(Drawing(id: 0, kind: .line, points: [line.0, line.1], closed: false, color: color))
                }
                curveLine = nil
            } else if let a = start, hypot(p.x - a.x, p.y - a.y) > 3 {
                curveLine = (a, p)       // now drag again to bend it
                preview = Drawing(id: 0, kind: .line, points: [a, p], closed: false, color: color)
                start = nil
                redraw()
                return
            }
        case .select, .freeSelect:
            if lastDrag != nil {
                lastDrag = nil
            } else if selecting {
                selecting = false
                finishSelection()
            }
        default:
            break
        }
        start = nil
        stroke = []
        if tool != .curve { preview = nil }
        redraw()
    }

    func rightMouseDown(_ p: CGPoint) {
        switch tool {
        case .magnifier: host?.magnifyCat(false)
        case .polygon: polygon = []
        case .curve: curveLine = nil; preview = nil
        case .select, .freeSelect: releaseSelection()
        default: break
        }
        redraw()
    }

    // MARK: - Tool actions

    private func commit(_ d: Drawing) {
        var d = d
        d.id = newID()
        drawings.append(d)
        preview = nil
        host?.withPlay { $0.drawingAdded(d); $0.groundChanged() }
    }

    private func bend(toward c: CGPoint) {
        guard let (a, b) = curveLine else { return }
        preview = Drawing(id: 0, kind: .curve, points: Geometry.curve(a, b, control: c), closed: false, color: color)
    }

    private func eraseAt(_ p: CGPoint) {
        let before = drawings.count
        drawings.removeAll { $0.isNear(p, within: 10) }
        if drawings.count != before {
            redraw()
            host?.withPlay { $0.groundChanged() }
        }
        host?.withPlay { $0.erase(at: p, radius: 10) }
    }

    private func sprayAt(_ p: CGPoint) {
        guard spray != nil else { return }
        for _ in 0..<10 {
            let a = CGFloat.random(in: 0..<(2 * .pi)), r = 18 * CGFloat.random(in: 0...1).squareRoot()
            spray?.points.append(CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r))
        }
        let now = CACurrentMediaTime()
        if catHit(p, slop: 18), now - lastSpray > 0.15 {
            lastSpray = now
            host?.withPlay { $0.sprayed() }
        }
    }

    private func finishSelection() {
        guard let sel = selection, sel.count >= 3, let pos = host?.catPlay.cat.position,
              Geometry.polygon(sel, contains: pos)
        else { selection = nil; return }
        captured = true
        host?.withPlay { $0.capture() }
        if host?.catPlay.mode != .captured { captured = false; selection = nil }
    }

    private func releaseSelection() {
        if captured { host?.withPlay { $0.releaseCaptured() } }
        captured = false
        selecting = false
        lastDrag = nil
        selection = nil
    }

    private func openText(at p: CGPoint) {
        textPanel?.close()
        let panel = TextEntryPanel(at: p)
        panel.onCommit = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let font = NSFont.boldSystemFont(ofSize: 28)
            let size = (text as NSString).size(withAttributes: [.font: font])
            let r = CGRect(x: p.x, y: p.y - size.height / 2, width: size.width, height: size.height)
            commit(Drawing(id: 0, kind: .text(text), points: Geometry.rectangle(r), closed: true, color: color, width: 1))
            redraw()
        }
        textPanel = panel
        panel.present()
    }

    /// 10 Hz from the app.
    func tick(now: Double) {
        if captured, host?.catPlay.mode != .captured {   // it got away (or was dragged off)
            captured = false
            selection = nil
            redraw()
        }
        if selection != nil {   // marching ants
            antsPhase += 2
            redraw()
        }
    }

    // MARK: - Drawing (Core Animation layers: no full-screen bitmaps)

    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in canvases { c.canvas.sync(self) }
        CATransaction.commit()
    }

    /// What every canvas shows, in global coordinates.
    struct Scene {
        var drawings: [Drawing]
        var live: [Drawing]          // preview + airbrush in progress
        var polygon: [CGPoint]
        var polygonColor: RGBA
        var selection: [CGPoint]?
        var antsPhase: CGFloat
        var catchClicks: Bool
    }

    var scene: Scene {
        Scene(drawings: drawings, live: [preview, spray].compactMap { $0 }, polygon: polygon,
              polygonColor: color, selection: selection, antsPhase: antsPhase, catchClicks: tool != .pointer)
    }
}

// MARK: - Canvas windows

final class CanvasView: NSView {
    weak var controller: ToolboxController?
    private let root = CALayer()
    private var committed: [Int: (Drawing, CALayer)] = [:]
    private let live = CALayer()
    private let polygonLayer = CAShapeLayer()
    private let marqueeLight = CAShapeLayer()
    private let marqueeDark = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root            // layer-hosting: shapes are composited by the GPU, no bitmap
        wantsLayer = true
        root.actions = ["backgroundColor": NSNull(), "sublayers": NSNull()]
        for l in [live, polygonLayer, marqueeLight, marqueeDark] {
            l.actions = ["path": NSNull(), "contents": NSNull()]
            root.addSublayer(l)
        }
        polygonLayer.fillColor = nil
        polygonLayer.lineWidth = 3
        marqueeLight.fillColor = nil
        marqueeLight.strokeColor = NSColor.white.cgColor
        marqueeLight.lineWidth = 1.5
        marqueeDark.fillColor = nil
        marqueeDark.strokeColor = NSColor.black.cgColor
        marqueeDark.lineWidth = 1.5
        marqueeDark.lineDashPattern = [6, 4]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Bring the layers in line with the scene; only changed drawings are rebuilt.
    func sync(_ controller: ToolboxController) {
        guard let o = window?.frame.origin else { return }
        let scene = controller.scene
        let scale = window?.backingScaleFactor ?? 2
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - o.x, y: p.y - o.y) }

        // Nearly invisible tint: lets the canvas catch every click while a tool is active.
        root.backgroundColor = scene.catchClicks ? NSColor(white: 0, alpha: 0.012).cgColor : nil

        var keep = Set<Int>()
        for d in scene.drawings {
            keep.insert(d.id)
            if let (old, l) = committed[d.id], old == d { _ = l; continue }
            committed[d.id]?.1.removeFromSuperlayer()
            let l = Self.layer(for: d, local: local, scale: scale)
            root.insertSublayer(l, below: live)
            committed[d.id] = (d, l)
        }
        for (id, entry) in committed where !keep.contains(id) {
            entry.1.removeFromSuperlayer()
            committed[id] = nil
        }

        live.sublayers = scene.live.map { Self.layer(for: $0, local: local, scale: scale) }

        if scene.polygon.isEmpty {
            polygonLayer.path = nil
        } else {
            let path = CGMutablePath()
            path.move(to: local(scene.polygon[0]))
            for p in scene.polygon.dropFirst() { path.addLine(to: local(p)) }
            for p in scene.polygon { path.addEllipse(in: CGRect(x: local(p).x - 3, y: local(p).y - 3, width: 6, height: 6)) }
            polygonLayer.path = path
            polygonLayer.strokeColor = scene.polygonColor.nsColor.cgColor
        }

        if let sel = scene.selection, sel.count >= 2 {
            let path = CGMutablePath()
            path.addLines(between: sel.map(local))
            path.closeSubpath()
            marqueeLight.path = path
            marqueeDark.path = path
            marqueeDark.lineDashPhase = scene.antsPhase   // marching ants
        } else {
            marqueeLight.path = nil
            marqueeDark.path = nil
        }
    }

    private static func layer(for d: Drawing, local: (CGPoint) -> CGPoint, scale: CGFloat) -> CALayer {
        switch d.kind {
        case .text(let s):
            let t = CATextLayer()
            t.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            t.string = s
            t.font = NSFont.boldSystemFont(ofSize: 28)
            t.fontSize = 28
            t.foregroundColor = d.color.nsColor.cgColor
            t.backgroundColor = d.fill?.nsColor.cgColor
            t.contentsScale = scale
            let pts = d.points.map(local)
            let minX = pts.map(\.x).min() ?? 0, minY = pts.map(\.y).min() ?? 0
            let maxX = pts.map(\.x).max() ?? 0, maxY = pts.map(\.y).max() ?? 0
            t.frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            return t
        case .spray:
            let l = CAShapeLayer()
            let path = CGMutablePath()
            for p in d.points { let q = local(p); path.addEllipse(in: CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2)) }
            l.path = path
            l.fillColor = d.color.nsColor.cgColor
            return l
        default:
            let l = CAShapeLayer()
            let path = CGMutablePath()
            path.addLines(between: d.points.map(local))
            if d.closed { path.closeSubpath() }
            l.path = path
            l.strokeColor = d.color.nsColor.cgColor
            l.fillColor = d.fill?.nsColor.cgColor
            l.lineWidth = d.width
            l.lineCap = .round
            l.lineJoin = .round
            return l
        }
    }
    override func mouseDown(with e: NSEvent) { controller?.mouseDown(NSEvent.mouseLocation, clicks: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseDragged(NSEvent.mouseLocation) }
    override func mouseUp(with e: NSEvent) { controller?.mouseUp(NSEvent.mouseLocation) }
    override func rightMouseDown(with e: NSEvent) { controller?.rightMouseDown(NSEvent.mouseLocation) }
}

/// A transparent drawing surface over one display (leaving its menu bar alone), under the cat.
final class CanvasWindow: NSPanel {
    let canvas = CanvasView(frame: .zero)

    init(screen: NSScreen, controller: ToolboxController) {
        var f = screen.frame
        f.size.height = screen.visibleFrame.maxY - f.minY
        super.init(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        canvas.controller = controller
        contentView = canvas
        setFrame(f, display: false)
        canvas.sync(controller)
    }

    override var canBecomeKey: Bool { false }
}

/// The Text tool's little input box. Return places the text; Escape cancels.
final class TextEntryPanel: NSPanel, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private let field = NSTextField()

    init(at p: CGPoint) {
        super.init(contentRect: NSRect(x: p.x, y: p.y - 14, width: 220, height: 28),
                   styleMask: [.titled, .utilityWindow, .hudWindow, .closable], backing: .buffered, defer: false)
        title = "Text: type, then Return"
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        field.placeholderString = "Hello, Neko"
        field.font = .boldSystemFont(ofSize: 16)
        field.target = self
        field.action = #selector(commit)
        field.delegate = self
        contentView = field
    }

    override var canBecomeKey: Bool { true }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    @objc private func commit() {
        let text = field.stringValue
        close()
        onCommit?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
}
