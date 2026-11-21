import Foundation

/// Every cat has a name: the first is Neko, the rest come from a long list (the same cat
/// always gets the same name), and you can rename any of them.
enum CatNames {
    static let names = [
        "Mochi", "Tofu", "Miso", "Sushi", "Biscuit", "Pickles", "Waffles", "Noodle", "Pumpkin", "Ginger",
        "Pepper", "Mittens", "Socks", "Boots", "Whiskers", "Luna", "Nova", "Pixel", "Byte", "Cookie",
        "Muffin", "Peanut", "Bean", "Olive", "Basil", "Sage", "Clover", "Maple", "Hazel", "Juniper",
        "Toast", "Bagel", "Dumpling", "Wasabi", "Nori", "Udon", "Ramen", "Taro", "Kiwi", "Mango",
        "Smokey", "Shadow", "Ash", "Cinder", "Ember", "Blaze", "Comet", "Orbit", "Rocket", "Zoom",
        "Fluff", "Puff", "Marshmallow", "Snowball", "Cotton", "Button", "Bubbles", "Jellybean", "Gumdrop", "Sprinkles",
        "Oscar", "Felix", "Milo", "Leo", "Simba", "Tiger", "Oliver", "Jasper", "Theo", "Finn",
        "Cleo", "Nala", "Lily", "Daisy", "Rosie", "Willow", "Pearl", "Ruby", "Opal", "Bella",
        "Sir Pounce", "Lord Fluff", "Captain", "Admiral", "Duchess", "Baron", "Professor", "Doctor", "Chairman Meow", "Mr. Beans",
        "Chonk", "Loaf", "Bean Bag", "Furball", "Purrito", "Catniss", "Meowth", "Kitkat", "Tabby", "Scratch",
    ]

    /// The name cat `id` goes by (0 is the first cat), unless you renamed it.
    static func name(_ id: Int, custom: [String: String] = [:]) -> String {
        if let n = custom[String(id)], !n.isEmpty { return n }
        if id == 0 { return "Neko" }
        let n = names[(id - 1) % names.count]
        let round = (id - 1) / names.count
        return round == 0 ? n : "\(n) \(roman(round + 1))"
    }

    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }
}

/// Stats for each cat (pets, yeets, naps…), kept in UserDefaults. Saved now and then, not
/// on every pet, so a big swarm doesn't hammer the disk.
final class CatStats {
    enum Key: String, CaseIterable {
        case pets, yeets, naps, fetches, meals, playdates
        var title: String {
            switch self {
            case .pets: return "pets"
            case .yeets: return "yeets"
            case .naps: return "box naps"
            case .fetches: return "fetches"
            case .meals: return "meals"
            case .playdates: return "playdates"
            }
        }
        /// For the leaderboard.
        var champion: String {
            switch self {
            case .pets: return "Most petted"
            case .yeets: return "Most yeeted"
            case .naps: return "Box napper"
            case .fetches: return "Best fetcher"
            case .meals: return "Biggest eater"
            case .playdates: return "Most playful"
            }
        }
    }

    private let defaults: UserDefaults
    /// cat id -> stat -> count.
    private var values: [String: [String: Int]]
    private var dirty = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: "catStats") as? [String: [String: Int]] ?? [:]
    }

    func bump(_ k: Key, cat id: Int) {
        values[String(id), default: [:]][k.rawValue, default: 0] += 1
        dirty = true
    }

    func value(_ k: Key, cat id: Int) -> Int { values[String(id)]?[k.rawValue] ?? 0 }

    /// "12 pets · 3 yeets" (the cat's top few, or nothing yet).
    func summary(cat id: Int) -> String {
        let parts = Key.allCases.compactMap { k -> (Int, String)? in
            let v = value(k, cat: id)
            return v > 0 ? (v, "\(v) \(k.title)") : nil
        }.sorted { $0.0 > $1.0 }.prefix(3).map(\.1)
        return parts.joined(separator: " · ")
    }

    /// The cat with the most of `k` (among the first `count` cats), if any has some.
    func champion(_ k: Key, among count: Int) -> (id: Int, value: Int)? {
        var best: (Int, Int)?
        for (key, stats) in values {
            guard let id = Int(key), id < count, let v = stats[k.rawValue], v > 0 else { continue }
            if v > (best?.1 ?? 0) || (v == best?.1 && id < best!.0) { best = (id, v) }
        }
        return best.map { (id: $0.0, value: $0.1) }
    }

    func reset() {
        values = [:]
        dirty = true
        save()
    }

    /// Write out if anything changed (the app calls this every few seconds and at quit).
    func save() {
        guard dirty else { return }
        dirty = false
        defaults.set(values, forKey: "catStats")
    }
}
