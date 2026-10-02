import Foundation

/// Actuation, rapid-trigger, and rapid-tap (SOCD) command builders for the
/// Apex Pro TKL Gen 3 (0x1642).
///
/// All per-key actuation commands live in the `0x38` device-command namespace
/// and are Feature reports (except rapid-tap, which are Output reports). Each
/// per-key block addresses a key by its HID usage code, so block order does not
/// affect which key is configured; we emit the 68 analog keys in ascending HID order.
///
/// Provenance: the command layouts are from the vendor's description of the
/// device — primary thresholds (0x38 0x61), second-actuation thresholds (0x38
/// 0x61, layer 0x02), release mode (0x38 0x62), rapid-trigger sensitivity
/// (0x38 0x65), rapid-tap enable (0x38 0x66) and rapid-tap pairs (0x38 0x67).
/// docs/PROTOCOL.md says how sure each one is.
public enum Actuation {

    public static let featurePayloadSize = 644
    public static let outputPayloadSize = 64

    public static let deviceCommand: UInt8 = 0x38
    public static let cmdHallThresholds: UInt8 = 0x61
    public static let cmdReleaseMode: UInt8 = 0x62
    public static let cmdRapidTriggerSensitivity: UInt8 = 0x65
    public static let cmdRapidTapEnable: UInt8 = 0x66
    public static let cmdRapidTapPairs: UInt8 = 0x67

    // MARK: - Actuation level ↔ raw hall thresholds

    /// The Gen-3-TKL (0x1642) actuation curve. Index = level−1 (levels 1…40,
    /// where level N ≈ N/10 mm of travel). Each entry is the raw `(l, h)` hall
    /// sensor threshold pair: `l` = release (shallower), `h` = actuation (deeper),
    /// with `l ≤ h` giving hysteresis. Values from the vendor's description of
    /// the device; docs/PROTOCOL.md says how far they have been checked.
    public static let levelToLH: [(l: UInt8, h: UInt8)] = [
        (4, 4), (3, 4), (4, 5), (5, 7), (7, 8), (8, 10), (10, 11), (11, 13), (13, 15), (15, 17),
        (17, 19), (19, 22), (22, 24), (24, 27), (27, 30), (30, 34), (34, 37), (37, 40), (40, 44), (44, 49),
        (49, 54), (54, 59), (59, 65), (65, 72), (72, 79), (79, 86), (86, 94), (94, 103), (103, 113), (113, 124),
        (124, 136), (136, 148), (148, 164), (164, 180), (180, 189), (189, 199), (199, 209), (209, 219), (211, 219), (213, 219),
    ]

    public static let minLevel = 1
    public static let maxLevel = 40

    /// Clamp and convert an actuation level (1…40) to its raw `(h, l)` bytes in
    /// the order the wire struct expects (`h` first, then `l`).
    public static func hl(forLevel level: Int) -> (h: UInt8, l: UInt8) {
        let idx = max(minLevel, min(maxLevel, level)) - 1
        let e = levelToLH[idx]
        return (h: e.h, l: e.l)
    }

    /// Convert a travel distance in millimetres (0.1…4.0) to an actuation level.
    public static func level(forMillimetres mm: Double) -> Int {
        max(minLevel, min(maxLevel, Int((mm * 10).rounded())))
    }

    public static func millimetres(forLevel level: Int) -> Double {
        Double(max(minLevel, min(maxLevel, level))) / 10.0
    }

    /// Sentinel `(h, l)` meaning "disabled" for a per-key second actuation point.
    public static let disabledHL: (h: UInt8, l: UInt8) = (h: 255, l: 255)

    /// Map a raw `(h, l)` threshold pair back to an actuation level — the
    /// inverse of `hl(forLevel:)`, for reading actuation out of an onboard
    /// profile image. Exact match on the current curve first, then the level
    /// with the nearest `h` (the actuation threshold proper), so a pair written
    /// by other software still reads back as a sensible level. Returns nil for
    /// the disabled sentinel and the all-zero pair, which mean "no point here",
    /// not a level.
    public static func level(forH h: UInt8, l: UInt8) -> Int? {
        if h == disabledHL.h && l == disabledHL.l { return nil }
        if h == 0 && l == 0 { return nil }
        if let idx = levelToLH.firstIndex(where: { $0.h == h && $0.l == l }) { return idx + 1 }
        let nearest = levelToLH.enumerated().min {
            abs(Int($0.element.h) - Int(h)) < abs(Int($1.element.h) - Int(h))
        }!
        return nearest.offset + 1
    }

    // MARK: - Packet builders

    /// Build one of the `(hid, h, l)` threshold commands.
    /// `perKeyLevel` maps HID code → level (1…40). Keys absent from the map use
    /// `defaultLevel`. Pass `layer = 0x02` for the second (dual) actuation point.
    public static func hallThresholds(perKeyLevel: [UInt8: Int], defaultLevel: Int, layer: UInt8 = 0x00) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = deviceCommand
        data[1] = cmdHallThresholds
        data[2] = UInt8(ApexProTKLGen3.actuationBlockCount)
        data[3] = layer
        var off = 4
        for hid in ApexProTKLGen3.analogHIDOrder {
            let level = perKeyLevel[hid] ?? defaultLevel
            let (h, l) = hl(forLevel: level)
            data[off] = hid; data[off + 1] = h; data[off + 2] = l
            off += 3
        }
        return data
    }

    /// Second actuation point (dual bind). `perKeyLevel` values of nil / absent
    /// disable the second point for that key.
    public static func secondActuation(perKeyLevel: [UInt8: Int?]) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = deviceCommand
        data[1] = cmdHallThresholds
        data[2] = UInt8(ApexProTKLGen3.actuationBlockCount)
        data[3] = 0x02 // layer
        var off = 4
        for hid in ApexProTKLGen3.analogHIDOrder {
            let (h, l): (UInt8, UInt8)
            if let lvl = perKeyLevel[hid], let lvl2 = lvl {
                (h, l) = hl(forLevel: lvl2)
            } else {
                (h, l) = disabledHL
            }
            data[off] = hid; data[off + 1] = h; data[off + 2] = l
            off += 3
        }
        return data
    }

    /// Per-key release behaviour (`release_mode`, `0x38 0x62`).
    ///
    /// The firmware accepts `0x00`, `0x02`, `0x03` and `0x04`. `0x00` (off) and
    /// `0x02` (rapid trigger) are confirmed on hardware. `0x03` and `0x04` are
    /// accepted, but nothing we have says what they do; the flash image has
    /// adaptive-distance and protection fields alongside, which suggests they
    /// select adaptive and protection behaviour — unproven, so they are
    /// surfaced as clearly-labelled alternates rather than given names we
    /// cannot stand behind.
    public enum ReleaseMode: UInt8, Sendable, Codable, CaseIterable, Identifiable {
        case off = 0x00
        case rapidTrigger = 0x02
        case alternate3 = 0x03
        case alternate4 = 0x04

        public var id: UInt8 { rawValue }

        public var displayName: String {
            switch self {
            case .off: return "Off"
            case .rapidTrigger: return "Rapid Trigger"
            case .alternate3: return "Alternate mode 3"
            case .alternate4: return "Alternate mode 4"
            }
        }

        /// True for the two modes whose behaviour is not documented.
        public var isUnverified: Bool { self == .alternate3 || self == .alternate4 }
    }

    /// Rapid-trigger release mode per key.
    public static func releaseMode(perKeyMode: [UInt8: ReleaseMode], defaultMode: ReleaseMode = .off) -> [UInt8] {
        releaseMode(perKeyRawMode: perKeyMode.mapValues { $0.rawValue }, defaultRawMode: defaultMode.rawValue)
    }

    /// Raw form, for experimentation with undocumented mode values.
    public static func releaseMode(perKeyRawMode: [UInt8: UInt8], defaultRawMode: UInt8 = 0) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = deviceCommand
        data[1] = cmdReleaseMode
        data[2] = UInt8(ApexProTKLGen3.actuationBlockCount)
        var off = 3
        for hid in ApexProTKLGen3.analogHIDOrder {
            data[off] = hid
            data[off + 1] = perKeyRawMode[hid] ?? defaultRawMode
            off += 2
        }
        return data
    }

    /// Rapid-trigger sensitivity per key (re-trigger travel delta, in 0.1 mm
    /// units; firmware default 2).
    public static func rapidTriggerSensitivity(perKey: [UInt8: UInt8], defaultSensitivity: UInt8 = 2) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = deviceCommand
        data[1] = cmdRapidTriggerSensitivity
        data[2] = UInt8(ApexProTKLGen3.actuationBlockCount)
        var off = 3
        for hid in ApexProTKLGen3.analogHIDOrder {
            data[off] = hid
            data[off + 1] = perKey[hid] ?? defaultSensitivity
            off += 2
        }
        return data
    }

    // MARK: - Rapid tap (SOCD) — Output reports

    /// Enable/disable rapid tap globally. Wire (Output 65): `[0x38][0x66][enabled]`.
    public static func rapidTapEnable(_ enabled: Bool) -> [UInt8] {
        [deviceCommand, cmdRapidTapEnable, enabled ? 1 : 0]
    }

    public struct RapidTapPair: Sendable, Equatable {
        public var hid1: UInt8
        public var hid2: UInt8
        /// 0…3 (e.g. last-input-priority variants).
        public var mode: UInt8
        /// If true, both keys may report simultaneously (full-press flag, bit 7).
        public var reportBoth: Bool
        public init(hid1: UInt8, hid2: UInt8, mode: UInt8 = 0, reportBoth: Bool = false) {
            self.hid1 = hid1; self.hid2 = hid2; self.mode = mode; self.reportBoth = reportBoth
        }
    }

    /// Build the rapid-tap pairs Output report.
    /// Wire (Output 65): `[0x38][0x67][count]` then per pair
    /// `[index, hid1, hid2, mode | (reportBoth ? 0x80 : 0), 0, 0]`.
    public static func rapidTapPairs(_ pairs: [RapidTapPair]) -> [UInt8] {
        var data: [UInt8] = [deviceCommand, cmdRapidTapPairs, UInt8(pairs.count)]
        for (i, p) in pairs.enumerated() {
            data.append(UInt8(i))
            data.append(p.hid1)
            data.append(p.hid2)
            data.append(p.mode | (p.reportBoth ? 0x80 : 0x00))
            data.append(0)
            data.append(0)
        }
        return data
    }
}
