import Foundation

/// A physical key on the Apex Pro TKL Gen 3.
///
/// `hid` is the USB HID Keyboard/Keypad usage code (usage page 0x07) which is
/// also the LED identifier used by the direct-lighting protocol and the key
/// address used by the actuation and button-mapping protocols.
/// `x`, `y`, `w`, `h` are in "key units" (1u = one standard keycap) for rendering.
public struct Key: Identifiable, Hashable, Sendable {
    public let hid: UInt8
    public let label: String
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    /// True if the key uses an adjustable OmniPoint magnetic switch (supports
    /// per-key actuation, rapid trigger, dual actuation).
    public let isAnalog: Bool
    /// True if the key has an addressable RGB LED (`direct_write` accepts it).
    public let hasLED: Bool
    /// True if the key can be rebound (`mappings` accepts it). The media/OLED
    /// buttons are excluded by the firmware — see `ignoredHIDCodes`.
    public let isMappable: Bool
    /// True if the key only exists on ISO (EU) physical layouts.
    public let isISOOnly: Bool

    public var id: UInt8 { hid }

    init(_ hid: UInt8, _ label: String, _ x: Double, _ y: Double, _ w: Double = 1, _ h: Double = 1, isoOnly: Bool = false) {
        self.hid = hid
        self.label = label
        self.x = x; self.y = y; self.w = w; self.h = h
        self.isAnalog = ApexProTKLGen3.analogHIDCodes.contains(hid)
        self.hasLED = ApexProTKLGen3.ledHIDCodeSet.contains(hid)
        self.isMappable = ApexProTKLGen3.mappableHIDCodeSet.contains(hid)
        self.isISOOnly = isoOnly
    }
}

/// Physical keycap layout reported by `read_layout` (`0xF2`).
public enum KeyboardLayout: UInt8, Sendable, CaseIterable, Codable {
    case ansi = 0   // US
    case iso  = 1   // EU
    case jis  = 2   // JP

    public var displayName: String {
        switch self {
        case .ansi: return "ANSI (US)"
        case .iso: return "ISO (EU)"
        case .jis: return "JIS (JP)"
        }
    }
}

public enum ApexProTKLGen3 {

    /// USB product identifier for the wired Apex Pro TKL Gen 3.
    public static let productID = 0x1642
    public static let vendorID = 0x1038
    /// Vendor configuration interface.
    public static let usagePage = 0xFFC0
    public static let usage = 0x0001
    /// Notification / sync interface (input reports only) — see PRD-14.
    public static let syncUsagePage = 0xFFC1
    public static let syncUsage = 0x0001

    // MARK: - Firmware key tables (from the vendor's description of the device)

    /// The firmware's key-slot → HID usage table (`deviceKeyIndexToHID`), in
    /// firmware slot order. Onboard-profile structures are indexed by *slot*,
    /// not by HID code, so this table is the bridge between the two. `0` marks
    /// an unpopulated slot. Values as established from the vendor's description
    /// of the device; membership rules confirmed on hardware (docs/PROTOCOL.md).
    public static let deviceKeyIndexToHID: [UInt8] = [
        53, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 137,
        43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49,
        57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 50, 40,
        225, 100, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 135, 229,
        224, 227, 226, 139, 44, 138, 136, 230, 231, 240, 228, 42, 0, 0,
        41, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 73,
        74, 75, 76, 77, 78, 82, 80, 81, 79, 0, 245, 246, 247, 241,
        254, 255,
    ]

    /// The first `numFirmwareAnalogKeys` slots of `deviceKeyIndexToHID` are the
    /// magnetic (OmniPoint) switches; the rest are mechanical.
    public static let numFirmwareAnalogKeys = 70
    public static let numFirmwareMechanicalKeys = 24

    /// The media / OLED navigation buttons. The firmware exposes them in the
    /// key table but refuses user bindings for them; they are hard-wired to consumer controls (play/pause, next, prev, mute,
    /// vol+, vol−) and have no RGB LED.
    public static let ignoredHIDCodes: Set<UInt8> = [245, 246, 247, 241, 254, 255]

    /// HID usage codes for the adjustable OmniPoint (analog) keys — the analog
    /// prefix of `deviceKeyIndexToHID` minus empty and ignored slots.
    public static let analogHIDCodes: Set<UInt8> = Set(analogHIDOrder)

    /// Analog HID codes in the order the actuation commands emit them: the
    /// analog slots, sorted ascending (68 blocks).
    public static let analogHIDOrder: [UInt8] = deviceKeyIndexToHID
        .prefix(numFirmwareAnalogKeys)
        .filter { $0 != 0 && !ignoredHIDCodes.contains($0) }
        .sorted()

    /// Number of per-key blocks the actuation commands expect.
    public static var actuationBlockCount: Int { analogHIDOrder.count }   // 68

    /// The rebindable keys, in the order the `mappings` commands emit them:
    /// every populated, non-ignored slot, sorted ascending (91 blocks).
    public static let mappableHIDOrder: [UInt8] = deviceKeyIndexToHID
        .filter { $0 != 0 && !ignoredHIDCodes.contains($0) }
        .sorted()

    public static let mappableHIDCodeSet: Set<UInt8> = Set(mappableHIDOrder)

    /// Number of per-key blocks the mapping commands expect.
    public static var mappingBlockCount: Int { mappableHIDOrder.count }   // 91

    /// Every addressable RGB LED, in ascending order — 86 LEDs.
    ///
    /// `0x04…0x45`, `0x49…0x52`, `0xE0…0xE7`, `0xF0` are the lit keys of the
    /// keyboard's lighting zone; `0xFB` (the play/pause button by the OLED)
    /// is added by the 2024 model, which has no LED for `0x46`, `0x47` or
    /// `0x48`. Cross-checked against the vendor's description of the layout,
    /// which lists the same set minus the four keys whose position differs
    /// between ANSI and ISO (`0x28`, `0x31`, `0x32`, `0xE6`).
    ///
    /// This is deliberately *not* the same set as `mappableHIDOrder`: `0xFB`
    /// lights but cannot be rebound, and the six media/OLED buttons
    /// (`ignoredHIDCodes`) neither light nor rebind.
    public static let ledHIDOrder: [UInt8] =
        Array(UInt8(0x04)...UInt8(0x45)) + Array(UInt8(0x49)...UInt8(0x52))
        + Array(UInt8(0xE0)...UInt8(0xE7)) + [0xF0, 0xFB]

    public static let ledHIDCodeSet: Set<UInt8> = Set(ledHIDOrder)

    // MARK: - Physical layout

    /// The full physical key layout. Keys flagged `isISOOnly` exist only on ISO
    /// boards; use `keys(for:)` to get the set for a specific physical layout.
    public static let keys: [Key] = {
        var k: [Key] = []

        // Function row (y = 0)
        k.append(Key(0x29, "Esc", 0, 0))
        let fkeys: [(UInt8, String, Double)] = [
            (0x3A, "F1", 2), (0x3B, "F2", 3), (0x3C, "F3", 4), (0x3D, "F4", 5),
            (0x3E, "F5", 6.5), (0x3F, "F6", 7.5), (0x40, "F7", 8.5), (0x41, "F8", 9.5),
            (0x42, "F9", 11), (0x43, "F10", 12), (0x44, "F11", 13), (0x45, "F12", 14),
        ]
        for (hid, label, x) in fkeys { k.append(Key(hid, label, x, 0)) }
        // Play/pause button beside the OLED. It has its own LED (0xFB) but the
        // firmware refuses user bindings for the media buttons, so it renders
        // and lights but is not selectable in the Bindings pane.
        k.append(Key(0xFB, "⏯", 15.5, 0))

        // Number row (y = 1.25)
        let numRow: [(UInt8, String, Double, Double)] = [
            (0x35, "`", 0, 1), (0x1E, "1", 1, 1), (0x1F, "2", 2, 1), (0x20, "3", 3, 1),
            (0x21, "4", 4, 1), (0x22, "5", 5, 1), (0x23, "6", 6, 1), (0x24, "7", 7, 1),
            (0x25, "8", 8, 1), (0x26, "9", 9, 1), (0x27, "0", 10, 1), (0x2D, "-", 11, 1),
            (0x2E, "=", 12, 1), (0x2A, "⌫", 13, 2),
        ]
        for (hid, label, x, w) in numRow { k.append(Key(hid, label, x, 1.25, w)) }
        k.append(Key(0x49, "Ins", 15.5, 1.25))
        k.append(Key(0x4A, "Home", 16.5, 1.25))
        k.append(Key(0x4B, "PgUp", 17.5, 1.25))

        // Tab row (y = 2.25)
        let tabRow: [(UInt8, String, Double, Double)] = [
            (0x2B, "Tab", 0, 1.5), (0x14, "Q", 1.5, 1), (0x1A, "W", 2.5, 1), (0x08, "E", 3.5, 1),
            (0x15, "R", 4.5, 1), (0x17, "T", 5.5, 1), (0x1C, "Y", 6.5, 1), (0x18, "U", 7.5, 1),
            (0x0C, "I", 8.5, 1), (0x12, "O", 9.5, 1), (0x13, "P", 10.5, 1), (0x2F, "[", 11.5, 1),
            (0x30, "]", 12.5, 1), (0x31, "\\", 13.5, 1.5),
        ]
        for (hid, label, x, w) in tabRow { k.append(Key(hid, label, x, 2.25, w)) }
        k.append(Key(0x4C, "Del", 15.5, 2.25))
        k.append(Key(0x4D, "End", 16.5, 2.25))
        k.append(Key(0x4E, "PgDn", 17.5, 2.25))

        // Caps row (y = 3.25)
        let capsRow: [(UInt8, String, Double, Double)] = [
            (0x39, "Caps", 0, 1.75), (0x04, "A", 1.75, 1), (0x16, "S", 2.75, 1), (0x07, "D", 3.75, 1),
            (0x09, "F", 4.75, 1), (0x0A, "G", 5.75, 1), (0x0B, "H", 6.75, 1), (0x0D, "J", 7.75, 1),
            (0x0E, "K", 8.75, 1), (0x0F, "L", 9.75, 1), (0x33, ";", 10.75, 1), (0x34, "'", 11.75, 1),
            (0x28, "Enter", 12.75, 2.25),
        ]
        for (hid, label, x, w) in capsRow { k.append(Key(hid, label, x, 3.25, w)) }
        // ISO boards carry an extra key here (`#~`, HID 0x32) and an L-shaped
        // Enter. It is lit on every board because the LED matrix is shared, so
        // it stays in the lighting frame regardless of the fitted keycaps.
        k.append(Key(0x32, "#", 12.75, 3.25, 1, 1, isoOnly: true))

        // Shift row (y = 4.25)
        let shiftRow: [(UInt8, String, Double, Double)] = [
            (0xE1, "Shift", 0, 2.25), (0x1D, "Z", 2.25, 1), (0x1B, "X", 3.25, 1), (0x06, "C", 4.25, 1),
            (0x19, "V", 5.25, 1), (0x05, "B", 6.25, 1), (0x11, "N", 7.25, 1), (0x10, "M", 8.25, 1),
            (0x36, ",", 9.25, 1), (0x37, ".", 10.25, 1), (0x38, "/", 11.25, 1), (0xE5, "Shift", 12.25, 2.75),
        ]
        for (hid, label, x, w) in shiftRow { k.append(Key(hid, label, x, 4.25, w)) }
        k.append(Key(0x52, "↑", 16.5, 4.25))

        // Bottom row (y = 5.25)
        let bottomRow: [(UInt8, String, Double, Double)] = [
            (0xE0, "Ctrl", 0, 1.25), (0xE3, "Cmd", 1.25, 1.25), (0xE2, "Alt", 2.5, 1.25),
            (0x2C, "Space", 3.75, 6.25),
            (0xE6, "Alt", 10, 1.25), (0xE7, "Cmd", 11.25, 1.25), (0xF0, "SS", 12.5, 1.25), (0xE4, "Ctrl", 13.75, 1.25),
        ]
        for (hid, label, x, w) in bottomRow { k.append(Key(hid, label, x, 5.25, w)) }
        k.append(Key(0x50, "←", 15.5, 5.25))
        k.append(Key(0x51, "↓", 16.5, 5.25))
        k.append(Key(0x4F, "→", 17.5, 5.25))

        return k
    }()

    /// The keys physically present on a given layout.
    public static func keys(for layout: KeyboardLayout) -> [Key] {
        layout == .ansi ? keys.filter { !$0.isISOOnly } : keys
    }

    /// Convenience: all analog keys, ordered as they appear in `keys`.
    public static var analogKeys: [Key] { keys.filter { $0.isAnalog } }

    /// Every key that has an LED, precomputed.
    ///
    /// The renderer walks this fifty times a second between the hardware stream
    /// and the on-screen preview; re-filtering the layout on each pass is pure
    /// waste in the one loop that has to stay cheap.
    public static let litKeys: [Key] = keys.filter { $0.hasLED }

    private static let keysByHID: [UInt8: Key] = Dictionary(uniqueKeysWithValues: keys.map { ($0.hid, $0) })

    public static func key(forHID hid: UInt8) -> Key? { keysByHID[hid] }

    /// Human-readable name for any HID usage code we know about, whether or not
    /// the key is present on this keyboard (used to label remap targets).
    public static func name(forHID hid: UInt8) -> String {
        keysByHID[hid]?.label ?? HIDUsage.name(hid)
    }

    /// Total layout width/height in key units, for laying out the UI.
    public static let layoutWidth: Double = 18.5
    public static let layoutHeight: Double = 6.25
}
