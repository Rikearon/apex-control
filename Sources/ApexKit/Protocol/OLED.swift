import Foundation

/// 128×40 one-bit-per-pixel framebuffer for the Apex Pro TKL Gen 3 OLED.
public struct MonoBitmap: Sendable, Equatable {
    public static let width = 128
    public static let height = 40

    /// Row-major pixel buffer, one Bool per pixel (`true` = lit).
    public private(set) var pixels: [Bool]

    public init() {
        pixels = [Bool](repeating: false, count: Self.width * Self.height)
    }

    public init(pixels: [Bool]) {
        precondition(pixels.count == Self.width * Self.height)
        self.pixels = pixels
    }

    @inline(__always)
    public func pixel(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return false }
        return pixels[y * Self.width + x]
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ on: Bool = true) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        pixels[y * Self.width + x] = on
    }

    public mutating func clear() {
        for i in pixels.indices { pixels[i] = false }
    }

    public mutating func invert() {
        for i in pixels.indices { pixels[i].toggle() }
    }

    /// Pack to the 640-byte SSD1306 page-major / column-packed format the Gen 3
    /// firmware expects: 5 pages (40 rows ÷ 8) × 128 columns; the byte at
    /// `page*128 + x` holds 8 vertically-stacked pixels for column `x`, rows
    /// `page*8 … page*8+7`, with bit 0 = the topmost row of that page.
    ///
    /// Verified against apex-tux's encoder for this keyboard and against the
    /// column-packed 128 × 40 format the vendor's description of the device gives.
    public func columnPacked() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 640)
        for y in 0..<Self.height {
            let page = y / 8
            let bit = UInt8(1 << (y % 8))
            let rowBase = y * Self.width
            let pageBase = page * Self.width
            for x in 0..<Self.width where pixels[rowBase + x] {
                out[pageBase + x] |= bit
            }
        }
        return out
    }
}

/// OLED command builders.
public enum OLED {
    public static let liveDeviceCommand: UInt8 = 0x1F
    public static let liveCommand: UInt8 = 0x81
    public static let resetCommand: UInt8 = 0x82

    public static let persistDeviceCommand: UInt8 = 0x38
    public static let persistCommand: UInt8 = 0x83

    public static let featurePayloadSize = 644

    /// Live (volatile) OLED write. Wire (Feature): `[0x1F][0x81][640 bytes]`.
    public static func liveWrite(_ bitmap: MonoBitmap) -> [UInt8] {
        liveWrite(packed: bitmap.columnPacked())
    }

    public static func liveWrite(packed: [UInt8]) -> [UInt8] {
        precondition(packed.count == 640)
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = liveDeviceCommand
        data[1] = liveCommand
        for i in 0..<640 { data[2 + i] = packed[i] }
        return data
    }

    /// Persistent OLED write (survives until changed / power cycle policy).
    /// Wire (Feature): `[0x38][0x83][0x00][640 bytes]`.
    public static func persist(_ bitmap: MonoBitmap) -> [UInt8] {
        let packed = bitmap.columnPacked()
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = persistDeviceCommand
        data[1] = persistCommand
        data[2] = 0x00
        for i in 0..<640 { data[3 + i] = packed[i] }
        return data
    }

    /// Hand the OLED back to firmware/onboard control.
    /// Wire (Output): `[0x1F][0x82]`.
    public static func resetDirect() -> [UInt8] {
        [liveDeviceCommand, resetCommand]
    }
}
