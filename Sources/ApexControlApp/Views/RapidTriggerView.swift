import SwiftUI
import ApexKit

struct RapidTriggerView: View {
    @EnvironmentObject var controller: DeviceController

    private var act: Binding<ActuationConfig> { $controller.actuation }
    private var isOn: Bool { controller.actuation.rapidTrigger }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                masterCard
                gaugeCard.frame(width: 300)
            }

            if isOn {
                whichKeysCard
                releaseModeCard
            }
        }
        .animation(Theme.Motion.reveal, value: isOn)
    }

    // MARK: - Master

    private var masterCard: some View {
        Card {
            SwitchRow(
                title: "Rapid Trigger",
                detail: "Normally a key has to travel back up past a fixed point before it can fire again. "
                    + "With Rapid Trigger it re-arms as soon as you start to lift, so repeated taps and "
                    + "direction changes register far sooner.",
                isOn: act.rapidTrigger
            )
            .onChange(of: controller.actuation.rapidTrigger) { _, _ in controller.applyActuation() }

            if isOn {
                Rule()

                ScaleControl.integer(
                    label: "Lift needed to re-arm",
                    value: Binding(
                        get: { Int(controller.actuation.rapidTriggerSensitivity) },
                        set: { controller.actuation.rapidTriggerSensitivity = UInt8($0) }),
                    range: 1...20,
                    majorEvery: 5,
                    detents: [2],
                    readout: { (String(format: "%.1f", Double($0) / 10), "mm") },
                    tickLabel: { String(format: "%.1f", Double($0) / 10) }
                )
                .onChange(of: controller.actuation.rapidTriggerSensitivity) { _, _ in controller.applyActuation() }

                Note("Smaller re-arms sooner and feels faster; too small and a shaky finger repeats the key. "
                     + "0.2 mm is the stock setting.")
            }
        }
    }

    private var gaugeCard: some View {
        Card(title: "Travel") {
            TravelGauge(
                actuation: Actuation.millimetres(forLevel: controller.actuation.globalLevel),
                secondActuation: nil,
                rapidTriggerReset: isOn
                    ? Double(controller.actuation.rapidTriggerSensitivity) / 10.0
                    : nil
            )
            Note(isOn
                 ? "The shaded band is how far you have to lift before the key can fire again."
                 : "With Rapid Trigger off the key has to travel most of the way back up before it "
                   + "counts as released. Turn it on to shorten that to a distance you choose.")
        }
    }

    // MARK: - Which keys

    private var whichKeysCard: some View {
        Card(title: "Which keys") {
            SegmentedRail(
                selection: Binding(
                    get: { controller.actuation.usePerKey },
                    set: { usePerKey in
                        // Write out the current state key by key on the way in.
                        // Otherwise every key we have not been told about keeps
                        // silently following the master switch, so the count is
                        // a guess and turning the master off later would take
                        // the chosen keys with it.
                        if usePerKey, controller.actuation.perKeyRapidTrigger.isEmpty {
                            let on = controller.actuation.rapidTrigger
                            for hid in ApexProTKLGen3.analogHIDOrder {
                                controller.actuation.perKeyRapidTrigger[hid] = on
                            }
                        }
                        controller.actuation.usePerKey = usePerKey
                        controller.applyActuation()
                    }
                ),
                items: [.init(false, "Every adjustable key"), .init(true, "Only the keys I choose")]
            )

            if controller.actuation.usePerKey {
                KeyboardView(
                    colorFor: { key in
                        guard key.isAnalog else { return LEDColor(r: 30, g: 33, b: 39) }
                        return controller.actuation.rapidTriggerEnabled(for: key.hid)
                            ? LEDColor(r: 235, g: 76, b: 10)
                            : LEDColor(r: 34, g: 38, b: 45)
                    },
                    isEnabled: { $0.isAnalog },
                    selected: controller.selectedKey,
                    layout: controller.layout ?? .ansi,
                    style: .data,
                    oled: controller.oledBitmap,
                    onKey: { key in
                        guard key.isAnalog else { return }
                        controller.selectedKey = key.hid
                        let now = controller.actuation.rapidTriggerEnabled(for: key.hid)
                        controller.actuation.perKeyRapidTrigger[key.hid] = !now
                        controller.applyActuation()
                    },
                    describe: { key in
                        guard key.isAnalog else { return "\(key.label), fixed switch" }
                        return "\(key.label), Rapid Trigger "
                            + (controller.actuation.rapidTriggerEnabled(for: key.hid) ? "on" : "off")
                    }
                )
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Button("WASD") { setKeys([0x1A, 0x04, 0x16, 0x07]) }.buttonStyle(.compactSecondary)
                    Button("Arrow keys") { setKeys([0x4F, 0x50, 0x51, 0x52]) }.buttonStyle(.compactSecondary)
                    Button("Everything") { setKeys(ApexProTKLGen3.analogHIDOrder) }.buttonStyle(.compactSecondary)
                    Button("Nothing") { setKeys([]) }.buttonStyle(.compactQuiet)
                    Spacer(minLength: 0)
                    Readout("\(enabledCount)", size: 12, color: Theme.signal)
                    Text("of \(ApexProTKLGen3.analogHIDOrder.count) keys")
                        .font(Typo.caption).foregroundStyle(Theme.ink3)
                }

                Note("Choosing keys here also switches Actuation to per-key mode — the keyboard keeps both "
                     + "in the same table.", icon: "link")
            } else {
                Note("Rapid Trigger applies to all 68 adjustable keys. The fixed mechanical keys are unaffected.")
            }
        }
    }

    private var enabledCount: Int {
        ApexProTKLGen3.analogHIDOrder.filter { controller.actuation.rapidTriggerEnabled(for: $0) }.count
    }

    private func setKeys(_ hids: [UInt8]) {
        let on = Set(hids)
        for hid in ApexProTKLGen3.analogHIDOrder {
            controller.actuation.perKeyRapidTrigger[hid] = on.contains(hid)
        }
        controller.applyActuation()
    }

    // MARK: - Release mode

    private var releaseModeCard: some View {
        Card(title: "Release mode") {
            SegmentedRail(
                selection: act.releaseMode,
                items: Actuation.ReleaseMode.allCases
                    .filter { $0 != .off }
                    .map { .init($0, $0.displayName) }
            )
            .onChange(of: controller.actuation.releaseMode) { _, _ in controller.applyActuation() }

            if controller.actuation.releaseMode.isUnverified {
                Banner(kind: .warning,
                       message: "The keyboard accepts this mode but does not describe what it changes. "
                           + "It is here to try; “Rapid Trigger” is the setting we can vouch for.")
            }
        }
    }
}
