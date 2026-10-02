import SwiftUI

/// A cross-section of one switch's travel.
///
/// Every number on the performance panes is a depth on the same 4 mm stroke, so
/// this draws the stroke itself and marks where things happen on it: where the
/// key registers, where it re-arms under Rapid Trigger, and where a second
/// binding fires. It turns "1.5" into somewhere you can point at.
struct TravelGauge: View {
    /// Where the key registers, in millimetres.
    var actuation: Double
    /// Second, deeper trigger point — nil when there isn't one.
    var secondActuation: Double?
    /// How far back up the key must come before it can fire again, in mm.
    /// nil when Rapid Trigger is off.
    var rapidTriggerReset: Double?
    var height: CGFloat = 156

    private let total: Double = 4.0
    private let channelWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GeometryReader { geo in
                let h = geo.size.height
                let y = { (mm: Double) in h * min(1, max(0, mm / total)) }

                ZStack(alignment: .top) {
                    // The stroke: top is rest, bottom is fully pressed.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceLo)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.hairline, lineWidth: 1))

                    // Travel before the key registers.
                    UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 6)
                        .fill(LinearGradient(colors: [Theme.signal.opacity(0.32), Theme.signal.opacity(0.16)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: y(actuation))

                    // Where Rapid Trigger re-arms the key.
                    if let reset = rapidTriggerReset {
                        let top = y(max(0, actuation - reset))
                        Rectangle()
                            .fill(Theme.signal.opacity(0.16))
                            .frame(height: max(1, y(actuation) - top))
                            .offset(y: top)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Theme.signal.opacity(0.5))
                                    .frame(height: 1).offset(y: top)
                            }
                    }

                    // Graduations every 0.5 mm, longer on the whole millimetre.
                    ForEach(1..<8) { i in
                        let whole = i % 2 == 0
                        Rectangle()
                            .fill(.white.opacity(whole ? 0.30 : 0.15))
                            .frame(width: whole ? channelWidth * 0.46 : channelWidth * 0.26, height: 1)
                            .offset(y: y(Double(i) * 0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    marker(at: y(actuation), color: Theme.signal, solid: true)
                    if let second = secondActuation {
                        marker(at: y(second), color: Theme.signal.opacity(0.75), solid: false)
                    }
                }
            }
            .frame(width: channelWidth, height: height)

            labels
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Travel")
        .accessibilityValue(accessibilitySummary)
    }

    private func marker(at y: CGFloat, color: Color, solid: Bool) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: solid ? 2 : 1.5)
            .offset(y: y - (solid ? 1 : 0.75))
            .shadow(color: color.opacity(0.7), radius: 3)
            .opacity(solid ? 1 : 0.85)
    }

    /// One labelled point on the stroke.
    private struct Pin {
        let title: String
        let mm: Double
        let color: Color
        let isCaption: Bool
    }

    private var pins: [Pin] {
        var out: [Pin] = [Pin(title: "Registers", mm: actuation, color: Theme.signal, isCaption: false)]
        if let reset = rapidTriggerReset {
            out.append(Pin(title: "Re-arms", mm: max(0, actuation - reset),
                           color: Theme.signal.opacity(0.75), isCaption: false))
        }
        if let second = secondActuation {
            out.append(Pin(title: "Second point", mm: second,
                           color: Theme.signal.opacity(0.85), isCaption: false))
        }
        out.append(Pin(title: "Rest", mm: 0, color: Theme.ink3, isCaption: true))
        out.append(Pin(title: "Bottom out", mm: total, color: Theme.ink3, isCaption: true))
        return out.sorted { $0.mm < $1.mm }
    }

    private var labels: some View {
        GeometryReader { geo in
            let placed = place(pins, in: geo.size.height)
            ZStack(alignment: .topLeading) {
                ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                    pinLabel(item.pin).offset(y: item.y)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lay the labels out top to bottom, never closer together than one line.
    ///
    /// A shallow actuation with Rapid Trigger on puts "Rest", "Re-arms" and
    /// "Registers" within a tenth of a millimetre of each other; drawn at their
    /// true positions they land on top of one another and none of them is
    /// readable. The markers on the stroke itself stay exact.
    private func place(_ pins: [Pin], in height: CGFloat) -> [(pin: Pin, y: CGFloat)] {
        let lineHeight: CGFloat = 15
        var out: [(pin: Pin, y: CGFloat)] = []
        var lastY: CGFloat = -.greatestFiniteMagnitude

        for pin in pins {
            let ideal = height * CGFloat(min(1, max(0, pin.mm / total))) - lineHeight / 2
            let y = max(ideal, lastY + lineHeight)
            out.append((pin, y))
            lastY = y
        }

        // If pushing down ran past the bottom, pull the whole run back up.
        if let last = out.last, last.y + lineHeight > height {
            let overflow = last.y + lineHeight - height
            var shift = overflow
            for item in out.reversed() where item.y - shift < 0 { shift = item.y }
            out = out.map { ($0.pin, $0.y - shift) }
        }
        return out
    }

    @ViewBuilder
    private func pinLabel(_ pin: Pin) -> some View {
        if pin.isCaption {
            Text(pin.title)
                .font(Typo.eyebrow).tracking(0.8)
                .foregroundStyle(pin.color)
                .frame(height: 15, alignment: .center)
        } else {
            HStack(spacing: 5) {
                Rectangle().fill(pin.color).frame(width: 6, height: 1)
                Text(pin.title).font(Typo.caption).foregroundStyle(Theme.ink2)
                Readout(String(format: "%.1f", pin.mm), unit: "mm", size: 11, color: pin.color)
            }
            .frame(height: 15, alignment: .center)
        }
    }

    private var accessibilitySummary: String {
        var parts = [String(format: "registers at %.1f millimetres", actuation)]
        if let reset = rapidTriggerReset {
            parts.append(String(format: "re-arms after %.1f millimetres of release", reset))
        }
        if let second = secondActuation {
            parts.append(String(format: "second point at %.1f millimetres", second))
        }
        return parts.joined(separator: ", ")
    }
}
