import SwiftUI
import ApexKit

struct RapidTapView: View {
    @EnvironmentObject var controller: DeviceController

    private var config: Binding<RapidTapConfig> { $controller.rapidTap }
    private let selectableKeys = ApexProTKLGen3.keys.filter(\.isAnalog)

    /// Keys claimed by more than one pair. The firmware has one slot per key, so
    /// a repeat makes the winner undefined and the pair is dropped on write.
    private var duplicatedKeys: Set<UInt8> {
        var seen = Set<UInt8>(), dupes = Set<UInt8>()
        for p in controller.rapidTap.pairs {
            for k in [p.key1, p.key2] {
                if seen.contains(k) { dupes.insert(k) } else { seen.insert(k) }
            }
        }
        return dupes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Card {
                SwitchRow(
                    title: "Rapid Tap",
                    detail: "Hold two opposing keys — A and D, say — and the keyboard decides which one counts "
                        + "instead of sending both. This is the null bind used for counter-strafing.",
                    isOn: config.enabled
                )
            }

            Card(title: "Key pairs") {
                if controller.rapidTap.pairs.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right",
                               title: "No pairs yet",
                               message: "Add a pair of opposing keys and choose which one wins when both are held.") {
                        Button("Add A and D") { addPair(0x04, 0x07) }.buttonStyle(.primary)
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(config.pairs) { $pair in
                            pairRow($pair)
                        }
                    }
                }

                if controller.rapidTap.pairs.contains(where: { $0.key1 == $0.key2 }) {
                    Banner(kind: .warning, message: "A pair needs two different keys. Pairs using the same key twice are skipped.")
                }
                if !duplicatedKeys.isEmpty {
                    Banner(kind: .warning, message: "Each key can belong to only one pair. Repeats are skipped.")
                }

                Rule()

                HStack(spacing: Theme.Space.s) {
                    Button("Add pair") { addPair() }
                        .buttonStyle(.secondary)
                        .disabled(controller.rapidTap.pairs.count >= 10)

                    if !controller.rapidTap.pairs.contains(where: { $0.key1 == 0x04 && $0.key2 == 0x07 }) {
                        Button("Add A and D") { addPair(0x04, 0x07) }.buttonStyle(.compactQuiet)
                    }

                    Spacer(minLength: 0)

                    Readout("\(controller.rapidTap.validPairs.count)", size: 12,
                            color: controller.rapidTap.enabled ? Theme.signal : Theme.ink3)
                    Text("of \(controller.rapidTap.pairs.count) sent to the keyboard · 10 max")
                        .font(Typo.caption).foregroundStyle(Theme.ink3)
                }
            }
        }
        // Every other pane writes as you edit; this one used to need a button.
        .onChange(of: controller.rapidTap) { _, _ in controller.applyRapidTap() }
    }

    // MARK: - Row

    private func pairRow(_ pair: Binding<RapidTapConfig.Pair>) -> some View {
        let same = pair.wrappedValue.key1 == pair.wrappedValue.key2
        return HStack(spacing: Theme.Space.s) {
            keyPicker(selection: pair.key1,
                      conflicting: same || duplicatedKeys.contains(pair.wrappedValue.key1))

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink3)

            keyPicker(selection: pair.key2,
                      conflicting: same || duplicatedKeys.contains(pair.wrappedValue.key2))

            Picker("", selection: pair.mode) {
                Text("Newest press wins").tag(UInt8(0))
                Text("Neither one counts").tag(UInt8(1))
                Text("\(name(pair.wrappedValue.key1)) always wins").tag(UInt8(2))
                Text("\(name(pair.wrappedValue.key2)) always wins").tag(UInt8(3))
            }
            .apexPicker(width: 190)

            Toggle("Send both", isOn: pair.reportBoth)
                .toggleStyle(.checkbox)
                .font(Typo.caption)
                .help("Report both keys instead of suppressing the losing one")

            Spacer(minLength: 0)

            IconButton(systemName: "trash", help: "Remove this pair", role: .destructive) {
                controller.rapidTap.pairs.removeAll { $0.id == pair.wrappedValue.id }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 660, alignment: .leading)
        .background(Theme.surfaceHi.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(same ? Theme.warn.opacity(0.5) : Theme.hairline, lineWidth: 1)
        )
    }

    private func keyPicker(selection: Binding<UInt8>, conflicting: Bool) -> some View {
        Picker("", selection: selection) {
            ForEach(selectableKeys) { k in Text(k.label).tag(k.hid) }
        }
        .apexPicker(width: 84)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(conflicting ? Theme.warn : .clear, lineWidth: 1.5)
        )
        .accessibilityLabel("Key")
    }

    private func name(_ hid: UInt8) -> String {
        ApexProTKLGen3.key(forHID: hid)?.label ?? "Key"
    }

    private func addPair(_ key1: UInt8? = nil, _ key2: UInt8? = nil) {
        guard controller.rapidTap.pairs.count < 10 else { return }
        var pair = RapidTapConfig.Pair()
        if let key1, let key2 {
            pair.key1 = key1
            pair.key2 = key2
        } else if let free = firstFreePair() {
            pair.key1 = free.0
            pair.key2 = free.1
        }
        controller.rapidTap.pairs.append(pair)
    }

    /// Pick two keys that are not already spoken for, so a new row starts valid
    /// instead of immediately warning.
    private func firstFreePair() -> (UInt8, UInt8)? {
        var used = Set<UInt8>()
        for p in controller.rapidTap.pairs { used.insert(p.key1); used.insert(p.key2) }
        let free = ApexProTKLGen3.analogHIDOrder.filter { !used.contains($0) }
        guard free.count >= 2 else { return nil }
        return (free[0], free[1])
    }
}
