import Foundation

/// A 24-bit RGB color as sent to the keyboard.
public struct LEDColor: Equatable, Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    public static let black = LEDColor(r: 0, g: 0, b: 0)
    public static let white = LEDColor(r: 255, g: 255, b: 255)
    public static let red = LEDColor(r: 255, g: 0, b: 0)
    public static let green = LEDColor(r: 0, g: 255, b: 0)
    public static let blue = LEDColor(r: 0, g: 0, b: 255)
    public static let steelOrange = LEDColor(r: 255, g: 74, b: 0)

    /// Create from hue (0...1), saturation (0...1), value (0...1).
    public static func hsv(_ h: Double, _ s: Double, _ v: Double) -> LEDColor {
        let hh = (h.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0)
        let i = Int(hh * 6.0)
        let f = hh * 6.0 - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return LEDColor(r: UInt8(max(0, min(255, r * 255))),
                        g: UInt8(max(0, min(255, g * 255))),
                        b: UInt8(max(0, min(255, b * 255))))
    }

    /// Parse `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        // `UInt32(_:radix:)` accepts a leading sign, so check the digits ourselves.
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Scale brightness by `factor` (0...1).
    public func scaled(by factor: Double) -> LEDColor {
        let f = max(0, min(1, factor))
        return LEDColor(r: UInt8(Double(r) * f), g: UInt8(Double(g) * f), b: UInt8(Double(b) * f))
    }

    /// Blend towards `other`: `amount` 0 gives this colour, 1 gives `other`.
    ///
    /// Used by the reactive effect to fade a struck key back into the resting
    /// colour. Fading to black instead leaves a visible step at the end of every
    /// press, because the key goes dark for a frame and then reappears at the
    /// resting level.
    public func mixed(with other: LEDColor, amount: Double) -> LEDColor {
        let t = max(0, min(1, amount))
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(a) + (Double(b) - Double(a)) * t).rounded())))
        }
        return LEDColor(r: lerp(r, other.r), g: lerp(g, other.g), b: lerp(b, other.b))
    }
}
