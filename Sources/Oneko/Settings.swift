import Foundation
import CoreGraphics

/// User preferences, saved in UserDefaults (`local.oneko.app`).
final class Settings {
    enum Speed: Int, CaseIterable {
        case slow = 6, normal = 10, fast = 16, zoomies = 48
        var title: String {
            switch self {
            case .slow: return "Slow"
            case .normal: return "Normal"
            case .fast: return "Fast"
            case .zoomies: return "Zoomies"
            }
        }
    }

    /// Whole-number scales only, so the pixel art stays sharp.
    enum Size: Int, CaseIterable {
        case small = 1, medium = 2, large = 3
        var title: String {
            switch self {
            case .small: return "Small (1×)"
            case .medium: return "Medium (2×)"
            case .large: return "Large (3×)"
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.speed: Speed.normal.rawValue,
            Key.size: Size.small.rawValue,
            Key.naps: true,
            Key.hideInFullScreen: true,
            Key.ignoreReduceMotion: false,
            Key.skin: Skin.classicID,
            Key.spotWindows: true,
            Key.spotMenuBar: true,
            Key.spotDock: true,
            Key.sound: false,
            Key.volume: 0.6,
            Key.catCount: 1,
            Key.hat: "auto",
            Key.reacts: true,
            Key.slamToTouchBar: true,
            Key.flickToDesktop: true,
            Key.paintOutline: "000000",
            Key.paintFill: "F5A142",
            Key.paintAccent: "FFFFFF",
            Key.paintPattern: CoatPattern.tabby.rawValue,
        ])
    }

    var speed: Speed {
        get { Speed(rawValue: defaults.integer(forKey: Key.speed)) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.speed) }
    }

    var size: Size {
        get { Size(rawValue: defaults.integer(forKey: Key.size)) ?? .small }
        set { defaults.set(newValue.rawValue, forKey: Key.size) }
    }

    /// The cat may fall asleep when left alone (on the spot, or at a nap spot).
    var naps: Bool { get { bool(Key.naps) } set { set(newValue, Key.naps) } }
    var hideInFullScreen: Bool { get { bool(Key.hideInFullScreen) } set { set(newValue, Key.hideInFullScreen) } }
    /// Keep chasing even when the system's Reduce Motion setting is on.
    var ignoreReduceMotion: Bool { get { bool(Key.ignoreReduceMotion) } set { set(newValue, Key.ignoreReduceMotion) } }
    var paused: Bool { get { bool(Key.paused) } set { set(newValue, Key.paused) } }

    var spotWindows: Bool { get { bool(Key.spotWindows) } set { set(newValue, Key.spotWindows) } }
    var spotMenuBar: Bool { get { bool(Key.spotMenuBar) } set { set(newValue, Key.spotMenuBar) } }
    var spotDock: Bool { get { bool(Key.spotDock) } set { set(newValue, Key.spotDock) } }

    var boxOut: Bool { get { bool(Key.boxOut) } set { set(newValue, Key.boxOut) } }
    var boneOut: Bool { get { bool(Key.boneOut) } set { set(newValue, Key.boneOut) } }
    var touchBarCat: Bool { get { bool(Key.touchBarCat) } set { set(newValue, Key.touchBarCat) } }

    var sound: Bool { get { bool(Key.sound) } set { set(newValue, Key.sound) } }
    var volume: Float {
        get { defaults.float(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }
    /// How many cats (1…5).
    var catCount: Int {
        get { max(1, min(5, defaults.integer(forKey: Key.catCount))) }
        set { defaults.set(max(1, min(5, newValue)), forKey: Key.catCount) }
    }
    /// "auto" (seasonal), "none", "santa", "witch", "party".
    var hat: String {
        get { defaults.string(forKey: Key.hat) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.hat) }
    }
    /// Naps while you're away, sleepy late at night.
    var reacts: Bool { get { bool(Key.reacts) } set { set(newValue, Key.reacts) } }
    var yarnOut: Bool { get { bool(Key.yarnOut) } set { set(newValue, Key.yarnOut) } }
    /// Throwing the cat down hard on the MacBook's screen drops it into the Touch Bar.
    var slamToTouchBar: Bool { get { bool(Key.slamToTouchBar) } set { set(newValue, Key.slamToTouchBar) } }
    /// Flicking the cat up off the Touch Bar sends it to the desktop.
    var flickToDesktop: Bool { get { bool(Key.flickToDesktop) } set { set(newValue, Key.flickToDesktop) } }

    /// The coat from the coat painter.
    var paintedSkin: Skin {
        get {
            Skin(id: Skin.paintedID, title: "My Coat",
                 outline: RGBA(hex: defaults.string(forKey: Key.paintOutline) ?? "000000"),
                 fill: RGBA(hex: defaults.string(forKey: Key.paintFill) ?? "F5A142"),
                 accent: RGBA(hex: defaults.string(forKey: Key.paintAccent) ?? "FFFFFF"),
                 pattern: CoatPattern(rawValue: defaults.string(forKey: Key.paintPattern) ?? "") ?? .solid)
        }
        set {
            defaults.set(newValue.outline.hex, forKey: Key.paintOutline)
            defaults.set(newValue.fill.hex, forKey: Key.paintFill)
            defaults.set((newValue.accent ?? newValue.fill).hex, forKey: Key.paintAccent)
            defaults.set(newValue.pattern.rawValue, forKey: Key.paintPattern)
        }
    }

    var skin: String {
        get { defaults.string(forKey: Key.skin) ?? Skin.classicID }
        set { defaults.set(newValue, forKey: Key.skin) }
    }

    var customSheetPath: String? {
        get { defaults.string(forKey: Key.customSheet) }
        set { defaults.set(newValue, forKey: Key.customSheet) }
    }

    /// Where the cat was last seen (global, y-up), if saved.
    var lastPosition: CGPoint? {
        get { point(Key.posX, Key.posY) }
        set { setPoint(newValue, Key.posX, Key.posY) }
    }

    var boxPosition: CGPoint? {
        get { point(Key.boxX, Key.boxY) }
        set { setPoint(newValue, Key.boxX, Key.boxY) }
    }

    var bonePosition: CGPoint? {
        get { point(Key.boneX, Key.boneY) }
        set { setPoint(newValue, Key.boneX, Key.boneY) }
    }

    // MARK: - Storage

    private func bool(_ k: String) -> Bool { defaults.bool(forKey: k) }
    private func set(_ v: Bool, _ k: String) { defaults.set(v, forKey: k) }

    private func point(_ kx: String, _ ky: String) -> CGPoint? {
        guard defaults.object(forKey: kx) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: kx), y: defaults.double(forKey: ky))
    }

    private func setPoint(_ p: CGPoint?, _ kx: String, _ ky: String) {
        if let p {
            defaults.set(Double(p.x), forKey: kx)
            defaults.set(Double(p.y), forKey: ky)
        } else {
            defaults.removeObject(forKey: kx)
            defaults.removeObject(forKey: ky)
        }
    }

    private enum Key {
        static let speed = "speed", size = "size", naps = "naps"
        static let hideInFullScreen = "hideInFullScreen", ignoreReduceMotion = "ignoreReduceMotion"
        static let paused = "paused", posX = "positionX", posY = "positionY"
        static let spotWindows = "spotWindows", spotMenuBar = "spotMenuBar", spotDock = "spotDock"
        static let boxOut = "boxOut", boneOut = "boneOut", touchBarCat = "touchBarCat"
        static let skin = "skin", customSheet = "customSheetPath"
        static let boxX = "boxX", boxY = "boxY", boneX = "boneX", boneY = "boneY"
        static let sound = "sound", volume = "volume", catCount = "catCount", hat = "hat", reacts = "reacts"
        static let yarnOut = "yarnOut", slamToTouchBar = "slamToTouchBar", flickToDesktop = "flickToDesktop"
        static let paintOutline = "paintOutline", paintFill = "paintFill", paintAccent = "paintAccent"
        static let paintPattern = "paintPattern"
    }
}
