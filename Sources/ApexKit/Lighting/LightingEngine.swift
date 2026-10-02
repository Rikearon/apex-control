import Foundation

/// Software lighting effect kinds. All are rendered on the host and streamed to
/// the keyboard as `direct_write` frames — this gives us unlimited effects and
/// full per-key control, independent of the firmware's onboard lighting engine.
public enum EffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case staticColor = "Static"
    case perKey = "Per-Key"
    case rainbowWave = "Rainbow Wave"
    case spectrumCycle = "Spectrum Cycle"
    case breathe = "Breathe"
    case reactive = "Reactive"

    public var id: String { rawValue }
    public var isAnimated: Bool { self != .staticColor && self != .perKey }
    public var usesReactive: Bool { self == .reactive }
}

public struct LightingConfig: Equatable, Sendable, Codable {
    public var kind: EffectKind = .rainbowWave
    public var baseColor: LEDColor = .steelOrange
    public var secondaryColor: LEDColor = LEDColor(r: 0, g: 120, b: 255)
    public var perKeyColors: HIDMap<LEDColor> = [:]
    public var brightness: Double = 1.0
    public var speed: Double = 0.5           // 0…1
    public var horizontal: Bool = true       // wave direction
    public var reactiveFade: Double = 0.6    // seconds
    /// How brightly reactive draws the keys nobody is pressing, as a fraction of
    /// `secondaryColor`. Adjustable because the useful setting depends entirely
    /// on the room: a resting glow that reads as "off" in daylight is glaring at
    /// night, and one that is invisible makes the effect look broken.
    public var reactiveRestLevel: Double = 0.06
    /// How far a press radiates across the board, 0 (just the key) to 1 (most of
    /// the keyboard). The wave's speed comes from `speed`.
    public var reactiveRipple: Double = 0.55

    public init() {}

    /// Tolerant decode so profiles from older/newer builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(EffectKind.self, forKey: .kind) ?? .rainbowWave
        baseColor = try c.decodeIfPresent(LEDColor.self, forKey: .baseColor) ?? .steelOrange
        secondaryColor = try c.decodeIfPresent(LEDColor.self, forKey: .secondaryColor) ?? LEDColor(r: 0, g: 120, b: 255)
        perKeyColors = try c.decodeIfPresent(HIDMap<LEDColor>.self, forKey: .perKeyColors) ?? [:]
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0.5
        horizontal = try c.decodeIfPresent(Bool.self, forKey: .horizontal) ?? true
        reactiveFade = try c.decodeIfPresent(Double.self, forKey: .reactiveFade) ?? 0.6
        reactiveRestLevel = try c.decodeIfPresent(Double.self, forKey: .reactiveRestLevel) ?? 0.06
        reactiveRipple = try c.decodeIfPresent(Double.self, forKey: .reactiveRipple) ?? 0.55
    }

    /// The colour an unpressed key shows in reactive mode.
    public var reactiveRestColor: LEDColor {
        secondaryColor.scaled(by: max(0, min(1, reactiveRestLevel)))
    }
}

/// A clock that only ever moves forwards, at a fixed rate.
///
/// Effects and key-press fades are timed against this rather than `Date`: the
/// wall clock is adjusted by NTP, by the user, and across sleep, and a backwards
/// step of even a second freezes every fade on the keyboard until real time
/// catches up again.
public enum MonotonicClock {
    /// Seconds since an arbitrary fixed point. Only differences are meaningful.
    public static var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Renders and streams lighting frames on a dedicated background thread so the
/// UI never blocks on USB I/O.
public final class LightingEngine: @unchecked Sendable {

    private let device: ApexDevice
    private let queue = DispatchQueue(label: "io.github.rikearon.apex-control.lighting", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var startTime = MonotonicClock.now
    private var config = LightingConfig()

    /// Reactive key activity: HID code → `MonotonicClock` time of the last press.
    /// Written from the key-monitor thread, read from the render thread and from
    /// the main actor (for the on-screen preview), so it is lock-guarded.
    private let reactiveLock = NSLock()
    private var reactiveHits: [UInt8: TimeInterval] = [:]
    private var lastPress: (hid: UInt8, at: TimeInterval)?

    /// Called when frame delivery starts failing, and again with `nil` once it
    /// recovers. Reported on the edge only: a 30 fps stream that has stopped
    /// working would otherwise raise thirty identical errors a second.
    public var onStreamHealthChange: (@Sendable (Error?) -> Void)?
    private var isFailing = false

    public init(device: ApexDevice) {
        self.device = device
    }

    public func apply(_ newConfig: LightingConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.config = newConfig
            self.stopTimerLocked()
            if newConfig.kind.isAnimated {
                self.startTime = MonotonicClock.now
                self.startTimerLocked()
            } else {
                self.renderAndSend(at: 0)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopTimerLocked() }
    }

    /// Feed a key-press event (HID code) for the reactive effect.
    /// Called from the key-monitor thread for every press, so it does no work
    /// beyond stamping the time.
    public func registerKeyPress(hid: UInt8) {
        let now = MonotonicClock.now
        reactiveLock.lock()
        reactiveHits[hid] = now
        lastPress = (hid, now)
        reactiveLock.unlock()
    }

    /// The most recent key press and how long ago it was, for the UI to show
    /// that it really is watching. Kept separately from `reactiveHits` because
    /// that map is pruned to the fade window, which is far too short to read.
    public func lastReactivePress() -> (hid: UInt8, secondsAgo: TimeInterval)? {
        reactiveLock.lock(); defer { reactiveLock.unlock() }
        guard let lastPress else { return nil }
        return (lastPress.hid, MonotonicClock.now - lastPress.at)
    }

    /// The live key-press map, for drawing the same reactive frame on screen.
    public func reactiveSnapshot() -> [UInt8: TimeInterval] {
        reactiveLock.lock(); defer { reactiveLock.unlock() }
        return reactiveHits
    }

    /// Forget every recorded press.
    ///
    /// Called when reactive is switched on, so a press from the last time it was
    /// selected — possibly hours ago — does not flash a key on the first frame.
    public func clearReactiveHits() {
        reactiveLock.lock()
        reactiveHits.removeAll()
        lastPress = nil
        reactiveLock.unlock()
    }

    // MARK: - Timer

    private func startTimerLocked() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 30 fps: matches the keyboard's Prism sync rate. Streaming full frames
        // faster than this outpaces the LED controller and causes visible tearing.
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.renderAndSend(at: MonotonicClock.now - self.startTime)
        }
        timer = t
        t.resume()
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Rendering

    private func renderAndSend(at t: TimeInterval) {
        let now = MonotonicClock.now
        // Drop presses that have finished fading while the map is held anyway.
        // Without this every key ever struck stays in the dictionary for the
        // lifetime of the process, and the render walks all of them every frame.
        let fade = max(0.05, config.reactiveFade)
        reactiveLock.lock()
        reactiveHits = reactiveHits.filter { now - $0.value < fade }
        let hits = reactiveHits
        reactiveLock.unlock()

        let frame = LightingRender.render(config: config, time: t, hits: hits, now: now)
        let list = frame.map { (hid: $0.key, color: $0.value.scaled(by: config.brightness)) }
        do {
            try device.setColors(list)
            if isFailing {
                isFailing = false
                onStreamHealthChange?(nil)
            }
        } catch HIDError.notConnected, HIDError.deviceDisconnected {
            // Unplugged. The connection callback already tells the user, and
            // the stream resumes on its own when the keyboard comes back.
            isFailing = false
        } catch {
            guard !isFailing else { return }
            isFailing = true
            onStreamHealthChange?(error)
        }
    }
}

/// Pure, side-effect-free lighting renderer, shared by the streaming engine and
/// the on-screen keyboard preview so both stay perfectly in sync.
public enum LightingRender {

    /// How far a ripple travels at full strength, in key units. The board is
    /// 18.5 units wide, so this reaches a corner from roughly anywhere.
    static let maxRippleReach = 14.0

    /// Render one frame.
    ///
    /// The frame covers every key in the *rendered layout* plus every
    /// addressable LED that has no rendered key, so effects never leave a dark
    /// hole on the physical board (e.g. the ISO `#~` LED on an ANSI render).
    ///
    /// - Parameters:
    ///   - hits: HID code → `MonotonicClock` time of the last press, for the
    ///     reactive effect. Ignored by every other effect.
    ///   - now: the `MonotonicClock` reading to age `hits` against. Passed in so
    ///     the streamer and the on-screen preview can render the same instant,
    ///     and so the fade curve is testable without sleeping.
    public static func render(config: LightingConfig, time t: TimeInterval,
                              hits: [UInt8: TimeInterval] = [:],
                              now: TimeInterval = MonotonicClock.now) -> [UInt8: LEDColor] {
        var out: [UInt8: LEDColor] = [:]
        let keys = ApexProTKLGen3.litKeys
        let speed = 0.1 + config.speed * 1.9

        switch config.kind {
        case .staticColor:
            for k in keys { out[k.hid] = config.baseColor }

        case .perKey:
            for k in keys { out[k.hid] = config.perKeyColors[k.hid] ?? .black }

        case .rainbowWave:
            for k in keys {
                let pos = config.horizontal ? k.x / ApexProTKLGen3.layoutWidth : k.y / ApexProTKLGen3.layoutHeight
                let hue = (pos - t * speed * 0.3).truncatingRemainder(dividingBy: 1.0)
                out[k.hid] = .hsv(hue, 1.0, 1.0)
            }

        case .spectrumCycle:
            let hue = (t * speed * 0.1).truncatingRemainder(dividingBy: 1.0)
            let c = LEDColor.hsv(hue, 1.0, 1.0)
            for k in keys { out[k.hid] = c }

        case .breathe:
            let phase = (sin(t * speed * 1.5) + 1) / 2      // 0…1
            for k in keys { out[k.hid] = config.baseColor.scaled(by: 0.15 + 0.85 * phase) }

        case .reactive:
            let rest = config.reactiveRestColor
            let fade = max(0.05, config.reactiveFade)
            let spread = max(0, min(1, config.reactiveRipple))
            let reach = maxRippleReach * spread
            // Wider reach gets a wider crest, or a ripple crossing half the
            // board would be a hairline that flickers past each key in a single
            // frame instead of washing over it.
            let crestWidth = 1.0 + spread * 1.6
            // At the middle speed setting the crest arrives at the edge of its
            // reach exactly as the press finishes fading, so the wave reads as
            // one event rather than a pulse that outruns or lags its own key.
            let waveSpeed = reach > 0 ? (reach / fade) * (0.5 + config.speed) : 0

            // Hoisted out of the per-key loop: with fast typing this is walked
            // eighty-six times a frame.
            var sources: [(x: Double, y: Double, age: Double)] = []
            if reach > 0 {
                sources.reserveCapacity(hits.count)
                for (hid, hitTime) in hits {
                    let age = now - hitTime
                    guard age >= 0, age < fade, let k = ApexProTKLGen3.key(forHID: hid) else { continue }
                    sources.append((k.x + k.w / 2, k.y + k.h / 2, age))
                }
            }

            for k in keys {
                var intensity = 0.0

                // The struck key itself. Linear, so a tap stays visible for the
                // whole fade — a curved falloff spends most of the time near
                // black and reads as "nothing happened" while you type.
                if let hitTime = hits[k.hid] {
                    let age = now - hitTime
                    if age >= 0, age < fade { intensity = 1.0 - age / fade }
                }

                if intensity < 1, !sources.isEmpty {
                    let cx = k.x + k.w / 2, cy = k.y + k.h / 2
                    for s in sources {
                        let dx = cx - s.x, dy = cy - s.y
                        let distance = (dx * dx + dy * dy).squareRoot()
                        guard distance <= reach else { continue }
                        let offCrest = abs(distance - s.age * waveSpeed)
                        guard offCrest < crestWidth else { continue }
                        // Squared across the crest for a soft edge, and weaker
                        // the further it has travelled — a ring that stayed as
                        // bright at the rim as at the origin looks like a
                        // flashing border, not something spreading outwards.
                        let onCrest = 1.0 - offCrest / crestWidth
                        let falloff = 1.0 - distance / reach
                        let life = 1.0 - s.age / fade
                        intensity = max(intensity, onCrest * onCrest * falloff * life)
                    }
                }

                out[k.hid] = intensity <= 0 ? rest : rest.mixed(with: config.baseColor, amount: intensity)
            }
        }
        return out
    }
}
