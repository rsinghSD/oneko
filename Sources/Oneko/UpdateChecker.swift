import AppKit

/// Looks for a newer Oneko on GitHub (the public releases API: no account, nothing about
/// you is sent), once a day and from the menu. If there is one, it offers to download it.
/// After you update, the What's New window shows what changed.
final class UpdateChecker {
    static let releasesAPI = URL(string: "https://api.github.com/repos/rsinghSD/oneko/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/rsinghSD/oneko/releases/latest")!

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL?
    }

    private let settings: Settings
    private var checking = false

    init(settings: Settings) {
        self.settings = settings
    }

    /// "v0.5.10" is newer than "0.5.9" (numbers compared one by one).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The release in GitHub's JSON, if it reads.
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let assets = j["assets"] as? [[String: Any]] ?? []
        let dmg = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".dmg") }.flatMap(URL.init(string:))
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       notes: j["body"] as? String ?? "", page: page, dmg: dmg)
    }

    /// Once a day at most, if automatic checks are on.
    func checkIfDue() {
        guard settings.autoUpdateCheck else { return }
        let last = settings.lastUpdateCheck
        guard last.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true else { return }
        check(userAsked: false)
    }

    /// `userAsked`: from the menu, so say so even when you're up to date (or offline).
    func check(userAsked: Bool) {
        guard !checking else { return }
        checking = true
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Oneko/\(WhatsNewWindow.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.settings.lastUpdateCheck = Date()
                guard error == nil, let data, let release = Self.parse(data) else {
                    if userAsked { self.tell("Couldn't check for updates", "GitHub couldn't be reached. Try again later.") }
                    return
                }
                self.offer(release, userAsked: userAsked)
            }
        }.resume()
    }

    private func offer(_ r: Release, userAsked: Bool) {
        let current = WhatsNewWindow.currentVersion
        guard Self.isNewer(r.version, than: current) else {
            if userAsked { tell("Oneko is up to date", "You have the newest version, \(current).") }
            return
        }
        if !userAsked, settings.skippedVersion == r.version { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Oneko \(r.version) is out"
        let notes = r.notes.split(separator: "\n").prefix(12).joined(separator: "\n")
        alert.informativeText = "You have \(current).\n\n" + notes
            + "\n\nInstalled with Homebrew? Run: brew upgrade --cask oneko"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.dmg ?? r.page)
        case .alertThirdButtonReturn: settings.skippedVersion = r.version
        default: break
        }
    }

    private func tell(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
