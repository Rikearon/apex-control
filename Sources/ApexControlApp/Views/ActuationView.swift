import SwiftUI
import ApexKit

struct ActuationView: View {
    @EnvironmentObject var controller: DeviceController

    private var act: Binding<ActuationConfig> { $controller.actuation }

    private var selectedAnalogKey: Key? {
        guard let hid = controller.selectedKey, let key = ApexProTKLGen3.key(forHID: hid), key.isAnalog
        else { return nil }
        return key
    }

    /// The depth the gauge is showing: the selected key when there is one,
    /// otherwise the global setting.
    private var gaugeLevel: Int {
        guard controller.actuation.usePerKey, let key = selectedAnalogKey else {
            return controller.actuation.globalLevel
        }
        return controller.actuation.level(for: key.hid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            KeyboardView(
                colorFor: heatColor,
                isEnabled: { $0.isAnalog },
                selected: controller.selectedKey,
                layout: controller.layout ?? .ansi,
                style: .data,
                oled: controller.oledBitmap,
                onKey: { key in if key.isAnalog { controller.selectedKey = key.hid } },
                describe: { key in
                    guard key.isAnalog else { return "\(key.label), fixed switch" }
                    return String(format: "%@, actuates at %.1f millimetres",
                                  key.label,
                                  Actuation.millimetres(forLevel: controller.actuation.level(for: key.hid)))
                }
            )
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.l) {
                    globalCard
                    perKeyCard
                }
                gaugeCard.frame(width: 300)
            }
        }
    }

    // MARK: - Global

    private var globalCard: some View {
        Card(title: "All keys") {
            ScaleControl.integer(
                label: "Actuation point",
                value: act.globalLevel,
                range: 1...40,
                majorEvery: 5,
                detents: [2, 10, 15, 22],
                readout: { (String(format: "%.1f", Actuation.millimetres(forLevel: $0)), "mm") },
                tickLabel: { String(format: "%.1f", Actuation.millimetres(forLevel: $0)) }
            )
            .onChange(of: controller.actuation.globalLevel) { _, _ in controller.applyActuation() }

            HStack(spacing: 6) {
                preset("Hair trigger", level: 2)
                preset("Gaming", level: 10)
                preset("Balanced", level: 15)
                preset("Typing", level: 22)
                Spacer(minLength: 0)
            }

            Rule()

            SwitchRow(
                title: "Set each key separately",
                detail: "Keep a hair trigger on the keys you game with and a normal press everywhere else.",
                isOn: act.usePerKey
            )
            .onChange(of: controller.actuation.usePerKey) { _, _ in controller.applyActuation() }
        }
    }

    private func preset(_ title: String, level: Int) -> some View {
        let isOn = controller.actuation.globalLevel == level
        return Button {
            controller.actuation.globalLevel = level
            controller.applyActuation()
        } label: {
            VStack(spacing: 1) {
                Text(title).font(Typo.captionMedium)
                Readout(String(format: "%.1f", Actuation.millimetres(forLevel: level)), unit: "mm",
                        size: 10, color: isOn ? Color(srgb: 0x140A04).opacity(0.72) : Theme.ink3)
            }
        }
        .buttonStyle(ApexButton(role: isOn ? .primary : .secondary, compact: true))
    }

    // MARK: - Per key

    @ViewBuilder
    private var perKeyCard: some View {
        Card(title: "Per key") {
            if !controller.actuation.usePerKey {
                EmptyState(
                    icon: "square.grid.3x3",
                    title: "Every key uses the same point",
                    message: "Turn on “Set each key separately” to tune individual keys. The 68 adjustable keys are the lit ones above."
                ) {
                    Button("Set each key separately") {
                        controller.actuation.usePerKey = true
                        controller.applyActuation()
                    }
                    .buttonStyle(.secondary)
                }
            } else if let key = selectedAnalogKey {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(key.label).font(Typo.title).foregroundStyle(Theme.ink)
                    if controller.actuation.perKey[key.hid] != nil {
                        Chip(text: "Custom", color: Theme.signal, filled: true)
                    } else {
                        Chip(text: "Follows all keys")
                    }
                    Spacer(minLength: 0)
                }

                ScaleControl.integer(
                    label: "Actuation point",
                    value: Binding(
                        get: { controller.actuation.perKey[key.hid] ?? controller.actuation.globalLevel },
                        set: { controller.actuation.perKey[key.hid] = $0 }),
                    range: 1...40,
                    majorEvery: 5,
                    readout: { (String(format: "%.1f", Actuation.millimetres(forLevel: $0)), "mm") },
                    tickLabel: { String(format: "%.1f", Actuation.millimetres(forLevel: $0)) }
                )
                .onChange(of: controller.actuation.perKey) { _, _ in controller.applyActuation() }

                HStack {
                    Button("Follow all keys again") {
                        controller.actuation.perKey[key.hid] = nil
                        controller.applyActuation()
                    }
                    .buttonStyle(.compactSecondary)
                    .disabled(controller.actuation.perKey[key.hid] == nil)

                    if controller.actuation.perKey.count > 0 {
                        Button("Clear all custom keys") {
                            controller.actuation.perKey = [:]
                            controller.applyActuation()
                        }
                        .buttonStyle(.compactQuiet)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                EmptyState(icon: "cursorarrow.click",
                           title: "No key selected",
                           message: "Click an adjustable key on the board above. Drag across several to work through a row.")
            }
        }
    }

    // MARK: - Gauge

    private var gaugeCard: some View {
        Card(title: "Travel") {
            TravelGauge(
                actuation: Actuation.millimetres(forLevel: gaugeLevel),
                secondActuation: controller.actuation.secondActuationEnabled
                    ? selectedAnalogKey.flatMap { controller.actuation.secondActuationLevel(for: $0.hid) }
                        .map { Actuation.millimetres(forLevel: $0) }
                    : nil,
                rapidTriggerReset: rapidTriggerReset
            )

            Rule()

            Eyebrow("Board")
            heatLegend
        }
    }

    private var rapidTriggerReset: Double? {
        guard controller.actuation.rapidTrigger else { return nil }
        if let key = selectedAnalogKey, controller.actuation.usePerKey,
           !controller.actuation.rapidTriggerEnabled(for: key.hid) {
            return nil
        }
        return Double(controller.actuation.rapidTriggerSensitivity) / 10.0
    }

    private var heatLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            LinearGradient(
                colors: stride(from: 0.0, through: 1.0, by: 0.05).map { Color(Self.levelColor($0)) },
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 6)
            .clipShape(Capsule())

            HStack {
                Readout("0.1", unit: "mm", size: 10, color: Theme.ink3)
                Text("sensitive").font(Typo.caption).foregroundStyle(Theme.ink3)
                Spacer()
                Text("deep").font(Typo.caption).foregroundStyle(Theme.ink3)
                Readout("4.0", unit: "mm", size: 10, color: Theme.ink3)
            }
        }
    }

    // MARK: - Colour

    private func heatColor(for key: Key) -> LEDColor {
        guard key.isAnalog else { return LEDColor(r: 30, g: 33, b: 39) }
        let level = controller.actuation.level(for: key.hid)
        return Self.levelColor(Double(level - 1) / 39.0)
    }

    /// A warm single-family ramp: golden where the key registers early, deep red
    /// where it needs a full press. Data on this pane is a setting you chose, so
    /// it stays inside the signal palette rather than borrowing a second hue.
    static func levelColor(_ t: Double) -> LEDColor {
        LEDColor.hsv(0.13 - 0.13 * t, 0.72 + 0.28 * t, 1.0 - 0.16 * t)
    }
}
