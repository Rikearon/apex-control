import SwiftUI
import ApexKit

// MARK: - Colour bridging

extension Color {
    init(_ c: LEDColor) {
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

extension LEDColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: UInt8(max(0, min(1, ns.redComponent)) * 255),
                  g: UInt8(max(0, min(1, ns.greenComponent)) * 255),
                  b: UInt8(max(0, min(1, ns.blueComponent)) * 255))
    }
    var color: Color { Color(self) }

    /// Perceived brightness, 0…1. Used to decide keycap label contrast and how
    /// much bloom a lit key throws.
    var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }
}

// MARK: - Theme

/// The visual language.
///
/// The palette is deliberately three families with non-overlapping jobs, so
/// colour carries meaning instead of decoration:
///
/// - **Graphite** is every surface. The app is the chassis the keyboard sits in.
/// - **Signal orange** means *you*: a setting you changed, a control that is on.
///   It is never used for structure or emphasis, only for state you own.
/// - **Readout cyan** means *the device*: values measured or reported by the
///   keyboard, and the OLED. It is never used for anything you set.
///
/// Dark only, and deliberately so — every pane previews RGB output, and a light
/// surround would misrepresent the colours you are about to send to the board.
enum Theme {

    // MARK: Surfaces

    /// Window background — the room the chassis sits in.
    static let void = Color(srgb: 0x0A0B0D)
    /// Sidebar, toolbar, footer.
    static let chassis = Color(srgb: 0x14161A)
    /// Cards.
    static let surface = Color(srgb: 0x1C1F24)
    /// Controls, keycap faces, inset wells.
    static let surfaceHi = Color(srgb: 0x262A31)
    /// Pressed / recessed control.
    static let surfaceLo = Color(srgb: 0x101216)

    /// The only border treatment in the app.
    static let hairline = Color.white.opacity(0.075)
    static let hairlineStrong = Color.white.opacity(0.14)

    // MARK: Meaning

    /// The app's signal orange. Reserved for settings you have changed and controls
    /// that are on.
    static let signal = Color(srgb: 0xFF4A00)
    /// Reserved for values the keyboard reports back, and for the OLED.
    static let readout = Color(srgb: 0x5AD9E8)

    static let ok = Color(srgb: 0x46D18A)
    static let warn = Color(srgb: 0xFFA22B)
    static let danger = Color(srgb: 0xFF5A5A)

    // MARK: Ink

    static let ink = Color(srgb: 0xF0F2F4)
    static let ink2 = Color(srgb: 0x98A0AA)
    static let ink3 = Color(srgb: 0x646C77)

    // MARK: Metrics

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 30
    }

    enum Radius {
        static let control: CGFloat = 7
        static let card: CGFloat = 11
        static let chassis: CGFloat = 16
    }

    /// Content column width. Panes centre inside this so the layout does not
    /// sprawl on a wide display.
    static let contentMaxWidth: CGFloat = 1160

    /// Longest line of running text. A card can be 1100 points wide; a sentence
    /// should not be — past roughly 75 characters the eye loses the next line.
    static let textMeasure: CGFloat = 620

    /// Widest an interactive control gets. A slider the width of the window
    /// takes a long drag to move one step, and a switch at the far right of a
    /// wide card reads as unrelated to its label.
    static let controlMeasure: CGFloat = 660

    // MARK: Motion

    enum Motion {
        /// Control state changes. No overshoot — this is machined, not bouncy.
        static let snap = Animation.spring(response: 0.26, dampingFraction: 0.92)
        /// Pane and content transitions.
        static let pane = Animation.easeOut(duration: 0.2)
        /// Banners and disclosure.
        static let reveal = Animation.spring(response: 0.34, dampingFraction: 0.88)
        /// LEDs behave like light: quick attack, slower decay.
        static let light = Animation.easeOut(duration: 0.32)
    }
}

// MARK: - Typography

/// A fixed type scale. Two roles carry the personality:
///
/// - `eyebrow` is condensed, uppercase and widely tracked — the silkscreen
///   labelling printed on the hardware itself.
/// - `readout` is monospaced and tabular — every measured value in this app is
///   an instrument reading and is set like one.
enum Typo {
    static let display = Font.system(size: 25, weight: .semibold)
    static let title = Font.system(size: 18, weight: .semibold)
    static let heading = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let callout = Font.system(size: 12)
    static let calloutMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)

    static let eyebrow = Font.system(size: 10, weight: .semibold).width(.condensed)

    /// Instrument readout. Monospaced so digits do not shuffle as values change.
    static func readout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Small helpers

extension Color {
    init(srgb hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// An uppercase, condensed, widely-tracked label — the app's structural voice.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.ink3
    init(_ text: String, color: Color = Theme.ink3) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(Typo.eyebrow)
            .tracking(1.3)
            .foregroundStyle(color)
    }
}

/// A measured value with its unit set smaller and quieter, so a column of them
/// aligns on the number rather than on the string.
struct Readout: View {
    let value: String
    var unit: String?
    var size: CGFloat = 14
    var color: Color = Theme.ink

    init(_ value: String, unit: String? = nil, size: CGFloat = 14, color: Color = Theme.ink) {
        self.value = value
        self.unit = unit
        self.size = size
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            Text(value)
                .font(Typo.readout(size))
                .monospacedDigit()
                .foregroundStyle(color)
            if let unit {
                Text(unit)
                    .font(Typo.readout(size * 0.68, weight: .regular))
                    .foregroundStyle(color.opacity(0.55))
            }
        }
    }
}

extension View {
    /// Honour Reduce Motion without scattering the check through every view.
    func animationRespectingMotion(_ animation: Animation?, value: some Equatable, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
