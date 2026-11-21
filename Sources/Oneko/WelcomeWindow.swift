import AppKit

/// "How to Play": shown once on first launch (and from the menu), so nobody has to guess
/// that a sleeping cat wakes up with a double-click.
final class WelcomeWindow: NSPanel {
    static let tips: [(symbol: String, title: String, text: String)] = [
        ("hand.point.up.left", "Pet", "Click the cat and a heart pops up."),
        ("cursorarrow.click.2", "Stay and wake", "Double-click and it sits down and sleeps right there. Double-click a sleeping cat to wake it up and it chases you again."),
        ("hand.draw", "Pick up and yeet", "Drag the cat around, then let go mid-swing to throw it."),
        ("dock.rectangle", "Park it", "Drop it on the Dock or on a window and it stays there and dozes off. Double-click it (or pick it up) to get it chasing again."),
        ("paperclip", "Clip it", "Right-click to clip it in mid-air. Right-click again to let it drop."),
        ("menubar.rectangle", "Everything else", "Toys, more cats, coats and hats live in the menu bar (the little cat face) and in Settings."),
    ]

    var onClose: (() -> Void)?

    init(icon: CGImage?) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating

        let image = NSImageView()
        if let icon { image.image = NSImage(cgImage: icon, size: NSSize(width: 64, height: 64)) }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.magnificationFilter = .nearest
        image.widthAnchor.constraint(equalToConstant: 64).isActive = true
        image.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Meet Oneko")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let sub = NSTextField(labelWithString: "A cat that chases your cursor. Here's how to play.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        let rows = NSStackView(views: Self.tips.map(Self.tipRow))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12

        let go = NSButton(title: "Let's Play", target: nil, action: #selector(NSWindow.performClose(_:)))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        go.controlSize = .large

        let stack = NSStackView(views: [image, title, sub, rows, go])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(18, after: sub)
        stack.setCustomSpacing(20, after: rows)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 22, right: 28)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    private static func tipRow(_ tip: (symbol: String, title: String, text: String)) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: tip.symbol, accessibilityDescription: tip.title)
            ?? NSImage(systemSymbolName: "pawprint", accessibilityDescription: tip.title)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let s = NSMutableAttributedString(string: tip.title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: tip.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: s)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 320
        label.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let row = NSStackView(views: [icon, label])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        super.close()
        onClose?()
    }
}

/// A little bubble over a sleeping cat: "Double-click to wake".
final class HintWindow: OverlayPanel {
    private let label = NSTextField(labelWithString: "Double-click to wake")

    override init() {
        super.init()
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        bubble.layer?.cornerRadius = 9
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 18, height: 20)
        bubble.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: 9, y: (size.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        bubble.addSubview(label)
        mouseView.addSubview(bubble)
        setContentSize(size)
    }

    /// Centred just above `top` (global, y-up).
    func show(above top: CGPoint) {
        let o = NSPoint(x: (top.x - frame.width / 2).rounded(), y: (top.y + 4).rounded())
        if frame.origin != o { setFrameOrigin(o) }
        if !isVisible { orderFrontRegardless() }
    }
}
