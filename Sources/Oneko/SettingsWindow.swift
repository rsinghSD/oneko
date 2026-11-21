import AppKit
import ServiceManagement

/// Oneko Settings: a native macOS settings window with toolbar tabs. Every control
/// applies immediately; the window re-reads the current state whenever it's shown.
final class SettingsWindow: NSWindow {
    private weak var app: AppDelegate?
    private let tabs = NSTabViewController()
    private var pages: [SettingsPage] = []

    init(app: AppDelegate) {
        self.app = app
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabs.tabStyle = .toolbar
        pages = [GeneralPage(), CatsPage(), NapsPage(), ToysPage(), SoundsPage()]
        if TouchBarCat.isSupported { pages.append(TouchBarPage()) }
        pages.append(StatsPage())
        for p in pages {
            p.app = app
            let item = NSTabViewItem(viewController: p)
            item.label = p.title ?? ""
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
            tabs.addTabViewItem(item)
        }
        if let saved = UserDefaults.standard.string(forKey: "settingsTab"),
           let i = pages.firstIndex(where: { $0.title == saved }) {
            tabs.selectedTabViewItemIndex = i
        }
        contentViewController = tabs
    }

    func present() {
        refresh()
        if !isVisible { center() }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Re-read everything (things can change from the menu, the Touch Bar, or play).
    func refresh() {
        for p in pages { p.refresh() }
    }

    override func close() {
        if let t = pages[safe: tabs.selectedTabViewItemIndex]?.title {
            UserDefaults.standard.set(t, forKey: "settingsTab")
        }
        super.close()
    }
}


// MARK: - Building blocks

/// One tab: a two-column form (labels on the right of the left column, controls on the left
/// of the right column), like the system's own settings panes.
class SettingsPage: NSViewController {
    weak var app: AppDelegate?
    var symbol: String { "gearshape" }
    let grid = NSGridView()

    override func loadView() {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        build()
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 22),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -22),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -30),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
        view = box
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        preferredContentSize = view.fittingSize
    }

    func build() {}
    func refresh() {}

    func row(_ label: String, _ views: NSView...) {
        let l = NSTextField(labelWithString: label.isEmpty ? "" : label + ":")
        let stack = NSStackView(views: views)
        stack.spacing = 8
        grid.addRow(with: [l, stack])
    }

    func note(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 300
        grid.addRow(with: [NSGridCell.emptyContentView, l])
    }

    func gap() {
        let r = grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        r.height = 4
    }

    func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    func popup(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = self
        p.action = action
        return p
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    /// Run a change, then refresh every page (one setting can affect another).
    func changed(_ f: () -> Void) {
        f()
        (view.window as? SettingsWindow)?.refresh()
    }
}

// MARK: - General

final class GeneralPage: SettingsPage {
    override var symbol: String { "gearshape" }
    private lazy var speed = popup(Settings.Speed.allCases.map(\.title), #selector(speedChanged))
    private lazy var size = popup(Settings.Size.allCases.map(\.title), #selector(sizeChanged))
    private lazy var coat = popup([], #selector(coatChanged))
    private lazy var hat = popup(["Seasonal", "None", "Santa Hat", "Witch Hat", "Party Hat"], #selector(hatChanged))
    private lazy var paused = checkbox("Paused (curls up and sleeps)", #selector(pauseChanged))
    private lazy var login = checkbox("Launch Oneko at login", #selector(loginChanged))
    private static let hatKeys = ["auto", "none", "santa", "witch", "party"]

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        coat.addItems(withTitles: Skin.all.map(\.title) + ["My Coat", "Custom Sprite Sheet…"])
        row("Speed", speed)
        row("Size", size)
        gap()
        row("Coat", coat, button("Paint Your Coat…", #selector(paintCoat)))
        row("Hat", hat)
        gap()
        row("", paused)
        row("", login)
    }

    override func refresh() {
        guard let s = app?.settings else { return }
        speed.selectItem(at: Settings.Speed.allCases.firstIndex(of: s.speed) ?? 1)
        size.selectItem(at: Settings.Size.allCases.firstIndex(of: s.size) ?? 0)
        size.isEnabled = app?.touchBar == nil
        if let i = Skin.all.firstIndex(where: { $0.id == s.skin }) { coat.selectItem(at: i) }
        else if s.skin == Skin.paintedID { coat.selectItem(at: Skin.all.count) }
        else { coat.selectItem(at: Skin.all.count + 1) }
        hat.selectItem(at: Self.hatKeys.firstIndex(of: s.hat) ?? 0)
        paused.state = s.paused ? .on : .off
        let status = SMAppService.mainApp.status
        login.state = status == .enabled ? .on : .off
        login.title = status == .requiresApproval ? "Launch Oneko at login (needs approval in System Settings)"
            : "Launch Oneko at login"
    }

    @objc private func speedChanged() {
        changed { app?.settings.speed = Settings.Speed.allCases[speed.indexOfSelectedItem]; app?.applySettings() }
    }
    @objc private func sizeChanged() {
        changed { app?.settings.size = Settings.Size.allCases[size.indexOfSelectedItem]; app?.applySettings() }
    }
    @objc private func coatChanged() {
        let i = coat.indexOfSelectedItem
        if i < Skin.all.count {
            changed { app?.settings.skin = Skin.all[i].id; app?.reloadSprites() }
        } else if i == Skin.all.count {
            changed { app?.settings.skin = Skin.paintedID; app?.reloadSprites() }
        } else {
            app?.chooseCustomSheet()
            refresh()
        }
    }
    @objc private func paintCoat() { app?.paintCoat() }
    @objc private func hatChanged() {
        changed { app?.settings.hat = Self.hatKeys[hat.indexOfSelectedItem]; app?.applyHat() }
    }
    @objc private func pauseChanged() { changed { app?.togglePause() } }
    @objc private func loginChanged() { changed { app?.toggleLaunchAtLogin() } }
}

// MARK: - Cats

final class CatsPage: SettingsPage {
    override var symbol: String { "pawprint" }
    private let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.allowsFloats = false
        f.minimum = 0
        f.maximum = NSNumber(value: Settings.maxCrowdCats)
        return f
    }()
    private lazy var count: NSTextField = {
        let t = NSTextField()
        t.formatter = formatter
        t.alignment = .right
        t.target = self
        t.action = #selector(countChanged)
        t.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return t
    }()
    private lazy var stepper: NSStepper = {
        let s = NSStepper()
        s.minValue = 0
        s.increment = 1
        s.valueWraps = false
        s.target = self
        s.action = #selector(stepped)
        return s
    }()
    private lazy var crowd = checkbox("Crowd mode: cats past 50 are light GPU cats", #selector(crowdChanged))
    private lazy var behavior = popup(Settings.CatBehavior.allCases.map(\.title), #selector(behaviorChanged))
    private lazy var coats = popup(Settings.CoatMode.allCases.map(\.title), #selector(coatsChanged))
    private lazy var choose = button("Choose…", #selector(chooseCoats))
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var warningRow: NSGridRow?
    private var coatList: CoatListPanel?

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Cats"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        row("Cats", count, stepper)
        row("", crowd)
        note("Optional. Off, every cat is a real cat you can pet, yeet and park, up to 10,000 (each one is a little window, so it costs CPU). On, cats past 50 are drawn by the graphics chip instead: light on resources, click-through, up to 1,000,000.")
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 300
        warningRow = grid.addRow(with: [NSGridCell.emptyContentView, warning])
        gap()
        row("Extra cats", behavior)
        row("Coats", coats, choose)
        if TouchBarCat.isSupported { note("The Touch Bar shows up to 50 cats.") }
    }

    override func refresh() {
        guard let s = app?.settings else { return }
        let n = s.catCount
        let max = s.crowdMode ? Settings.maxCrowdCats : Settings.maxRealCats
        formatter.maximum = NSNumber(value: max)
        stepper.maxValue = Double(max)
        if count.currentEditor() == nil { count.integerValue = n }
        stepper.integerValue = n
        crowd.state = s.crowdMode ? .on : .off
        behavior.selectItem(at: Settings.CatBehavior.allCases.firstIndex(of: s.catBehavior) ?? 0)
        coats.selectItem(at: Settings.CoatMode.allCases.firstIndex(of: s.coatMode) ?? 0)
        choose.isEnabled = s.coatMode == .custom && n >= 2
        let heavy = !s.crowdMode && n > 200, wild = s.crowdMode && n > 10_000
        warning.stringValue = heavy
            ? "\(n.formatted()) real cats, each with its own window and physics. Past a few hundred your Mac will feel it."
            : wild ? "That's a lot of cats. Past about 10,000 they get choppy, and around a million the screen is solid cat." : ""
        warningRow?.isHidden = !heavy && !wild
    }

    private func setCount(_ n: Int) {
        guard let app else { return }
        let real = app.settings.crowdMode ? min(n, Settings.crowdAfter) : min(n, Settings.maxRealCats)
        if real > 1000, real > app.settings.realCatCount, !confirmRealCats(real) { refresh(); return }
        changed {
            app.settings.catCount = n
            app.setCatCount(app.settings.catCount)
        }
    }

    /// Thousands of real cats are heavy: ask once before spawning them.
    private func confirmRealCats(_ n: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Spawn \(n.formatted()) real cats?"
        alert.informativeText = "Each real cat is its own little window with its own physics. A thousand is fine on most Macs; thousands more will make it feel slow. Crowd mode keeps big numbers light."
        alert.addButton(withTitle: "Spawn Them")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func countChanged() { setCount(count.integerValue) }
    @objc private func stepped() { setCount(stepper.integerValue) }
    @objc private func crowdChanged() {
        changed {
            guard let app else { return }
            let on = crowd.state == .on
            // Turning it off makes every cat real (up to 10,000): ask first if that's a lot.
            let real = min(app.settings.catCount, Settings.maxRealCats)
            if !on, real > 1000, !confirmRealCats(real) { return }
            app.settings.crowdMode = on
            app.setCatCount(app.settings.catCount)
        }
    }
    @objc private func behaviorChanged() {
        changed {
            app?.settings.catBehavior = Settings.CatBehavior.allCases[behavior.indexOfSelectedItem]
            app?.catsChanged()
        }
    }
    @objc private func coatsChanged() {
        changed {
            app?.settings.coatMode = Settings.CoatMode.allCases[coats.indexOfSelectedItem]
            app?.reloadSprites()
        }
    }
    @objc private func chooseCoats() {
        guard let app, let w = view.window else { return }
        let panel = CoatListPanel(app: app)
        coatList = panel
        w.beginSheet(panel)
    }
}

/// One coat per cat, for cats 2…50.
final class CoatListPanel: NSPanel {
    private weak var app: AppDelegate?
    private static var choices: [(id: String, title: String)] {
        [("", "Take turns")] + Skin.all.map { ($0.id, $0.title) } + [(Skin.paintedID, "My Coat"), ("random", "Random")]
    }

    init(app: AppDelegate) {
        self.app = app
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        let n = min(app.settings.realCatCount, 50)
        let saved = app.settings.customCoats
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        for i in 0..<max(0, n - 1) {
            let p = NSPopUpButton()
            p.addItems(withTitles: Self.choices.map(\.title))
            p.selectItem(at: Self.choices.firstIndex { $0.id == (saved[safe: i] ?? "") } ?? 0)
            p.tag = i
            p.target = self
            p.action = #selector(picked(_:))
            let label = NSTextField(labelWithString: "Cat \(i + 2):")
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let row = NSStackView(views: [label, p])
            row.spacing = 8
            rows.addArrangedSubview(row)
        }
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let doc = FlippedView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rows)
        let fit = rows.fittingSize
        doc.frame = NSRect(x: 0, y: 0, width: max(300, fit.width), height: fit.height)
        rows.frame = doc.bounds
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 320, height: 376))
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        scroll.drawsBackground = false
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 320 - 96, y: 10, width: 80, height: 28)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
        content.addSubview(scroll)
        content.addSubview(done)
        contentView = content
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        guard let app else { return }
        var list = app.settings.customCoats
        while list.count <= sender.tag { list.append("") }
        list[sender.tag] = Self.choices[sender.indexOfSelectedItem].id
        app.settings.customCoats = list
        app.reloadSprites()
    }

    @objc private func finish() {
        sheetParent?.endSheet(self)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Naps & behaviour

final class NapsPage: SettingsPage {
    override var symbol: String { "moon.zzz" }
    private lazy var naps = checkbox("Naps when left alone", #selector(napsChanged))
    private lazy var windows = checkbox("On window title bars", #selector(windowsChanged))
    private lazy var menuBar = checkbox("In the menu bar (1× size only)", #selector(menuBarChanged))
    private lazy var dock = checkbox("On top of the Dock", #selector(dockChanged))
    private lazy var reacts = checkbox("Reacts to your Mac", #selector(reactsChanged))
    private lazy var fullScreen = checkbox("Hide in full-screen apps", #selector(fullScreenChanged))
    private lazy var reduceMotion = checkbox("Keep chasing when Reduce Motion is on", #selector(reduceMotionChanged))
    private let dockStatus = NSTextField(labelWithString: "")
    private lazy var dockButton = button("Allow Exact Size…", #selector(dockExact))

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Behavior"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        row("Naps", naps)
        row("Nap spots", windows)
        row("", menuBar)
        row("", dock)
        gap()
        row("Your Mac", reacts)
        note("Naps when you've been away for 2 minutes and stretches awake when you're back; a little sleepier late at night.")
        row("", fullScreen)
        row("", reduceMotion)
        gap()
        row("Dock size", dockStatus, dockButton)
        note("Oneko works out how long the Dock is from its icons. With Accessibility access it reads the Dock's exact size instead (it never reads anything else).")
    }

    override func refresh() {
        guard let s = app?.settings else { return }
        naps.state = s.naps ? .on : .off
        windows.state = s.spotWindows ? .on : .off
        menuBar.state = s.spotMenuBar ? .on : .off
        dock.state = s.spotDock ? .on : .off
        for b in [windows, menuBar, dock] { b.isEnabled = s.naps && app?.touchBar == nil }
        reacts.state = s.reacts ? .on : .off
        fullScreen.state = s.hideInFullScreen ? .on : .off
        fullScreen.isEnabled = app?.touchBar == nil
        reduceMotion.state = s.ignoreReduceMotion ? .on : .off
        let exact = WorldReader.exactDockAllowed
        dockStatus.stringValue = exact ? "Exact (Accessibility allowed)" : "Estimated from its icons"
        dockButton.isHidden = exact
    }

    @objc private func dockExact() { WorldReader.askForExactDock() }

    @objc private func napsChanged() { changed { app?.toggleNaps() } }
    @objc private func windowsChanged() { changed { app?.toggleSpotWindows() } }
    @objc private func menuBarChanged() { changed { app?.toggleSpotMenuBar() } }
    @objc private func dockChanged() { changed { app?.toggleSpotDock() } }
    @objc private func reactsChanged() { changed { app?.toggleReacts() } }
    @objc private func fullScreenChanged() { changed { app?.toggleHideInFullScreen() } }
    @objc private func reduceMotionChanged() { changed { app?.toggleIgnoreReduceMotion() } }
}

// MARK: - Toys

final class ToysPage: SettingsPage {
    override var symbol: String { "teddybear" }
    private lazy var box = checkbox("Cardboard box", #selector(boxChanged))
    private lazy var bone = checkbox("Bone (throw it to play fetch)", #selector(boneChanged))
    private lazy var yarn = checkbox("Ball of yarn", #selector(yarnChanged))
    private lazy var laser = checkbox("Laser pointer (follows your cursor)", #selector(laserChanged))
    private lazy var toolbox = checkbox("Toolbox: Paint tools, gravity", #selector(toolboxChanged))
    private lazy var catnip = button("Give Catnip", #selector(catnipPressed))

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Toys"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        row("Toys", box)
        row("", bone)
        row("", yarn)
        row("", laser)
        gap()
        row("Mode", toolbox)
        gap()
        row("Treats", catnip)
        note("About 12 seconds of zoomies.")
    }

    override func refresh() {
        guard let app else { return }
        let desk = app.touchBar == nil
        box.state = (app.touchBar?.hasBox ?? (app.play.box.state != .hidden)) ? .on : .off
        bone.state = (app.touchBar?.hasBone ?? (app.play.bone.state != .hidden)) ? .on : .off
        yarn.state = app.play.yarn.state != .hidden ? .on : .off
        laser.state = app.laserOn ? .on : .off
        toolbox.state = app.toolbox != nil ? .on : .off
        for c in [yarn, laser, toolbox, catnip] { c.isEnabled = desk }
    }

    @objc private func boxChanged() { changed { app?.toggleBox() } }
    @objc private func boneChanged() { changed { app?.toggleBone() } }
    @objc private func yarnChanged() { changed { app?.toggleYarn() } }
    @objc private func laserChanged() { changed { app?.toggleLaser() } }
    @objc private func toolboxChanged() { changed { app?.toggleToolbox() } }
    @objc private func catnipPressed() { app?.giveCatnip() }
}

// MARK: - Sounds

final class SoundsPage: SettingsPage {
    override var symbol: String { "speaker.wave.2" }
    private lazy var on = checkbox("Play sounds", #selector(onChanged))
    private lazy var volume: NSSlider = {
        let s = NSSlider(value: 0.6, minValue: 0.05, maxValue: 1, target: self, action: #selector(volumeChanged))
        s.isContinuous = false
        s.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return s
    }()
    private var previews: [NSButton] = []
    private let kinds: [(String, SoundBox.Kind)] = [("Purr", .purr), ("Meow", .meow), ("Mrrp", .mrrp),
                                                     ("Thud", .thud), ("Sleepy", .sleep)]

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Sounds"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        row("Sounds", on)
        row("Volume", volume)
        previews = kinds.enumerated().map { i, k in
            let b = NSButton(title: k.0, target: self, action: #selector(preview(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            return b
        }
        let stack = NSStackView(views: previews)
        stack.spacing = 4
        row("Listen", stack)
        note("All sounds are made by the app itself; there's nothing to download.")
    }

    override func refresh() {
        guard let s = app?.settings else { return }
        on.state = s.sound ? .on : .off
        volume.doubleValue = Double(s.volume)
        volume.isEnabled = s.sound
        for b in previews { b.isEnabled = s.sound }
    }

    @objc private func onChanged() { changed { app?.toggleSound() } }
    @objc private func volumeChanged() {
        changed {
            app?.settings.volume = Float(volume.doubleValue)
            app?.sounds.volume = Float(volume.doubleValue)
            app?.sounds.play(.mrrp)
        }
    }
    @objc private func preview(_ sender: NSButton) { app?.sounds.play(kinds[sender.tag].1) }
}

// MARK: - Touch Bar

final class TouchBarPage: SettingsPage {
    override var symbol: String { "rectangle.and.hand.point.up.left" }
    private lazy var desktop = NSButton(radioButtonWithTitle: "Desktop", target: self, action: #selector(homeChanged(_:)))
    private lazy var onBar = NSButton(radioButtonWithTitle: "Touch Bar", target: self, action: #selector(homeChanged(_:)))
    private lazy var slam = checkbox("Slam down into the Touch Bar", #selector(slamChanged))
    private lazy var flick = checkbox("Flick up to the desktop", #selector(flickChanged))

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Touch Bar"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        row("Neko lives on", desktop, onBar)
        gap()
        row("Trips", slam)
        note("Throw Neko down hard onto the bottom of the MacBook's screen and it drops into the Touch Bar.")
        row("", flick)
        note("On the Touch Bar, flick Neko upward (or very hard) and it flies back up to the desktop.")
    }

    override func refresh() {
        guard let app else { return }
        desktop.state = app.touchBar == nil ? .on : .off
        onBar.state = app.touchBar != nil ? .on : .off
        slam.state = app.settings.slamToTouchBar ? .on : .off
        flick.state = app.settings.flickToDesktop ? .on : .off
    }

    @objc private func homeChanged(_ sender: NSButton) {
        changed { app?.setHome(touchBar: sender === onBar) }
    }
    @objc private func slamChanged() { changed { app?.toggleSlamToTouchBar() } }
    @objc private func flickChanged() { changed { app?.toggleFlickToDesktop() } }
}

// MARK: - Stats

final class StatsPage: SettingsPage {
    override var symbol: String { "chart.bar" }
    private var values: [Stats.Key: NSTextField] = [:]

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        title = "Stats"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        for k in Stats.Key.allCases {
            let v = NSTextField(labelWithString: "0")
            v.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            values[k] = v
            row(k.title, v)
        }
        gap()
        row("", button("Reset Stats…", #selector(resetPressed)))
    }

    override func refresh() {
        guard let st = app?.stats else { return }
        for (k, v) in values { v.stringValue = k == .highestYeet ? "\(st[k]) pt" : "\(st[k])" }
    }

    @objc private func resetPressed() {
        let alert = NSAlert()
        alert.messageText = "Reset all of Neko's stats?"
        alert.informativeText = "Pets, yeets, fetches and records go back to zero."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard let w = view.window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.changed { self?.app?.stats.reset() }
        }
    }
}
