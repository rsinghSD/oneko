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
            Key.dockBonk: true,
            Key.catsPlay: true,
            Key.weather: "live",
            Key.autoUpdateCheck: true,
            Key.sleepiness: Sleepiness.sometimes.rawValue,
            Key.dockFloor: DockFloor.top.rawValue,
            Key.explores: true,
            Key.scratchesWindows: true,
            Key.bumping: Bumping.normal.rawValue,
        ])
        // 0.5.7: one box became any number of toys.
        if defaults.object(forKey: Key.boxCount) == nil {
            defaults.set(defaults.bool(forKey: Key.boxOut) ? 1 : 0, forKey: Key.boxCount)
            if let p = point(Key.boxX, Key.boxY) { boxPositions = [p] }
        }
        // 0.5.8: one bone / one ball of yarn became any number.
        if defaults.object(forKey: Key.boneCount) == nil {
            defaults.set(defaults.bool(forKey: Key.boneOut) ? 1 : 0, forKey: Key.boneCount)
            if let p = point(Key.boneX, Key.boneY) { bonePositions = [p] }
        }
        if defaults.object(forKey: Key.yarnCount) == nil {
            defaults.set(defaults.bool(forKey: Key.yarnOut) ? 1 : 0, forKey: Key.yarnCount)
        }
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

    /// How much the cats sleep (when naps are on).
    enum Sleepiness: Int, CaseIterable {
        case rarely = 1, sometimes = 2, often = 3, very = 4
        var title: String {
            switch self {
            case .rarely: return "Rarely"
            case .sometimes: return "Now and Then"
            case .often: return "Often (classic)"
            case .very: return "Very Sleepy"
            }
        }
        /// Relative to classic oneko (1): how often it dozes off and nods off somewhere.
        var factor: CGFloat {
            switch self {
            case .rarely: return 0.25
            case .sometimes: return 0.5
            case .often: return 1
            case .very: return 2
            }
        }
    }
    /// 0.6.5: classic oneko slept a lot; "Now and Then" is the new default.
    var sleepiness: Sleepiness {
        get { Sleepiness(rawValue: defaults.integer(forKey: Key.sleepiness)) ?? .sometimes }
        set { defaults.set(newValue.rawValue, forKey: Key.sleepiness) }
    }

    /// The Dock: something to stand on, or not there at all (walk on the ground in front of it).
    enum DockFloor: String, CaseIterable {
        case top, ground
        var title: String {
            switch self {
            case .top: return "Stand on top of the Dock"
            case .ground: return "Walk on the ground, in front of the Dock"
            }
        }
    }
    var dockFloor: DockFloor {
        get { DockFloor(rawValue: defaults.string(forKey: Key.dockFloor) ?? "") ?? .top }
        set { defaults.set(newValue.rawValue, forKey: Key.dockFloor) }
    }

    /// Left alone, cats go off on their own: climb up windows, stroll along title bars and
    /// the menu bar.
    var explores: Bool { get { bool(Key.explores) } set { set(newValue, Key.explores) } }
    /// How cats bump into each other.
    enum Bumping: String, CaseIterable {
        case off, gentle, normal, crazy, chaos
        var title: String {
            switch self {
            case .off: return "Off (they walk through each other)"
            case .gentle: return "Gentle"
            case .normal: return "Normal"
            case .crazy: return "Crazy (much harder, bouncier)"
            case .chaos: return "Total Chaos (pinball)"
            }
        }
        var style: CatCollisions.Style {
            switch self {
            case .off: return .off
            case .gentle: return .gentle
            case .normal: return .normal
            case .crazy: return .crazy
            case .chaos: return .chaos
            }
        }
    }
    var bumping: Bumping {
        get { Bumping(rawValue: defaults.string(forKey: Key.bumping) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.bumping) }
    }

    /// Exploring, it stops to scratch the edges of windows.
    var scratchesWindows: Bool { get { bool(Key.scratchesWindows) } set { set(newValue, Key.scratchesWindows) } }

    /// Sizes of their own for the first cats (index = cat id, 0 = the first cat; 0 = the
    /// Size setting).
    static let maxSizedCats = 10
    var catSizes: [Int] {
        get { (defaults.array(forKey: Key.catSizes) as? [Int] ?? []).map { (0...3).contains($0) ? $0 : 0 } }
        set { defaults.set(Array(newValue.prefix(Self.maxSizedCats)), forKey: Key.catSizes) }
    }
    /// The size cat `id` is drawn at (1×, 2× or 3×).
    func size(ofCat id: Int) -> Int {
        let own = id < Self.maxSizedCats ? (catSizes[safe: id] ?? 0) : 0
        return own > 0 ? own : size.rawValue
    }
    var hideInFullScreen: Bool { get { bool(Key.hideInFullScreen) } set { set(newValue, Key.hideInFullScreen) } }
    /// Keep chasing even when the system's Reduce Motion setting is on.
    var ignoreReduceMotion: Bool { get { bool(Key.ignoreReduceMotion) } set { set(newValue, Key.ignoreReduceMotion) } }
    var paused: Bool { get { bool(Key.paused) } set { set(newValue, Key.paused) } }

    var spotWindows: Bool { get { bool(Key.spotWindows) } set { set(newValue, Key.spotWindows) } }
    var spotMenuBar: Bool { get { bool(Key.spotMenuBar) } set { set(newValue, Key.spotMenuBar) } }
    var spotDock: Bool { get { bool(Key.spotDock) } set { set(newValue, Key.spotDock) } }

    /// Real boxes (you can carry, throw and shut them) stop here; the rest are a heap on
    /// the floor drawn by the graphics chip.
    static let maxRealBoxes = 50
    static let maxBoxes = 1_000_000

    /// How many cardboard boxes are out (0 = none), up to a million.
    var boxCount: Int {
        get { max(0, min(Self.maxBoxes, defaults.integer(forKey: Key.boxCount))) }
        set {
            let n = max(0, min(Self.maxBoxes, newValue))
            if n > 0 { defaults.set(n, forKey: Key.lastBoxCount) }
            defaults.set(n, forKey: Key.boxCount)
        }
    }
    /// The count to bring back when you turn boxes on again from the menu.
    var lastBoxCount: Int { max(1, min(Self.maxBoxes, defaults.integer(forKey: Key.lastBoxCount))) }
    var realBoxCount: Int { min(boxCount, Self.maxRealBoxes) }
    var heapBoxCount: Int { max(0, boxCount - Self.maxRealBoxes) }
    var boxOut: Bool { boxCount > 0 }
    /// Where the real boxes were left (global, y-up).
    var boxPositions: [CGPoint] {
        get { points(Key.boxPositions) }
        set { setPoints(newValue, Key.boxPositions) }
    }
    /// The first box is a big one that fits 4 cats.
    var bigBox: Bool { get { bool(Key.bigBox) } set { set(newValue, Key.bigBox) } }
    /// "auto" (snow in winter, leaves in autumn), "off", "snow" or "leaves".
    var weather: String {
        get { defaults.string(forKey: Key.weather) ?? "live" }
        set { defaults.set(newValue, forKey: Key.weather) }
    }
    /// Look for a newer Oneko on GitHub once a day.
    var autoUpdateCheck: Bool { get { bool(Key.autoUpdateCheck) } set { set(newValue, Key.autoUpdateCheck) } }
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }
    /// "Skip This Version": don't offer this one again (checking from the menu still shows it).
    var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        set { defaults.set(newValue, forKey: Key.skippedVersion) }
    }
    /// Names you gave cats (cat id -> name; cat 0 is the first cat).
    var catNames: [String: String] {
        get { defaults.dictionary(forKey: Key.catNames) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.catNames) }
    }
    /// Cats sitting next to each other now and then groom, play-fight or chase each other.
    var catsPlay: Bool { get { bool(Key.catsPlay) } set { set(newValue, Key.catsPlay) } }
    /// An auto-hiding Dock popping up bonks cats (and toys) sitting where it appears.
    var dockBonk: Bool { get { bool(Key.dockBonk) } set { set(newValue, Key.dockBonk) } }
    /// Bones and balls of yarn: each one is a real toy (its own little window), up to 50.
    static let maxBones = 50
    static let maxYarns = 50
    var boneCount: Int {
        get { max(0, min(Self.maxBones, defaults.integer(forKey: Key.boneCount))) }
        set {
            let n = max(0, min(Self.maxBones, newValue))
            if n > 0 { defaults.set(n, forKey: Key.lastBoneCount) }
            defaults.set(n, forKey: Key.boneCount)
        }
    }
    var lastBoneCount: Int { max(1, min(Self.maxBones, defaults.integer(forKey: Key.lastBoneCount))) }
    var boneOut: Bool { boneCount > 0 }
    var yarnCount: Int {
        get { max(0, min(Self.maxYarns, defaults.integer(forKey: Key.yarnCount))) }
        set {
            let n = max(0, min(Self.maxYarns, newValue))
            if n > 0 { defaults.set(n, forKey: Key.lastYarnCount) }
            defaults.set(n, forKey: Key.yarnCount)
        }
    }
    var lastYarnCount: Int { max(1, min(Self.maxYarns, defaults.integer(forKey: Key.lastYarnCount))) }
    /// Food bowls (cats get hungry every 20–40 minutes).
    static let maxBowls = 10
    var bowlCount: Int {
        get { max(0, min(Self.maxBowls, defaults.integer(forKey: Key.bowlCount))) }
        set { defaults.set(max(0, min(Self.maxBowls, newValue)), forKey: Key.bowlCount) }
    }
    var bowlPositions: [CGPoint] {
        get { points(Key.bowlPositions) }
        set { setPoints(newValue, Key.bowlPositions) }
    }
    var yarnOut: Bool { yarnCount > 0 }
    /// Where the bones were left (global, y-up).
    var bonePositions: [CGPoint] {
        get { points(Key.bonePositions) }
        set { setPoints(newValue, Key.bonePositions) }
    }
    var touchBarCat: Bool { get { bool(Key.touchBarCat) } set { set(newValue, Key.touchBarCat) } }

    var sound: Bool { get { bool(Key.sound) } set { set(newValue, Key.sound) } }
    var volume: Float {
        get { defaults.float(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }
    /// In crowd mode, every cat past this many is a crowd cat.
    static let crowdAfter = 50
    /// Real cats (each its own window and physics) stop here, so a saved count can never
    /// make Oneko too heavy to even launch.
    static let maxRealCats = 10_000
    /// Crowd mode goes up to this many in all.
    static let maxCrowdCats = 1_000_000

    /// How many cats: up to 10,000 real cats, or up to 1,000,000 in crowd mode.
    var catCount: Int {
        get { max(0, min(crowdMode ? Self.maxCrowdCats : Self.maxRealCats, defaults.integer(forKey: Key.catCount))) }
        set { defaults.set(max(0, min(crowdMode ? Self.maxCrowdCats : Self.maxRealCats, newValue)), forKey: Key.catCount) }
    }
    /// Optional, the nuts.wad switch: cats past 50 are crowd cats (GPU-drawn, click-through,
    /// light on resources). Off, every cat is a real cat.
    var crowdMode: Bool { get { bool(Key.crowdMode) } set { set(newValue, Key.crowdMode) } }
    /// Cats you can pet, yeet and park.
    var realCatCount: Int { crowdMode ? min(catCount, Self.crowdAfter) : catCount }
    /// Cats drawn by the graphics chip.
    var crowdCatCount: Int { crowdMode ? max(0, catCount - Self.crowdAfter) : 0 }

    enum CatBehavior: String, CaseIterable {
        case swarm, conga, roam
        var title: String {
            switch self {
            case .swarm: return "Swarm (each chases your cursor)"
            case .conga: return "Conga line (follow the one in front)"
            case .roam: return "Free roam (wander and nap)"
            }
        }
    }
    /// What the extra cats do.
    var catBehavior: CatBehavior {
        get { CatBehavior(rawValue: defaults.string(forKey: Key.catBehavior) ?? "") ?? .swarm }
        set { defaults.set(newValue.rawValue, forKey: Key.catBehavior) }
    }

    enum CoatMode: String, CaseIterable {
        case rotate, same, random, custom
        var title: String {
            switch self {
            case .rotate: return "Take turns with the other coats"
            case .same: return "Same coat as the first cat"
            case .random: return "A random coat each"
            case .custom: return "Choose for each cat"
            }
        }
    }
    /// What the extra cats wear.
    var coatMode: CoatMode {
        get { CoatMode(rawValue: defaults.string(forKey: Key.coatMode) ?? "") ?? .rotate }
        set { defaults.set(newValue.rawValue, forKey: Key.coatMode) }
    }
    /// Custom coats for cats 2, 3, … (skin ids; "" = take turns).
    var customCoats: [String] {
        get { defaults.stringArray(forKey: Key.customCoats) ?? [] }
        set { defaults.set(newValue, forKey: Key.customCoats) }
    }
    /// The version whose What's New window was last shown (nil: before 0.5.7, or never).
    var lastSeenVersion: String? {
        get { defaults.string(forKey: Key.lastSeenVersion) }
        set { defaults.set(newValue, forKey: Key.lastSeenVersion) }
    }
    /// Show What's New on this launch? Only after an update: a fresh install gets How to
    /// Play instead, and each version is shown once.
    func shouldShowWhatsNew(current: String) -> Bool {
        seenWelcome && lastSeenVersion != current
    }
    /// The How to Play window has been shown once.
    var seenWelcome: Bool { get { bool(Key.seenWelcome) } set { set(newValue, Key.seenWelcome) } }
    /// "auto" (seasonal), "none", "santa", "witch", "party".
    var hat: String {
        get { defaults.string(forKey: Key.hat) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.hat) }
    }
    /// Naps while you're away, sleepy late at night.
    var reacts: Bool { get { bool(Key.reacts) } set { set(newValue, Key.reacts) } }
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


    // MARK: - Storage

    private func bool(_ k: String) -> Bool { defaults.bool(forKey: k) }
    private func set(_ v: Bool, _ k: String) { defaults.set(v, forKey: k) }

    private func points(_ k: String) -> [CGPoint] {
        let a = defaults.array(forKey: k) as? [Double] ?? []
        return stride(from: 0, to: a.count - 1, by: 2).map { CGPoint(x: a[$0], y: a[$0 + 1]) }
    }

    private func setPoints(_ p: [CGPoint], _ k: String) {
        defaults.set(p.flatMap { [Double($0.x), Double($0.y)] }, forKey: k)
    }

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
        static let crowdMode = "crowdMode", catBehavior = "catBehavior", coatMode = "coatMode"
        static let customCoats = "customCoats", seenWelcome = "seenWelcome"
        static let boxCount = "boxCount", lastBoxCount = "lastBoxCount", boxPositions = "boxPositions"
        static let dockBonk = "dockBonk", lastSeenVersion = "lastSeenVersion"
        static let boneCount = "boneCount", lastBoneCount = "lastBoneCount", bonePositions = "bonePositions"
        static let yarnCount = "yarnCount", lastYarnCount = "lastYarnCount"
        static let bowlCount = "bowlCount", bowlPositions = "bowlPositions"
        static let bigBox = "bigBox", catsPlay = "catsPlay", weather = "weather", catNames = "catNames"
        static let sleepiness = "sleepiness", dockFloor = "dockFloor", explores = "explores", catSizes = "catSizes"
        static let scratchesWindows = "scratchesWindows", bumping = "bumping"
        static let autoUpdateCheck = "autoUpdateCheck", lastUpdateCheck = "lastUpdateCheck", skippedVersion = "skippedVersion"
    }
}
