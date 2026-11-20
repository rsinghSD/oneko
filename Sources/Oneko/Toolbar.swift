import AppKit

/// Controls in a non-activating panel must take the very first click.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating Paint toolbox: a native macOS HUD panel with SF Symbol tools, the 16-colour
/// palette, a hint for the current tool, and Clear.
final class ToolbarPanel: NSPanel {
    var onTool: ((PaintTool) -> Void)?
    var onColor: ((RGBA) -> Void)?
    var onClear: (() -> Void)?

    private var toolButtons: [FirstClickButton] = []
    private let swatch = NSView()
    private let hint = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 500),
                   styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Toolbox"
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build()
    }

    override var canBecomeKey: Bool { false }

    private func build() {
        // Tools: two columns, like Paint.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        for t in PaintTool.allCases {
            let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title) ?? NSImage()
            let b = FirstClickButton(image: img, target: self, action: #selector(toolPressed(_:)))
            b.setButtonType(.toggle)
            b.bezelStyle = .smallSquare
            b.tag = t.rawValue
            b.toolTip = t.title
            b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.widthAnchor.constraint(equalToConstant: 46).isActive = true
            b.heightAnchor.constraint(equalToConstant: 32).isActive = true
            toolButtons.append(b)
        }
        for i in stride(from: 0, to: toolButtons.count, by: 2) {
            grid.addRow(with: [toolButtons[i], i + 1 < toolButtons.count ? toolButtons[i + 1] : NSGridCell.emptyContentView])
        }

        // Current colour + palette.
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        swatch.widthAnchor.constraint(equalToConstant: 96).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let palette = NSGridView(numberOfColumns: 8, rows: 0)
        palette.rowSpacing = 2
        palette.columnSpacing = 2
        var row: [NSView] = []
        for (i, c) in PaintTool.palette.enumerated() {
            let b = FirstClickButton(title: "", target: self, action: #selector(colorPressed(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.nsColor.cgColor
            b.layer?.borderWidth = 0.5
            b.layer?.borderColor = NSColor.gray.cgColor
            b.tag = i
            b.widthAnchor.constraint(equalToConstant: 10).isActive = true
            b.heightAnchor.constraint(equalToConstant: 10).isActive = true
            row.append(b)
            if row.count == 8 { palette.addRow(with: row); row = [] }
        }

        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 100
        hint.widthAnchor.constraint(equalToConstant: 100).isActive = true
        hint.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let clear = FirstClickButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear drawings") ?? NSImage(),
                                     target: self, action: #selector(clearPressed))
        clear.title = " Clear"
        clear.imagePosition = .imageLeading
        clear.controlSize = .small
        clear.bezelStyle = .rounded
        clear.toolTip = "Clear all drawings"

        let stack = NSStackView(views: [grid, swatch, palette, hint, clear])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        stack.setCustomSpacing(10, after: grid)
        stack.setCustomSpacing(10, after: palette)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    func setTool(_ t: PaintTool) {
        for b in toolButtons {
            let on = b.tag == t.rawValue
            b.state = on ? .on : .off
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor : nil
            b.contentTintColor = on ? .white : nil
        }
        hint.stringValue = t.title
    }

    func setColor(_ c: RGBA) {
        swatch.layer?.backgroundColor = c.nsColor.cgColor
    }

    @objc private func toolPressed(_ sender: NSButton) {
        onTool?(PaintTool(rawValue: sender.tag) ?? .pointer)
    }

    @objc private func colorPressed(_ sender: NSButton) {
        onColor?(PaintTool.palette[sender.tag])
    }

    @objc private func clearPressed() { onClear?() }
}
