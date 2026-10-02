import Foundation

/// Builders for the "direct" per-key lighting protocol.
///
/// Direct writes put the keyboard into a software-controlled lighting mode where
/// every LED is addressed individually. This overrides the onboard lighting
/// profile until `clearDirect` (0x41) hands control back.
///
/// Wire format (Feature report, report ID 0, padded to 644 payload bytes):
///     [0x40][count][ (hid, R, G, B) × count ][ 0-padding ]
///
/// Provenance: command 0x40 with one `{ hid, red, green, blue }` block per key,
/// sent as a Feature report of 645 bytes (644 data bytes after the report ID),
/// from the vendor's description of the device and confirmed on hardware.
public enum DirectLighting {

    /// Size of the Feature report payload (excludes the report-ID byte).
    public static let featurePayloadSize = 644
    public static let directCommand: UInt8 = 0x40
    public static let clearCommand: UInt8 = 0x41

    /// Build a direct-write Feature payload from per-key colors.
    /// Keys not present in `colors` are omitted (left unchanged by firmware only
    /// if not previously set; for a full frame pass a color for every key).
    public static func directWrite(colors: [(hid: UInt8, color: LEDColor)]) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = directCommand
        let count = min(colors.count, (featurePayloadSize - 2) / 4)
        data[1] = UInt8(count)
        for i in 0..<count {
            let off = 2 + i * 4
            data[off] = colors[i].hid
            data[off + 1] = colors[i].color.r
            data[off + 2] = colors[i].color.g
            data[off + 3] = colors[i].color.b
        }
        return data
    }

    /// Convenience: build a full frame for every addressable LED from a color
    /// map, defaulting missing LEDs to black.
    ///
    /// The frame covers `ApexProTKLGen3.ledHIDOrder` — the firmware's own LED
    /// list — not the rendered key layout: the media/OLED buttons have no LED,
    /// and the ISO `#~` LED exists in the matrix on every board.
    public static func frame(_ map: [UInt8: LEDColor]) -> [UInt8] {
        let colors = ApexProTKLGen3.ledHIDOrder.map { (hid: $0, color: map[$0] ?? .black) }
        return directWrite(colors: colors)
    }

    /// Solid color across every addressable LED.
    public static func solid(_ color: LEDColor) -> [UInt8] {
        let colors = ApexProTKLGen3.ledHIDOrder.map { (hid: $0, color: color) }
        return directWrite(colors: colors)
    }

    /// Clear direct mode and return to the onboard lighting profile.
    /// Wire format (Output report, report ID 0): [0x41]
    public static func clearDirect() -> [UInt8] {
        [clearCommand]
    }
}
