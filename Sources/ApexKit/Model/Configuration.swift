import Foundation

// MARK: - HID-keyed map

/// A `HID usage code → value` map that serialises as a JSON object with
/// readable hex keys (`"0x2C"`), so exported profiles stay hand-editable and
/// diffable. Swift's default `Dictionary` conformance would emit an
/// alternating `[key, value, key, value…]` array for a `UInt8` key, which is
/// neither.
public struct HIDMap<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable,
                                                             ExpressibleByDictionaryLiteral, Sequence {
    public private(set) var values: [UInt8: Value]

    public init(_ values: [UInt8: Value] = [:]) { self.values = values }
    public init(dictionaryLiteral elements: (UInt8, Value)...) {
        values = Dictionary(elements, uniquingKeysWith: { _, b in b })
    }

    public subscript(hid: UInt8) -> Value? {
        get { values[hid] }
        set { values[hid] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }
    public var count: Int { values.count }
    public var keys: Dictionary<UInt8, Value>.Keys { values.keys }
    public func makeIterator() -> Dictionary<UInt8, Value>.Iterator { values.makeIterator() }
    public mutating func removeAll() { values.removeAll() }
    public func mapValues<T>(_ transform: (Value) -> T) -> [UInt8: T] { values.mapValues(transform) }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Value].self)
        var out: [UInt8: Value] = [:]
        for (key, value) in raw {
            guard let hid = HIDMap.parseKey(key) else { continue }   // skip junk, never throw
            out[hid] = value
        }
        values = out
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = Dictionary(uniqueKeysWithValues: values.map { (String(format: "0x%02X", $0.key), $0.value) })
        try container.encode(raw)
    }

    /// Accepts `"0x2C"`, `"2C"` (hex) and plain decimal, so files edited by hand
    /// in either convention still load.
    public static func parseKey(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { return UInt8(t.dropFirst(2), radix: 16) }
        if let d = UInt8(t) { return d }
        return UInt8(t, radix: 16)
    }
}

// MARK: - Actuation

/// Per-key actuation, rapid-trigger, and dual-actuation settings.
public struct ActuationConfig: Equatable, Codable, Sendable {
    /// Level 1…40 = 0.1…4.0 mm.
    public var globalLevel: Int = 15
    public var perKey: HIDMap<Int> = [:]
    public var usePerKey: Bool = false

    public var rapidTrigger: Bool = false
    public var rapidTriggerSensitivity: UInt8 = 2
    public var perKeyRapidTrigger: HIDMap<Bool> = [:]
    /// Which release mode "rapid trigger on" writes. Standard is `.rapidTrigger`.
    public var releaseMode: Actuation.ReleaseMode = .rapidTrigger

    /// Second actuation point (PRD-03) — a deeper press on the same key can
    /// fire a different binding (`Mappings.Layer.secondActuation`).
    public var secondActuationEnabled: Bool = false
    public var secondActuationLevel: Int = 32
    public var perKeySecondActuation: HIDMap<Int> = [:]

    public func level(for hid: UInt8) -> Int {
        usePerKey ? (perKey[hid] ?? globalLevel) : globalLevel
    }

    public func rapidTriggerEnabled(for hid: UInt8) -> Bool {
        usePerKey ? (perKeyRapidTrigger[hid] ?? rapidTrigger) : rapidTrigger
    }

    /// The second actuation level for a key, or nil when it has none.
    /// A second point shallower than the primary makes no physical sense, so it
    /// is clamped to at least one level deeper.
    public func secondActuationLevel(for hid: UInt8) -> Int? {
        guard secondActuationEnabled else { return nil }
        guard let explicit = perKeySecondActuation[hid] else { return nil }
        return max(explicit, level(for: hid) + 1)
    }

    private enum CodingKeys: String, CodingKey {
        case globalLevel, perKey, usePerKey, rapidTrigger, rapidTriggerSensitivity
        case perKeyRapidTrigger, releaseMode
        case secondActuationEnabled, secondActuationLevel, perKeySecondActuation
    }

    public init() {}

    /// Every field is optional on decode so profiles written by an older build
    /// still load (PRD-06 FR-1 forward/backward compatibility).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalLevel = try c.decodeIfPresent(Int.self, forKey: .globalLevel) ?? 15
        perKey = try c.decodeIfPresent(HIDMap<Int>.self, forKey: .perKey) ?? [:]
        usePerKey = try c.decodeIfPresent(Bool.self, forKey: .usePerKey) ?? false
        rapidTrigger = try c.decodeIfPresent(Bool.self, forKey: .rapidTrigger) ?? false
        rapidTriggerSensitivity = try c.decodeIfPresent(UInt8.self, forKey: .rapidTriggerSensitivity) ?? 2
        perKeyRapidTrigger = try c.decodeIfPresent(HIDMap<Bool>.self, forKey: .perKeyRapidTrigger) ?? [:]
        releaseMode = try c.decodeIfPresent(Actuation.ReleaseMode.self, forKey: .releaseMode) ?? .rapidTrigger
        secondActuationEnabled = try c.decodeIfPresent(Bool.self, forKey: .secondActuationEnabled) ?? false
        secondActuationLevel = try c.decodeIfPresent(Int.self, forKey: .secondActuationLevel) ?? 32
        perKeySecondActuation = try c.decodeIfPresent(HIDMap<Int>.self, forKey: .perKeySecondActuation) ?? [:]
    }
}

// MARK: - Rapid tap (SOCD)

public struct RapidTapConfig: Equatable, Codable, Sendable {
    public var enabled: Bool = false
    public var pairs: [Pair] = [Pair()]

    public struct Pair: Equatable, Codable, Sendable, Identifiable {
        public var id: UUID = UUID()
        public var key1: UInt8 = 0x04     // A
        public var key2: UInt8 = 0x07     // D
        /// 0…3, per the firmware's `rapid_tap_pair.mode`.
        public var mode: UInt8 = 0
        public var reportBoth: Bool = false

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            key1 = try c.decodeIfPresent(UInt8.self, forKey: .key1) ?? 0x04
            key2 = try c.decodeIfPresent(UInt8.self, forKey: .key2) ?? 0x07
            mode = try c.decodeIfPresent(UInt8.self, forKey: .mode) ?? 0
            reportBoth = try c.decodeIfPresent(Bool.self, forKey: .reportBoth) ?? false
        }
    }

    /// The pairs the firmware will accept: valid, distinct, de-duplicated, ≤ 10.
    public var validPairs: [Pair] {
        var seen = Set<UInt8>()
        var out: [Pair] = []
        for p in pairs {
            guard p.key1 != p.key2 else { continue }
            guard ApexProTKLGen3.analogHIDCodes.contains(p.key1),
                  ApexProTKLGen3.analogHIDCodes.contains(p.key2) else { continue }
            // A key may only appear in one pair; the firmware has one SOCD slot
            // per key and a duplicate would make the winner undefined.
            guard !seen.contains(p.key1), !seen.contains(p.key2) else { continue }
            seen.insert(p.key1); seen.insert(p.key2)
            out.append(p)
            if out.count == 10 { break }
        }
        return out
    }

    public init() {}
}

// MARK: - Bindings (PRD-01 / 02 / 03)

public struct BindingsConfig: Equatable, Codable, Sendable {
    /// Layer 0 — what a key does on its own.
    public var normal: HIDMap<Mappings.Binding> = [:]
    /// Layer 1 — what it does while the Fn/meta key is held.
    public var meta: HIDMap<Mappings.Binding> = [:]
    /// Layer 2 — what it does past the second actuation point.
    public var secondActuation: HIDMap<Mappings.Binding> = [:]
    /// Which key triggers the meta layer, if any.
    public var metaToggleHID: UInt8?

    public subscript(layer: Mappings.Layer) -> HIDMap<Mappings.Binding> {
        get {
            switch layer {
            case .normal: return normal
            case .meta: return meta
            case .secondActuation: return secondActuation
            }
        }
        set {
            switch layer {
            case .normal: normal = newValue
            case .meta: meta = newValue
            case .secondActuation: secondActuation = newValue
            }
        }
    }

    /// Bindings that differ from the factory default, for badge counts.
    public var changedCount: Int {
        Mappings.Layer.allCases.reduce(0) { total, layer in
            total + self[layer].values.filter { !Mappings.isBlank($1, layer: layer, hid: $0) }.count
        } + (metaToggleHID == nil ? 0 : 1)
    }

    /// What a key does on a layer, resolving "not configured" to the layer's
    /// blank rather than inventing `function 0`.
    public func binding(for hid: UInt8, layer: Mappings.Layer) -> Mappings.Binding {
        self[layer][hid] ?? layer.blankBinding(forHID: hid)
    }

    public func isBlank(_ hid: UInt8, layer: Mappings.Layer) -> Bool {
        Mappings.isBlank(binding(for: hid, layer: layer), layer: layer, hid: hid)
    }

    public var isEmpty: Bool { changedCount == 0 }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        normal = try c.decodeIfPresent(HIDMap<Mappings.Binding>.self, forKey: .normal) ?? [:]
        meta = try c.decodeIfPresent(HIDMap<Mappings.Binding>.self, forKey: .meta) ?? [:]
        secondActuation = try c.decodeIfPresent(HIDMap<Mappings.Binding>.self, forKey: .secondActuation) ?? [:]
        metaToggleHID = try c.decodeIfPresent(UInt8.self, forKey: .metaToggleHID)
    }
}

// MARK: - OLED

public struct OLEDConfig: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        case off, text, image, clock
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .off: return "Firmware default"
            case .text: return "Text"
            case .image: return "Image"
            case .clock: return "Clock"
            }
        }
    }

    public var mode: Mode = .text
    public var line1: String = "APEX PRO"
    public var line2: String = "Gen 3"
    public var fontSize: Double = 18
    /// Absolute path of the chosen image, so a profile can restore it.
    public var imagePath: String?
    public var clockTimeFormat: String = "HH:mm:ss"
    public var clockDateFormat: String = "EEE d MMM"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .text
        line1 = try c.decodeIfPresent(String.self, forKey: .line1) ?? ""
        line2 = try c.decodeIfPresent(String.self, forKey: .line2) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        clockTimeFormat = try c.decodeIfPresent(String.self, forKey: .clockTimeFormat) ?? "HH:mm:ss"
        clockDateFormat = try c.decodeIfPresent(String.self, forKey: .clockDateFormat) ?? "EEE d MMM"
    }

    /// Render the current configuration to a 128 × 40 bitmap, or nil for `.off`.
    public func render(now: Date = Date()) -> MonoBitmap? {
        switch mode {
        case .off:
            return nil
        case .text:
            let lines = [line1, line2].filter { !$0.isEmpty }
            guard !lines.isEmpty else { return MonoBitmap() }
            return OLEDGraphics.text(lines, fontSize: CGFloat(lines.count > 1 ? min(fontSize, 16) : fontSize))
        case .image:
            guard let imagePath else { return nil }
            return OLEDGraphics.image(contentsOf: URL(fileURLWithPath: imagePath))
        case .clock:
            let time = DateFormatter(); time.dateFormat = clockTimeFormat
            let date = DateFormatter(); date.dateFormat = clockDateFormat
            return OLEDGraphics.text([time.string(from: now), date.string(from: now)], fontSize: 16)
        }
    }

    /// True when the content changes over time and needs a repeating push.
    public var isLive: Bool { mode == .clock }
}
