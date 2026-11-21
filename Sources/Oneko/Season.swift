import AppKit

/// Weather falling from the top of the screen, on the desktop behind your windows: your real
/// weather right now (rain, a thunderstorm, sun, snow), the season's (snow in winter, leaves
/// in autumn), or one you picked. Drawn by a Core Animation emitter (the window server does
/// the work, so it costs Oneko next to nothing).
final class SeasonOverlay {
    enum Weather: String, CaseIterable {
        case snow, leaves, rain, thunder, sunny
        var title: String {
            switch self {
            case .snow: return "Snow"
            case .leaves: return "Falling Leaves"
            case .rain: return "Rain"
            case .thunder: return "Thunderstorm"
            case .sunny: return "Sunny"
            }
        }
    }

    /// The setting → what's falling now. "live": your local weather (nil until it's known,
    /// and under clouds or a clear night sky); "auto": by the date; "off"; or a weather by name.
    static func weather(_ setting: String, date: Date = Date(), live: Weather? = nil) -> Weather? {
        switch setting {
        case "off": return nil
        case "live": return live
        case "auto":
            switch Calendar.current.component(.month, from: date) {
            case 12, 1, 2: return .snow
            case 10, 11: return .leaves
            default: return nil
            }
        default: return Weather(rawValue: setting)
        }
    }

    private var weather: Weather
    /// One overlay per display (a list: CGRect isn't hashable before macOS 15).
    private var windows: [(frame: CGRect, window: SeasonWindow)] = []
    private var lightning: Timer?

    /// `thunder`: plays the rumble (the app's sounds, so it follows the sound setting).
    init(_ weather: Weather, thunder: @escaping () -> Void = {}) {
        self.weather = weather
        if weather == .thunder {   // a flash now and then (about every 12 s), the rumble a moment later
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, Dice.roll(12) == 0,
                      let w = self.windows.filter({ $0.window.isVisible }).randomElement()?.window else { return }
                w.strike()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(Dice.roll(20)) / 10, execute: thunder)
            }
            RunLoop.main.add(t, forMode: .common)
            lightning = t
        }
    }

    var current: Weather { weather }

    /// Displays to cover, and displays to skip (running something full screen).
    func update(screens: [CGRect], hidden: [CGRect]) {
        // One overlay per display, rebuilt when displays change.
        for (f, w) in windows where !screens.contains(f) { w.orderOut(nil); w.close() }
        windows.removeAll { !screens.contains($0.frame) }
        for f in screens where !windows.contains(where: { $0.frame == f }) {
            windows.append((f, SeasonWindow(frame: f, weather: weather)))
        }
        for (f, w) in windows {
            let hide = hidden.contains(f)
            if hide { if w.isVisible { w.orderOut(nil) } } else if !w.isVisible { w.orderFrontRegardless() }
        }
    }

    func stop() {
        lightning?.invalidate()
        lightning = nil
        for (_, w) in windows { w.orderOut(nil); w.close() }
        windows = []
    }
}

/// Your weather right now: the rough location your IP address gives (ipwho.is), then the
/// current weather there (Open-Meteo). No account, no key and no location permission. Asked
/// every 30 minutes while live weather is on (the location every 6 hours).
final class LiveWeather {
    static let shared = LiveWeather()

    /// What it's doing outside (nil: not known yet, cloudy or foggy, or a clear night).
    private(set) var current: SeasonOverlay.Weather?
    private var checked: Date?
    private var located: (lat: Double, lon: Double, at: Date)?
    private var busy = false
    private var failed = false

    /// WMO weather code (as Open-Meteo reports it) → what falls.
    static func weather(code: Int, isDay: Bool) -> SeasonOverlay.Weather? {
        switch code {
        case 95...99: return .thunder                  // thunderstorm (with or without hail)
        case 51...67, 80...82: return .rain            // drizzle, rain, freezing rain, showers
        case 71...77, 85, 86: return .snow             // snow, snow grains, snow showers
        case 0, 1: return isDay ? .sunny : nil         // clear, mainly clear
        default: return nil                            // clouds, fog
        }
    }

    /// Ask again if it's been a while (every 30 minutes; 5 after a failure).
    func refreshIfDue() {
        guard !busy else { return }
        if let c = checked, Date().timeIntervalSince(c) < (failed ? 300 : 1800) { return }
        busy = true
        checked = Date()
        locate { [weak self] loc in
            guard let self else { return }
            guard let loc else { self.finish(nil); return }
            var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            c.queryItems = [URLQueryItem(name: "latitude", value: String(format: "%.2f", loc.lat)),
                            URLQueryItem(name: "longitude", value: String(format: "%.2f", loc.lon)),
                            URLQueryItem(name: "current", value: "weather_code,is_day")]
            Self.get(c.url!) { j in
                guard let now = j?["current"] as? [String: Any], let code = (now["weather_code"] as? NSNumber)?.intValue
                else { self.finish(nil); return }
                self.finish(Self.weather(code: code, isDay: (now["is_day"] as? NSNumber)?.intValue != 0))
            }
        }
    }

    private func finish(_ w: SeasonOverlay.Weather??) {
        busy = false
        if let w { current = w; failed = false } else { failed = true }   // offline: keep the last weather
    }

    /// Where you roughly are (the city your IP address is registered to).
    private func locate(_ done: @escaping ((lat: Double, lon: Double)?) -> Void) {
        if let l = located, Date().timeIntervalSince(l.at) < 6 * 3600 { done((l.lat, l.lon)); return }
        Self.get(URL(string: "https://ipwho.is/")!) { [weak self] j in
            guard let j, (j["success"] as? Bool) != false,
                  let lat = (j["latitude"] as? NSNumber)?.doubleValue, let lon = (j["longitude"] as? NSNumber)?.doubleValue
            else { done(nil); return }
            self?.located = (lat, lon, Date())
            done((lat, lon))
        }
    }

    /// A JSON object from `url`, on the main thread (nil if it didn't come).
    private static func get(_ url: URL, _ done: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Oneko", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
        }.resume()
    }
}

/// A full-display, click-through overlay with the emitter (and, in a storm, the lightning).
private final class SeasonWindow: NSPanel {
    private let emitter = CAEmitterLayer()
    private let flash = CALayer()
    private let bolt = CALayer()

    init(frame: CGRect, weather: SeasonOverlay.Weather) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // On the desktop, just above its icons: behind every app window (and every cat), so
        // the weather never falls over what you're working on.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(emitter)
        contentView = view
        setFrame(frame, display: false)

        emitter.frame = view.bounds
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: frame.width / 2, y: frame.height + 10)
        emitter.emitterSize = CGSize(width: frame.width, height: 1)
        emitter.renderMode = .unordered
        let scale = NSScreen.screens.first { $0.frame == frame }?.backingScaleFactor ?? 2
        emitter.contentsScale = scale
        let wide = max(1, Float(frame.width) / 1500)   // the same density on any display
        switch weather {
        case .snow: emitter.emitterCells = [Self.flake(big: false), Self.flake(big: true)]
        case .leaves: emitter.emitterCells = Self.leaves()
        case .rain: emitter.emitterCells = [Self.drop(rate: 45 * wide)]
        case .thunder: emitter.emitterCells = [Self.drop(rate: 90 * wide, fast: true)]
        case .sunny:
            // Glints of sunlight drifting down from the top, not falling.
            emitter.emitterPosition = CGPoint(x: frame.width / 2, y: frame.height - 40)
            emitter.emitterSize = CGSize(width: frame.width, height: 80)
            emitter.emitterShape = .rectangle
            emitter.emitterCells = [Self.glint()]
        }
        // Settle in gently: start with a sky that's already going.
        emitter.beginTime = CACurrentMediaTime() - 30

        if weather == .thunder {
            flash.frame = view.bounds
            flash.backgroundColor = CGColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
            flash.opacity = 0
            view.layer?.addSublayer(flash)
            let a = PixelArt.fromRows(Self.boltRows, palette: ["y": RGBA(r: 255, g: 244, b: 170), "w": RGBA(r: 255, g: 255, b: 255)])
            bolt.contents = a.image
            bolt.magnificationFilter = .nearest
            bolt.bounds = CGRect(x: 0, y: 0, width: CGFloat(a.width) * 4, height: CGFloat(a.height) * 4)
            bolt.opacity = 0
            view.layer?.addSublayer(bolt)
        }
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Lightning: a bolt at the top of the display and a faint double flicker of the sky
    /// (just the bolt with Reduce Motion on).
    func strike() {
        let w = frame.width, h = frame.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bolt.position = CGPoint(x: CGFloat(Dice.roll(Int(max(1, w - 200)))) + 100, y: h - bolt.bounds.height / 2)
        CATransaction.commit()
        func flicker(_ peak: Float) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, peak, 0, peak * 0.7, 0]
            a.keyTimes = [0, 0.1, 0.3, 0.45, 1]
            a.duration = 0.6
            return a
        }
        bolt.add(flicker(1), forKey: "strike")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { flash.add(flicker(0.1), forKey: "strike") }
    }

    // MARK: - Art

    private static func image(_ rows: [String], _ palette: [Character: RGBA]) -> CGImage {
        PixelArt.fromRows(rows, palette: palette).image
    }

    private static let boltRows = [
        "   yy",
        "  yy ",
        " yyw ",
        " ywy ",
        "yyyyy",
        "  wy ",
        "  yy ",
        " yy  ",
        " y   ",
    ]

    private static func flake(big: Bool) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image(big ? [" w ", "www", " w "] : ["w"], ["w": RGBA(r: 255, g: 255, b: 255, a: 235)])
        c.birthRate = big ? 2 : 5
        c.lifetime = 40
        c.velocity = big ? 36 : 26
        c.velocityRange = 10
        c.emissionLongitude = -.pi / 2
        c.emissionRange = 0.4
        c.xAcceleration = 2
        c.scale = big ? 1.4 : 2
        c.scaleRange = 0.4
        c.alphaSpeed = -0.01
        c.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        return c
    }

    /// A raindrop: a short pale-blue streak, falling fast and a little slanted.
    private static func drop(rate: Float, fast: Bool = false) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image(["b", "b", "b", "l"], ["b": RGBA(r: 170, g: 200, b: 240, a: 150), "l": RGBA(r: 215, g: 232, b: 255, a: 210)])
        c.birthRate = rate
        c.lifetime = 6
        c.velocity = fast ? 620 : 480
        c.velocityRange = 80
        c.emissionLongitude = -.pi / 2 - 0.12
        c.emissionRange = 0.03
        c.yAcceleration = -200
        c.scale = 2
        c.scaleRange = 0.5
        c.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        return c
    }

    /// A glint of sunlight: a little warm sparkle that drifts and twinkles out.
    private static func glint() -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image([" y ", "ywy", " y "], ["y": RGBA(r: 255, g: 214, b: 110, a: 200), "w": RGBA(r: 255, g: 250, b: 225)])
        c.birthRate = 1.5
        c.lifetime = 9
        c.lifetimeRange = 3
        c.velocity = 10
        c.velocityRange = 6
        c.emissionLongitude = -.pi / 2 - 0.4
        c.emissionRange = 0.6
        c.scale = 1.6
        c.scaleRange = 0.6
        c.alphaSpeed = -0.11
        c.spin = 0.4
        c.spinRange = 0.8
        c.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        return c
    }

    private static func leaves() -> [CAEmitterCell] {
        let colors = [RGBA(r: 214, g: 98, b: 32), RGBA(r: 191, g: 54, b: 34), RGBA(r: 226, g: 162, b: 44), RGBA(r: 140, g: 82, b: 40)]
        return colors.map { col in
            let c = CAEmitterCell()
            c.contents = image([" ll  ", "lllll", " llls", "   s "], ["l": col, "s": RGBA(r: 90, g: 56, b: 30)])
            c.birthRate = 0.8
            c.lifetime = 45
            c.velocity = 30
            c.velocityRange = 12
            c.emissionLongitude = -.pi / 2
            c.emissionRange = 0.5
            c.xAcceleration = 6
            c.spin = 1.2
            c.spinRange = 3
            c.scale = 2
            c.scaleRange = 0.5
            c.magnificationFilter = CALayerContentsFilter.nearest.rawValue
            return c
        }
    }
}
