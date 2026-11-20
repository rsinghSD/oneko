import AppKit

/// Reads displays and app windows into a `World`. Window bounds and owners need no Screen
/// Recording permission (only window titles and contents do, and we never read them).
enum WorldReader {
    /// `previous`: reuse its window list instead of asking WindowServer (cheap ticks).
    static func read(reusingWindowsOf previous: World? = nil) -> World {
        let cursor = NSEvent.mouseLocation
        let screens = NSScreen.screens.map {
            ScreenInfo(frame: $0.frame, visible: $0.visibleFrame,
                       dock: dockStrip(frame: $0.frame, visible: $0.visibleFrame, cursor: cursor))
        }
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

    struct DockPrefs { var autohide: Bool; var edge: String; var tile: CGFloat; var delay: Double }
    private static var prefs: (read: CFTimeInterval, value: DockPrefs)?
    /// For tests: pretend the Dock has these settings.
    static var prefsOverride: DockPrefs?

    /// The Dock's own settings, re-read every few seconds.
    private static func dockPrefs() -> DockPrefs {
        if let o = prefsOverride { return o }
        let now = CACurrentMediaTime()
        if let p = prefs, now - p.read < 3 { return p.value }
        let app = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(app)
        func num(_ k: String) -> Double? { (CFPreferencesCopyAppValue(k as CFString, app) as? NSNumber)?.doubleValue }
        let v = DockPrefs(
            autohide: (CFPreferencesCopyAppValue("autohide" as CFString, app) as? Bool) ?? false,
            edge: (CFPreferencesCopyAppValue("orientation" as CFString, app) as? String) ?? "bottom",
            tile: CGFloat(num("tilesize") ?? 48),
            delay: num("autohide-delay") ?? 0.3)
        prefs = (now, v)
        return v
    }

    /// An auto-hiding Dock: which display it's showing on, and since when the cursor has
    /// been pressed against that display's Dock edge.
    private static var revealed: CGRect?
    private static var edgeSince: (screen: CGRect, t: Double)?

    /// The strip the Dock occupies on this display right now, if it's showing here.
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
