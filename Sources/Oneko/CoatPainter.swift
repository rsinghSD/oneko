import AppKit

/// "Paint your own coat": outline, fill and accent colours plus a pattern, with a live,
/// animated preview. "Use This Coat" puts it on the "My Coat" slot; "Save" keeps it under a
/// name, so it shows up in every coat menu and any cat can wear it.
final class CoatPainter: NSPanel, NSWindowDelegate {
    /// The coat to wear now (My Coat, or the coat just saved).
    var onApply: ((Skin) -> Void)?
    /// Saved coats were added, changed or deleted.
    var onCoatsChanged: (() -> Void)?

    private let base: SpriteSheet
    private let settings: Settings
    private let saved = NSPopUpButton()
    private let delete = NSButton()
    private let outlineWell = NSColorWell()
    private let fillWell = NSColorWell()
    private let accentWell = NSColorWell()
    private let accent2Well = NSColorWell()
    private let accentLabel = NSTextField(labelWithString: "Accent")
    private let accent2Label = NSTextField(labelWithString: "Patches 2")
    private lazy var accent2Column = labeled(accent2Label, accent2Well)
    private let autoOutline = NSButton(checkboxWithTitle: "Auto", target: nil, action: nil)
    private let shade = NSButton(checkboxWithTitle: "Soft shading", target: nil, action: nil)
    private let pattern = NSPopUpButton()
    private let name = NSTextField()
    private let save = NSButton()
    private let preview = CoatPreview()
    private var timer: Timer?
    /// The saved coat being edited, if any.
    private var editing: String?

    init(base: SpriteSheet, settings: Settings, start: Skin) {
        self.base = base
        self.settings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Paint Your Coat"
        isReleasedWhenClosed = false
        level = .floating
        delegate = self

        for w in [outlineWell, fillWell, accentWell, accent2Well] {
            w.target = self
            w.action = #selector(changed)
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        pattern.addItems(withTitles: CoatPattern.allCases.map(\.title))
        pattern.target = self
        pattern.action = #selector(patternChanged)
        for b in [autoOutline, shade] {
            b.target = self
            b.action = #selector(changed)
        }
        autoOutline.toolTip = "Pick an outline that stands out against the fill"
        shade.toolTip = "A slightly darker fill along the bottom and right of the outline"
        saved.target = self
        saved.action = #selector(pickSaved)
        delete.title = "Delete"
        delete.bezelStyle = .rounded
        delete.target = self
        delete.action = #selector(deleteSaved)
        name.placeholderString = "Name it to save it"
        name.widthAnchor.constraint(equalToConstant: 170).isActive = true
        name.delegate = self

        let suggest = NSButton(title: "Suggest Colours", target: self, action: #selector(suggestColours))
        suggest.bezelStyle = .rounded

        let outlineColumn = NSStackView(views: [NSTextField(labelWithString: "Outline"), outlineWell, autoOutline])
        outlineColumn.orientation = .vertical
        outlineColumn.spacing = 4
        let patternColumn = NSStackView(views: [NSTextField(labelWithString: "Pattern"), pattern, shade])
        patternColumn.orientation = .vertical
        patternColumn.alignment = .leading
        patternColumn.spacing = 4
        let colours = NSStackView(views: [outlineColumn, labeled(NSTextField(labelWithString: "Fill"), fillWell),
                                          labeled(accentLabel, accentWell), accent2Column, patternColumn])
        colours.alignment = .top
        colours.spacing = 16

        let library = NSStackView(views: [NSTextField(labelWithString: "Coat:"), saved, delete, NSView(), suggest])
        library.spacing = 8

        save.title = "Save"
        save.bezelStyle = .rounded
        save.target = self
        save.action = #selector(saveCoat)
        save.toolTip = "Keep this coat under its name: it shows up in every coat menu"
        let use = NSButton(title: "Use This Coat", target: self, action: #selector(apply))
        use.keyEquivalent = "\r"
        use.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [name, save, NSView(), cancel, use])
        buttons.spacing = 8

        let stack = NSStackView(views: [preview, colours, library, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        for row in [library, buttons] {
            row.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        }
        contentView = stack
        setContentSize(stack.fittingSize)

        editing = start.id.hasPrefix(Skin.savedPrefix) ? start.id : nil
        reloadSaved()
        load(start)
    }

    private func labeled(_ label: NSTextField, _ v: NSView) -> NSStackView {
        let s = NSStackView(views: [label, v])
        s.orientation = .vertical
        s.spacing = 4
        return s
    }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in self?.preview.tick += 1 }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSColorPanel.shared.close()
    }

    // MARK: - The coat

    private var selectedPattern: CoatPattern { CoatPattern.allCases[max(0, pattern.indexOfSelectedItem)] }

    private func skin(id: String, title: String) -> Skin {
        func rgba(_ c: NSColor) -> RGBA {
            let s = c.usingColorSpace(.sRGB) ?? c
            func ch(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            return RGBA(r: ch(s.redComponent), g: ch(s.greenComponent), b: ch(s.blueComponent))
        }
        let fill = rgba(fillWell.color), p = selectedPattern
        let auto = autoOutline.state == .on
        return Skin(id: id, title: title, outline: auto ? fill.contrastingOutline : rgba(outlineWell.color), fill: fill,
                    accent: rgba(accentWell.color), pattern: p,
                    accent2: p.usesAccent2 ? rgba(accent2Well.color) : nil,
                    shade: shade.state == .on, autoOutline: auto)
    }

    private func load(_ s: Skin) {
        outlineWell.color = s.outline.nsColor
        fillWell.color = s.fill.nsColor
        accentWell.color = (s.accent ?? s.fill).nsColor
        accent2Well.color = (s.accent2 ?? s.pattern.suggested.3 ?? s.accent ?? s.fill).nsColor
        autoOutline.state = s.autoOutline ? .on : .off
        shade.state = s.shade ? .on : .off
        pattern.selectItem(at: CoatPattern.allCases.firstIndex(of: s.pattern) ?? 0)
        name.stringValue = s.id.hasPrefix(Skin.savedPrefix) ? s.title : ""
        changed()
    }

    @objc private func patternChanged() {
        // Galaxy and calico need a second accent; start it on something that suits.
        if selectedPattern.usesAccent2, let a2 = selectedPattern.suggested.3, accent2Column.isHidden {
            accent2Well.color = a2.nsColor
        }
        changed()
    }

    @objc private func suggestColours() {
        let (o, f, a, a2) = selectedPattern.suggested
        outlineWell.color = o.nsColor
        fillWell.color = f.nsColor
        accentWell.color = a.nsColor
        if let a2 { accent2Well.color = a2.nsColor }
        autoOutline.state = .off
        changed()
    }

    @objc private func changed() {
        let p = selectedPattern
        accentWell.isEnabled = p.usesAccent
        accentLabel.stringValue = p.accentTitle
        accentLabel.textColor = p.usesAccent ? .labelColor : .disabledControlTextColor
        accent2Label.stringValue = p.accent2Title
        accent2Column.isHidden = !p.usesAccent2
        let current = skin(id: Skin.paintedID, title: "My Coat")
        outlineWell.isEnabled = autoOutline.state == .off
        if autoOutline.state == .on { outlineWell.color = current.outline.nsColor }
        preview.sheet = base.recolored(current)
        updateSave()
    }

    private func updateSave() {
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        save.isEnabled = !n.isEmpty
        let replacing = settings.savedCoats.contains { $0.title == n } || (editing != nil && savedTitle(editing) == n)
        save.title = replacing ? "Update" : "Save"
    }

    // MARK: - Saved coats

    private func savedTitle(_ id: String?) -> String? { settings.savedCoats.first { $0.id == id }?.title }

    private func reloadSaved() {
        let coats = settings.savedCoats
        saved.removeAllItems()
        saved.addItem(withTitle: "New Coat")
        saved.menu?.addItem(.separator())
        for c in coats {
            saved.menu?.addItem(withTitle: c.title, action: nil, keyEquivalent: "").representedObject = c.id
        }
        if let editing, let i = saved.itemArray.firstIndex(where: { $0.representedObject as? String == editing }) {
            saved.selectItem(at: i)
        } else {
            saved.selectItem(at: 0)
        }
        saved.isEnabled = !coats.isEmpty
        delete.isEnabled = editing != nil
    }

    @objc private func pickSaved() {
        guard let id = saved.selectedItem?.representedObject as? String, let coat = settings.coat(id: id) else {
            editing = nil
            name.stringValue = ""
            delete.isEnabled = false
            updateSave()
            return
        }
        editing = id
        delete.isEnabled = true
        load(coat)
    }

    @objc private func saveCoat() {
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var coats = settings.savedCoats
        // Same name: update that coat. Editing a coat and renaming it: rename it.
        let id = coats.first { $0.title == title }?.id ?? editing ?? Skin.savedPrefix + UUID().uuidString.prefix(8).lowercased()
        let coat = skin(id: id, title: title)
        if let i = coats.firstIndex(where: { $0.id == id }) { coats[i] = coat } else { coats.append(coat) }
        settings.savedCoats = coats
        onCoatsChanged?()
        onApply?(coat)
        close()
    }

    @objc private func deleteSaved() {
        guard let editing, let title = savedTitle(editing) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "Cats wearing it go back to taking turns with the other coats."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: self) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            settings.savedCoats = settings.savedCoats.filter { $0.id != editing }
            if settings.skin == editing { settings.skin = Skin.paintedID }
            self.editing = nil
            name.stringValue = ""
            reloadSaved()
            updateSave()
            onCoatsChanged?()
        }
    }

    @objc private func apply() {
        onApply?(skin(id: Skin.paintedID, title: "My Coat"))
        close()
    }

    @objc private func cancelPressed() {
        close()
    }
}

extension CoatPainter: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateSave() }
}

/// Sitting, running both ways, sleeping and alert, at 3×, animated.
private final class CoatPreview: NSView {
    var sheet: SpriteSheet? { didSet { needsDisplay = true } }
    var tick = 0 { didSet { needsDisplay = true } }

    /// Pose, and how many ticks each of its frames lasts (0: one frame).
    private static let poses: [(SpriteName, Int)] = [(.idle, 0), (.E, 1), (.S, 1), (.sleeping, 4), (.alert, 0)]
    private static let zoom: CGFloat = 3, gap: CGFloat = 10, pad: CGFloat = 14

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(Self.poses.count)
        return NSSize(width: n * 32 * Self.zoom + (n - 1) * Self.gap + 2 * Self.pad, height: 32 * Self.zoom + 2 * Self.pad)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        guard let sheet, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        let side = 32 * Self.zoom
        for (i, pose) in Self.poses.enumerated() {
            let frame = pose.1 == 0 ? 0 : tick / pose.1
            guard let img = sheet.image(for: pose.0, frame: frame) else { continue }
            ctx.draw(img, in: CGRect(x: Self.pad + CGFloat(i) * (side + Self.gap), y: Self.pad, width: side, height: side))
        }
    }
}
