import AppKit

/// "Paint your own coat": outline, fill and accent colours plus a pattern, with a live
/// preview of a few frames. Saving turns it into the "My Coat" coat.
final class CoatPainter: NSPanel {
    var onApply: ((Skin) -> Void)?

    private let base: SpriteSheet
    private let outlineWell = NSColorWell()
    private let fillWell = NSColorWell()
    private let accentWell = NSColorWell()
    private let pattern = NSPopUpButton()
    private let preview = NSImageView()

    init(base: SpriteSheet, start: Skin) {
        self.base = base
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Paint Your Coat"
        isReleasedWhenClosed = false
        level = .floating

        outlineWell.color = start.outline.nsColor
        fillWell.color = start.fill.nsColor
        accentWell.color = (start.accent ?? start.fill).nsColor
        for w in [outlineWell, fillWell, accentWell] {
            w.target = self
            w.action = #selector(changed)
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        pattern.addItems(withTitles: CoatPattern.allCases.map(\.title))
        pattern.selectItem(at: CoatPattern.allCases.firstIndex(of: start.pattern) ?? 0)
        pattern.target = self
        pattern.action = #selector(changed)

        preview.imageScaling = .scaleNone
        preview.widthAnchor.constraint(equalToConstant: 384).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true

        func labeled(_ text: String, _ v: NSView) -> NSStackView {
            let s = NSStackView(views: [NSTextField(labelWithString: text), v])
            s.orientation = .vertical
            s.alignment = .centerX
            s.spacing = 4
            return s
        }
        let controls = NSStackView(views: [labeled("Outline", outlineWell), labeled("Fill", fillWell),
                                           labeled("Accent", accentWell), labeled("Pattern", pattern)])
        controls.spacing = 18
        let use = NSButton(title: "Use This Coat", target: self, action: #selector(apply))
        use.keyEquivalent = "\r"
        use.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, use])
        let stack = NSStackView(views: [preview, controls, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        contentView = stack
        setContentSize(stack.fittingSize)
        changed()
    }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private var skin: Skin {
        func rgba(_ c: NSColor) -> RGBA {
            let s = c.usingColorSpace(.sRGB) ?? c
            return RGBA(r: UInt8(max(0, min(255, s.redComponent * 255))), g: UInt8(max(0, min(255, s.greenComponent * 255))),
                        b: UInt8(max(0, min(255, s.blueComponent * 255))))
        }
        return Skin(id: Skin.paintedID, title: "My Coat", outline: rgba(outlineWell.color), fill: rgba(fillWell.color),
                    accent: rgba(accentWell.color), pattern: CoatPattern.allCases[max(0, pattern.indexOfSelectedItem)])
    }

    /// Redraw the preview: sitting, running, sleeping, alert, at 3×.
    @objc private func changed() {
        let sheet = base.recolored(skin)
        let z = 3, frames: [(SpriteName, Int)] = [(.idle, 0), (.E, 0), (.sleeping, 0), (.alert, 0)]
        guard let ctx = CGContext(data: nil, width: 32 * z * frames.count, height: 32 * z, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .none
        for (i, f) in frames.enumerated() {
            if let img = sheet.image(for: f.0, frame: f.1) {
                ctx.draw(img, in: CGRect(x: i * 32 * z, y: 0, width: 32 * z, height: 32 * z))
            }
        }
        if let cg = ctx.makeImage() { preview.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
    }

    @objc private func apply() {
        NSColorPanel.shared.close()
        onApply?(skin)
        close()
    }

    @objc private func cancelPressed() {
        NSColorPanel.shared.close()
        close()
    }
}
