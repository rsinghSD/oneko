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

    static func tipRow(_ tip: (symbol: String, title: String, text: String)) -> NSView {
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

/// "What's New": shown once, on the first launch after an update (and from the menu).
final class WhatsNewWindow: NSPanel {
    /// The newest release first. Add an entry for every release.
    static let releases: [(version: String, items: [(symbol: String, title: String, text: String)])] = [
        ("0.6.5", [
            ("figure.climbing", "Off exploring", "Leave the mouse alone and a cat may climb up a window and stroll along its title bar, walk round the inside of a window's border, or run along the menu bar, scratching window edges on the way. Move the mouse and it comes running."),
            ("moon.zzz", "Less sleepy", "Cats nap less by default. Put one on a window, the Dock or the menu bar, or drop it inside a window, and it runs up and down there instead of dozing off. Pick how sleepy they are under Sleepiness in the menu bar menu."),
            ("dock.rectangle", "The Dock, your way", "Cats no longer get launched out of the Dock when they follow your cursor into it. They stand on top of it, or walk on the ground in front of it (Settings › Behavior)."),
            ("circle.grid.cross", "Cats bump into each other", "They don't walk through each other any more, and a cat you throw into another knocks it flying. Want it wilder? Settings › Cats › Bumping: Crazy, or Total Chaos (pinball)."),
            ("person.crop.square", "Names and sizes for each cat", "Name every cat, and give the first 10 their own size (1×, 2× or 3×) under Settings › Cats › Names and Sizes."),
            ("fork.knife", "Dinner's served", "Click a bowl (or Toys › Feed the Cats) and every cat comes to eat, hungry or not. A fish bobs over a cat while it eats, and the bowl is cleared away when they're done. The bone is a fish bone now, and catnip runs twice as fast."),
            ("wrench.and.screwdriver", "Fixes", "A real meow. Trips to the Touch Bar no longer leave a box on the desktop, cats lift out of the big box properly, and the Settings counts no longer lag behind."),
        ]),
        // 0.6.0 is the first release since 0.5.5, so it sums up 0.5.7 and 0.5.8 too (only the
        // newest entry is shown).
        ("0.6.0", [
            ("cloud.bolt.rain", "Your real weather", "Rain, thunderstorms (with thunder), snow or sunshine from where you are, falling behind your windows. Or pick seasonal weather, or none."),
            ("figure.2", "Every toy for every cat", "Any cat naps in any box, fetches any bone and chases any yarn. Up to 50 bones and balls of yarn, and up to a million boxes. Boxes stack."),
            ("heart.circle", "Cats play together", "They groom, play-fight and chase each other. The big box fits four, and they nap in it until you lift them out."),
            ("fork.knife", "Hungry cats", "Every 20–40 minutes they head for a food bowl. Click a bowl to fill it up."),
            ("tag", "Names and stats", "Hover a cat for its name and stats, and ⌥-click it to rename it. Oneko now checks for updates once a day."),
            ("gauge.with.dots.needle.67percent", "About ten times lighter", "Thousands of cats cost a fraction of the CPU, and cats no longer glitch where two displays meet."),
        ]),
        ("0.5.8", [
            ("figure.2", "Every toy for every cat", "The closest cat fetches a thrown bone, any cat chases the yarn, and the whole gang goes after the laser. Up to 50 bones and 50 balls of yarn."),
            ("fork.knife", "Food bowls", "Cats get hungry: click a bowl to fill it."),
            ("heart.circle", "Cats play together", "Cats sitting side by side groom each other, play-fight or chase each other. One big box fits four of them."),
            ("square.stack.3d.up", "Stack the boxes", "Boxes pile up on each other, and in Toolbox mode cats hop up them. Crowd cats nap in the box heap."),
            ("snowflake", "Names, stats and weather", "Hover a cat for its name and stats. Your real weather falls from the top of the screen: rain, thunder, snow or sun. Oneko now checks for updates once a day."),
        ]),
        ("0.5.7", [
            ("shippingbox", "Boxes for everyone", "Every cat naps in any free box, not just the first cat. One cat per box."),
            ("square.stack.3d.up", "Up to a million boxes", "Set how many under Settings › Toys. The first 50 are real boxes you can carry, throw and shut; the rest pile up in the corner of the screen."),
            ("dock.rectangle", "Dock bonk", "If your Dock hides itself, it bonks cats and toys into the air when it pops up. Turn it off under Settings › Behavior."),
            ("rectangle.bottomhalf.inset.filled", "Touch Bar trips for every cat", "Slam any cat down into the Touch Bar, and flick any cat on the bar back up to the desktop."),
            ("gauge.with.dots.needle.33percent", "Lighter", "Lots of cats cost less: idle ones skip the 60 fps work, and a sleeping crowd barely touches the graphics chip."),
        ]),
    ]

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

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
        image.widthAnchor.constraint(equalToConstant: 64).isActive = true
        image.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let latest = Self.releases.first
        let title = NSTextField(labelWithString: "What's New in Oneko \(latest?.version ?? Self.currentVersion)")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let sub = NSTextField(labelWithString: "Oneko just got an update. Here's what changed.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        let rows = NSStackView(views: (latest?.items ?? []).map(WelcomeWindow.tipRow))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12

        let go = NSButton(title: "Continue", target: nil, action: #selector(NSWindow.performClose(_:)))
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

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

/// A little bubble over a cat you're hovering: its name and stats ("Double-click to wake"
/// if it's asleep).
final class HintWindow: OverlayPanel {
    private let label = NSTextField(labelWithString: "Double-click to wake")
    private let bubble = NSView()

    override init() {
        super.init()
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        bubble.layer?.cornerRadius = 9
        bubble.addSubview(label)
        mouseView.addSubview(bubble)
        setText("Double-click to wake")
    }

    func setText(_ text: String) {
        guard text != label.stringValue || bubble.frame.width == 0 else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 18, height: 20)
        bubble.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: 9, y: (size.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        setContentSize(size)
    }

    /// Centred just above `top` (global, y-up).
    func show(above top: CGPoint) {
        let o = NSPoint(x: (top.x - frame.width / 2).rounded(), y: (top.y + 4).rounded())
        if frame.origin != o { setFrameOrigin(o) }
        if !isVisible { orderFrontRegardless() }
    }
}
