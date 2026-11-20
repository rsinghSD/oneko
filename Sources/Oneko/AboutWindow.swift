import AppKit

/// A clean About window: the cat, name, version, a few lines, the credits and the
/// developer link. Everything fits; nothing scrolls.
final class AboutWindow: NSPanel {
    init(icon: CGImage?) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating

        let image = NSImageView()
        if let icon {
            let img = NSImage(cgImage: icon, size: NSSize(width: 64, height: 64))
            image.image = img
        }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.magnificationFilter = .nearest
        image.widthAnchor.constraint(equalToConstant: 64).isActive = true
        image.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let info = Bundle.main.infoDictionary
        let version = "Version \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.alignment = .center
            l.preferredMaxLayoutWidth = 250
            l.widthAnchor.constraint(equalToConstant: 250).isActive = true
            return l
        }

        let link = NSButton(title: "github.com/rsinghSD", target: self, action: #selector(openGitHub))
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: "github.com/rsinghSD", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let stack = NSStackView(views: [
            image,
            label("Oneko", size: 18, weight: .bold),
            label(version, size: 11, color: .secondaryLabelColor),
            label("A desktop cat that chases your cursor.\nDrag it, throw it, pet it, and play with its toys.", size: 12),
            label("Sprites: classic Neko / oneko artwork by Kenji Gotoh and Tatsuya Kato, via oneko.js by adryd (MIT).",
                  size: 10, color: .secondaryLabelColor),
            divider,
            credit(),
            link,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: stack.views[1])
        stack.setCustomSpacing(14, after: stack.views[2])
        stack.setCustomSpacing(12, after: stack.views[4])
        stack.setCustomSpacing(12, after: divider)
        stack.setCustomSpacing(2, after: stack.views[6])
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 20, bottom: 22, right: 20)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    /// "Developed with ♥ by Ramandeep Singh", with a red heart.
    private func credit() -> NSTextField {
        let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let s = NSMutableAttributedString(string: "Developed with ", attributes: [.font: bold, .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "♥", attributes: [.font: bold, .foregroundColor: NSColor.systemRed]))
        s.append(NSAttributedString(string: " by Ramandeep Singh", attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        let l = NSTextField(labelWithAttributedString: s)
        l.alignment = .center
        return l
    }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rsinghSD")!)
    }
}
