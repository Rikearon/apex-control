import Foundation

/// The rules `apexctl` applies to command-line arguments, kept in the library so that
/// they can be unit-tested without a keyboard. Each returns `nil` (or clamps) instead of
/// exiting; the command-line tool turns that into an error message.
///
/// They are strict on purpose: an argument that is silently dropped or reinterpreted
/// sends the keyboard a different command from the one that was typed.
public enum ArgumentParsing {

    /// One byte written as one or two hex digits, with or without a `0x` prefix.
    ///
    /// `UInt8(_:radix:)` alone also accepts a leading sign and any number of leading
    /// zeros, so the digits are checked first.
    public static func hexByte(_ text: String) -> UInt8? {
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard (1...2).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt8(digits, radix: 16)
    }

    /// An onboard profile slot, a plain decimal number from 0 to 4. There is
    /// deliberately no fallback to slot 0: saving and restoring write flash, and a
    /// typo must not pick a slot.
    public static func slot(_ text: String) -> UInt8? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let slot = UInt8(text), slot <= 4 else { return nil }
        return slot
    }

    /// A whole number written with plain decimal digits and no sign, if it lies in
    /// `range`. For counts and delays, where a typo must not become a different value.
    public static func wholeNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    /// A finite number, or `fallback` when the text is missing or is not a number.
    /// `Double("nan")` and `Double("inf")` both parse, and would trap in the
    /// arithmetic that follows.
    public static func finiteNumber(_ text: String?, or fallback: Double) -> Double {
        guard let text, let value = Double(text), value.isFinite else { return fallback }
        return value
    }

    /// Frames per second an animation may be streamed at. 30 is the ceiling: faster
    /// frames outpace the LED controller and tear (docs/PROTOCOL.md).
    public static let frameRates: ClosedRange<Double> = 1...30

    /// Seconds an animation may run for.
    public static let durations: ClosedRange<Double> = 0...3600

    /// `value` limited to `range`.
    public static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
