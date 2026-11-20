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
        pages = [GeneralPage(), NapsPage(), ToysPage(), SoundsPage()]
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

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
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
    private lazy var cats = popup((1...5).map { $0 == 1 ? "1 cat" : "\($0) cats" }, #selector(catsChanged))
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
        row("Cats", cats)
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
        cats.selectItem(at: s.catCount - 1)
        cats.isEnabled = app?.touchBar == nil
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
    @objc private func catsChanged() {
        changed {
            let n = cats.indexOfSelectedItem + 1
            app?.settings.catCount = n
            app?.setCatCount(n)
        }
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
    }

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
