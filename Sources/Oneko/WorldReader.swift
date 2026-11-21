import AppKit

/// Reads displays and app windows into a `World`. Window bounds and owners need no Screen
/// Recording permission (only window titles and contents do, and we never read them).
enum WorldReader {
    /// `previous`: reuse its window list instead of asking WindowServer (cheap ticks).
    static func read(reusingWindowsOf previous: World? = nil) -> World {
        let cursor = NSEvent.mouseLocation
        let screens = dockedScreens(NSScreen.screens.map { ($0.frame, $0.visibleFrame) }, cursor: cursor)
        // CoreGraphics window bounds are top-left based on the primary display.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        var windows: [WindowInfo] = previous?.windows ?? []
        if previous == nil, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                      (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                      let id = w[kCGWindowNumber as String] as? Int,
                      let dict = w[kCGWindowBounds as String] as? NSDictionary,
                      let cg = CGRect(dictionaryRepresentation: dict),
                      cg.width >= 60, cg.height >= 40
                else { continue }
                windows.append(WindowInfo(id: id, pid: pid, frame: CGRect(
                    x: cg.minX, y: primaryMaxY - cg.maxY, width: cg.width, height: cg.height)))
            }
        }
        return World(screens: screens, windows: windows, cursor: cursor,
                     mouseDown: NSEvent.pressedMouseButtons & 1 != 0,
                     frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    // MARK: - Dock

    struct DockPrefs {
        var autohide: Bool; var edge: String; var tile: CGFloat; var delay: Double
        /// Roughly how many icons and separators the Dock shows (for its length).
        var icons: CGFloat = 0; var separators: Int = 0
    }
    private static var prefs: (read: CFTimeInterval, value: DockPrefs)?
    /// For tests: pretend the Dock has these settings.
    static var prefsOverride: DockPrefs?
    /// For tests: pretend Accessibility reported this Dock frame (global, y-up).
    static var axOverride: CGRect??

    /// The Dock's own settings, re-read every few seconds.
    static func dockPrefs() -> DockPrefs {
        if let o = prefsOverride { return o }
        let now = CACurrentMediaTime()
        if let p = prefs, now - p.read < 3 { return p.value }
        let app = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(app)
        func value(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, app) }
        func num(_ k: String) -> Double? { (value(k) as? NSNumber)?.doubleValue }
        var v = DockPrefs(
            autohide: (value("autohide") as? Bool) ?? false,
            edge: (value("orientation") as? String) ?? "bottom",
            tile: CGFloat(num("tilesize") ?? 48),
            delay: num("autohide-delay") ?? 0.3)
        (v.icons, v.separators) = dockItems(
            persistent: value("persistent-apps") as? [[String: Any]] ?? [],
            others: (value("persistent-others") as? [Any])?.count ?? 0,
            recents: (value("show-recents") as? Bool ?? true)
                ? (value("recent-apps") as? [[String: Any]] ?? []).compactMap(bundleID) : [],
            running: NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        prefs = (now, v)
        return v
    }

    private static func bundleID(_ tile: [String: Any]) -> String? {
        (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    /// What the Dock shows: Finder, your kept apps (spacers count too), then a section of
    /// running and recent apps that aren't kept, your folders, and the Trash.
    static func dockItems(persistent: [[String: Any]], others: Int, recents: [String],
                          running: [String]) -> (icons: CGFloat, separators: Int) {
        var kept: Set<String> = ["com.apple.finder"]
        var icons: CGFloat = 2                                    // Finder and the Trash
        for tile in persistent {
            switch tile["tile-type"] as? String {
            case "small-spacer-tile": icons += 0.5
            default: icons += 1
            }
            if let id = bundleID(tile) { kept.insert(id) }
        }
        var section: [String] = []
        for id in running + recents where !kept.contains(id) && !section.contains(id) { section.append(id) }
        icons += CGFloat(section.count + others)
        return (icons, section.isEmpty ? 1 : 2)
    }

    /// How long the Dock is along its edge (measured on macOS 26: ~1.06 tiles per icon).
    static func dockLength(_ p: DockPrefs) -> CGFloat {
        p.icons * p.tile * 1.06 + CGFloat(p.separators) * p.tile * 0.33 + 10
    }

    /// Every display, with the Dock (just the Dock itself, not the whole strip macOS keeps
    /// free for it) on the one where it's showing.
    static func dockedScreens(_ displays: [(frame: CGRect, visible: CGRect)], cursor: CGPoint,
                              now: Double = CACurrentMediaTime()) -> [ScreenInfo] {
        var strips = displays.map { dockStrip(frame: $0.frame, visible: $0.visible, cursor: cursor, now: now) }
        let p = dockPrefs()
        // A Dock that's always shown is always somewhere. If no display reports room for it
        // (seen on a MacBook on its own), it's on the main display.
        if !p.autohide, strips.allSatisfy({ $0 == nil }), let main = displays.first?.frame {
            let t = p.tile + 20
            switch p.edge {
            case "left": strips[0] = CGRect(x: main.minX, y: main.minY, width: t, height: main.height)
            case "right": strips[0] = CGRect(x: main.maxX - t, y: main.minY, width: t, height: main.height)
            default: strips[0] = CGRect(x: main.minX, y: main.minY, width: main.width, height: t)
            }
        }
        let exact = exactDockFrame()
        return zip(displays, strips).map { d, strip in
            ScreenInfo(frame: d.frame, visible: d.visible,
                       dock: strip.map { dockBody(strip: $0, frame: d.frame, length: dockLength(p), exact: exact) })
        }
    }

    /// The Dock inside its strip: centred along the edge, as long as its icons (or exactly
    /// as Accessibility reports it, when Oneko may ask).
    static func dockBody(strip s: CGRect, frame f: CGRect, length: CGFloat, exact: CGRect?) -> CGRect {
        let pad: CGFloat = 5
        if s.width >= s.height {                                   // bottom
            if let e = exact, e.intersects(s), e.width > 40 {
                let x0 = max(s.minX, e.minX - pad), x1 = min(s.maxX, e.maxX + pad)
                return CGRect(x: x0, y: s.minY, width: x1 - x0, height: s.height)
            }
            let w = min(s.width, max(length, s.height))
            return CGRect(x: f.midX - w / 2, y: s.minY, width: w, height: s.height)
        }
        if let e = exact, e.intersects(s), e.height > 40 {         // left / right
            let y0 = max(s.minY, e.minY - pad), y1 = min(s.maxY, e.maxY + pad)
            return CGRect(x: s.minX, y: y0, width: s.width, height: y1 - y0)
        }
        let h = min(s.height, max(length, s.width))
        return CGRect(x: s.minX, y: f.midY - h / 2, width: s.width, height: h)
    }

    // MARK: Exact Dock size (Accessibility)

    /// May Oneko read the Dock's size? (System Settings › Privacy & Security › Accessibility.)
    static var exactDockAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends you to the Accessibility list.
    static func askForExactDock() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static var exactCache: (read: CFTimeInterval, value: CGRect?)?

    /// The frame of the Dock's icon list, global y-up. Only with Accessibility; re-read
    /// once a second.
    static func exactDockFrame() -> CGRect? {
        if let o = axOverride { return o }
        let now = CACurrentMediaTime()
        if let c = exactCache, now - c.read < 1 { return c.value }
        var result: CGRect?
        if AXIsProcessTrusted(),
           let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
               let list = (children as? [AXUIElement])?.first(where: { role($0) == kAXListRole as String }),
               let r = frame(of: list) {
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                result = CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
            }
        }
        exactCache = (now, result)
        return result
    }

    private static func role(_ e: AXUIElement) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success ? v as? String : nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// An auto-hiding Dock: which display it's showing on, and since when the cursor has
    /// been pressed against that display's Dock edge.
    private static var revealed: CGRect?
    private static var edgeSince: (screen: CGRect, t: Double)?

    /// The strip macOS keeps for the Dock on this display right now, if it's showing here.
    /// An always-visible Dock shows up as the gap between the frame and the visible frame.
    /// An auto-hiding one isn't reported by macOS, so this copies macOS's own rule: it
    /// appears once the cursor has been pushed against the Dock's edge of the display for
    /// the reveal delay, stays while the cursor is over it, and hides when the cursor leaves.
    static func dockStrip(frame f: CGRect, visible v: CGRect, cursor: CGPoint,
                          now: Double = CACurrentMediaTime()) -> CGRect? {
        if v.minY - f.minY >= 20 { return CGRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY) }
        if v.minX - f.minX >= 20 { return CGRect(x: f.minX, y: f.minY, width: v.minX - f.minX, height: f.height) }
        if f.maxX - v.maxX >= 20 { return CGRect(x: v.maxX, y: f.minY, width: f.maxX - v.maxX, height: f.height) }
        let p = dockPrefs()
        guard p.autohide else { return nil }
        let band = p.tile + 22
        let strip: CGRect
        let atEdge: Bool
        switch p.edge {
        case "left":
            strip = CGRect(x: f.minX, y: f.minY, width: band, height: f.height)
            atEdge = cursor.x <= f.minX + 1.5
        case "right":
            strip = CGRect(x: f.maxX - band, y: f.minY, width: band, height: f.height)
            atEdge = cursor.x >= f.maxX - 2.5
        default:
            strip = CGRect(x: f.minX, y: f.minY, width: f.width, height: band)
            atEdge = cursor.y <= f.minY + 1.5
        }
        let here = f.contains(cursor) || (cursor.x >= f.minX && cursor.x < f.maxX && abs(cursor.y - f.minY) < 2)

        if revealed == f {
            if here && strip.contains(cursor) { return strip }   // still over the Dock
            revealed = nil                                       // moved away: it hides
            return nil
        }
        guard here, atEdge else {
            if edgeSince?.screen == f { edgeSince = nil }
            return nil
        }
        // Pushed against the edge: it appears after the Dock's delay (plus its slide-in).
        if edgeSince?.screen != f { edgeSince = (f, now) }
        if let s = edgeSince, now - s.t >= p.delay + 0.15 {
            revealed = f
            edgeSince = nil
            return strip
        }
        return nil
    }
}
