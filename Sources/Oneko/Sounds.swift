import AppKit

/// Neko's noises, synthesised in code at first use (no audio files): a purr for pets, a
/// mrrp for yeets and box hops, a meow on waking, a thud on hard landings, a sleepy
/// sigh when it dozes off, and thunder rolling in a storm.
final class SoundBox {
    enum Kind: CaseIterable { case purr, meow, mrrp, thud, sleep, thunder }

    var enabled = false
    var volume: Float = 0.6
    private var sounds: [Kind: NSSound] = [:]
    private var lastPlayed: [Kind: Double] = [:]

    /// Durations of every sound (synthesising them if needed); for the self-test.
    func durations() -> [TimeInterval] { Kind.allCases.map { sound($0).duration } }

    func play(_ kind: Kind) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let gap: Double = kind == .purr ? 1.1 : kind == .sleep ? 4 : kind == .thunder ? 3 : 0.25
        if let l = lastPlayed[kind], now - l < gap { return }
        lastPlayed[kind] = now
        let s = sound(kind)
        s.stop()
        // Dozing off is a quiet one; thunder stays in the background, under whatever you're playing.
        s.volume = volume * (kind == .sleep ? 0.7 : kind == .thunder ? 0.45 : 1)
        s.play()
    }

    /// The raw samples of a sound (44.1 kHz mono), e.g. to mix into a video's audio track.
    static func samples(_ kind: Kind) -> [Float] {
        switch kind {
        case .purr: return purr()
        case .meow: return meow()
        case .mrrp: return mrrp()
        case .thud: return thud()
        case .sleep: return sleep()
        case .thunder: return thunder()
        }
    }

    static let sampleRate: Float = 44_100

    /// 16-bit mono WAV data.
    static func wavData(_ samples: [Float]) -> Data { wav(samples) }

    private func sound(_ kind: Kind) -> NSSound {
        if let s = sounds[kind] { return s }
        let samples = Self.samples(kind)
        let s = NSSound(data: Self.wav(samples)) ?? NSSound()
        sounds[kind] = s
        return s
    }

    // MARK: - Synthesis (44.1 kHz mono)

    private static let rate: Float = 44_100

    private static func render(_ seconds: Float, _ f: (Float, Float) -> Float) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { i in
            let t = Float(i) / rate
            return f(t, t / seconds)
        }
    }

    /// Soft attack/release so nothing clicks.
    private static func envelope(_ p: Float, attack: Float = 0.08, release: Float = 0.25) -> Float {
        min(1, p / attack) * min(1, (1 - p) / release)
    }

    /// A soft purr: a breath out and a quieter breath in, each a gentle flutter of ~22
    /// little "rr" taps, warm (around 140–600 Hz) so laptop speakers play it softly.
    private static func purr() -> [Float] {
        var lp: Float = 0, slow: Float = 0, phase: Float = 0
        var rng = SystemRandomNumberGenerator()
        return render(1.25) { t, p in
            // Out-breath 0–0.55, tiny gap, in-breath 0.62–1 (softer).
            let breath: Float
            if p < 0.55 { breath = sin(.pi * p / 0.55) }
            else if p < 0.62 { breath = 0 }
            else { breath = 0.6 * sin(.pi * (p - 0.62) / 0.38) }
            let tap = pow(max(0, sin(2 * .pi * 22 * t)), 4)            // the flutter
            let noise = Float.random(in: -1...1, using: &rng)
            lp += 0.12 * (noise - lp)
            slow += 0.015 * (lp - slow)
            phase += 2 * .pi * 140 / rate
            let tone = 0.5 * sin(phase) + 0.25 * sin(2 * phase)
            return ((lp - slow) * 2.2 + tone) * tap * breath * 0.38
        }
    }

    /// "Mi-aow": pitch rises then falls; the vowel opens up.
    private static func meow() -> [Float] {
        var phase: Float = 0
        return render(0.62) { t, p in
            let f0 = 520 + 330 * sin(.pi * min(1, p * 1.35)) - 120 * p + 9 * sin(2 * .pi * 6 * t)
            phase += 2 * .pi * f0 / rate
            let open = sin(.pi * p)                     // "m" → "ow"
            var s: Float = 0
            for h in 1...6 {
                let weight = h == 1 ? 1 : (0.35 + 0.5 * open) / Float(h)
                s += weight * sin(phase * Float(h))
            }
            return s * envelope(p, attack: 0.06, release: 0.35) * 0.32
        }
    }

    /// A short rolling trill going up: "mrrp?"
    private static func mrrp() -> [Float] {
        var phase: Float = 0
        return render(0.34) { t, p in
            let f0 = 340 + 300 * p
            phase += 2 * .pi * f0 / rate
            let trill = 0.55 + 0.45 * sin(2 * .pi * 32 * t)
            let s = sin(phase) + 0.4 * sin(2 * phase) + 0.2 * sin(3 * phase)
            return s * trill * envelope(p, attack: 0.05, release: 0.3) * 0.3
        }
    }

    /// A soft body landing: a short, dull knock that laptop speakers can play.
    private static func thud() -> [Float] {
        var phase: Float = 0, lp: Float = 0
        var rng = SystemRandomNumberGenerator()
        return render(0.22) { _, p in
            let f0 = 190 - 90 * p
            phase += 2 * .pi * f0 / rate
            lp += 0.3 * (Float.random(in: -1...1, using: &rng) - lp)
            let knock = lp * max(0, 1 - p * 7) * 0.9
            let body = (sin(phase) + 0.35 * sin(2 * phase)) * exp(-p * 7)
            return (body + knock) * 0.75
        }
    }

    /// Dozing off: a little yawn sliding down, then a slow sleepy breath with a tiny
    /// whistle on the way out ("hmmm… zzz").
    private static func sleep() -> [Float] {
        var phase: Float = 0, whistle: Float = 0, lp: Float = 0
        var rng = SystemRandomNumberGenerator()
        return render(2.2) { t, p in
            var s: Float = 0
            if p < 0.3 {                                    // the yawn: "hmmm" sliding down
                let q = p / 0.3
                let f0 = 420 - 170 * q
                phase += 2 * .pi * f0 / rate
                s += (sin(phase) + 0.3 * sin(2 * phase)) * sin(.pi * q) * 0.3
            }
            if p > 0.38 {                                   // breathing in…
                let q = (p - 0.38) / 0.62
                lp += 0.05 * (Float.random(in: -1...1, using: &rng) - lp)
                s += lp * 1.6 * sin(.pi * q) * 0.35
                if q > 0.55 {                               // …and a tiny whistle out
                    let w = (q - 0.55) / 0.45
                    whistle += 2 * .pi * (880 - 260 * w) / rate
                    s += sin(whistle) * sin(.pi * w) * 0.07
                }
            }
            _ = t
            return s * envelope(p, attack: 0.04, release: 0.2)
        }
    }

    /// Thunder some way off: a soft crack, then a low rumble that rolls a few times and
    /// fades. Low and soft, so it sits in the background.
    private static func thunder() -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var lp1: Float = 0, lp2: Float = 0, hp: Float = 0, crack: Float = 0
        let rolls = (0..<5).map { _ in (at: Float.random(in: 0.04...0.65, using: &rng), height: Float.random(in: 0.4...1, using: &rng)) }
        var s = render(4.2) { t, p in
            let n = Float.random(in: -1...1, using: &rng)
            lp1 += 0.03 * (n - lp1)                 // brown-ish noise: the rumble
            lp2 += 0.03 * (lp1 - lp2)
            hp += 0.002 * (lp2 - hp)                // minus the sub-bass speakers can't play
            var swell: Float = 0.3
            for r in rolls where p > r.at { swell += r.height * exp(-(p - r.at) * 7) }
            crack += 0.6 * (n - crack)
            let snap = crack * max(0, 1 - t * 10) * 0.12
            return ((lp2 - hp) * swell * exp(-p * 1.3) + snap) * envelope(p, attack: 0.005, release: 0.35)
        }
        let peak = s.map(abs).max() ?? 1
        if peak > 0 { s = s.map { $0 / peak * 0.6 } }
        return s
    }

    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)   // PCM, mono
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_000))) }
        return d
    }
}

/// Neko's lifetime stats, kept in UserDefaults.
final class Stats {
    enum Key: String, CaseIterable {
        case pets, yeets, fetches, windowBonks, dockYeets, boxNaps, yarnBats, touchBarTrips, meals, playdates, highestYeet
        var title: String {
            switch self {
            case .pets: return "Pets"
            case .yeets: return "Yeets"
            case .fetches: return "Fetches"
            case .windowBonks: return "Window bonks"
            case .dockYeets: return "Dock yeets"
            case .boxNaps: return "Box naps"
            case .yarnBats: return "Yarn bats"
            case .touchBarTrips: return "Touch Bar trips"
            case .meals: return "Meals"
            case .playdates: return "Playdates"
            case .highestYeet: return "Highest yeet"
            }
        }
    }

    private let defaults: UserDefaults
    private var values: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: "stats") as? [String: Int] ?? [:]
    }

    subscript(_ k: Key) -> Int { values[k.rawValue] ?? 0 }

    func bump(_ k: Key, by n: Int = 1) {
        values[k.rawValue, default: 0] += n
        save()
    }

    func record(_ k: Key, max v: Int) {
        guard v > self[k] else { return }
        values[k.rawValue] = v
        save()
    }

    func reset() {
        values = [:]
        save()
    }

    func line(_ k: Key) -> String {
        k == .highestYeet ? "\(k.title): \(self[k]) pt" : "\(k.title): \(self[k])"
    }

    private func save() { defaults.set(values, forKey: "stats") }
}
