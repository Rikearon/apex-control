import SwiftUI
import UniformTypeIdentifiers
import ApexKit

struct ProfilesView: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var store: ProfileStore

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var confirmDeleteID: UUID?
    @State private var switchTemporarily = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let error = store.lastError {
                Banner(kind: .error, message: error) { store.lastError = nil }
            }

            HStack(alignment: .top, spacing: Theme.Space.l) {
                profileList
                onboardSlots.frame(width: 330)
            }
        }
        .alert("Delete this profile?", isPresented: Binding(
            get: { confirmDeleteID != nil },
            set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID { store.delete(id: id) }
                confirmDeleteID = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
        } message: {
            Text("“\(store.profile(id: confirmDeleteID)?.name ?? "This profile")” will be removed from your library. "
                 + "The keyboard keeps whatever settings it has now.")
        }
    }

    // MARK: - List

    private var profileList: some View {
        Card(title: "Your profiles") {
            HStack(spacing: Theme.Space.s) {
                Button("Save current setup") { saveCurrent() }
                    .buttonStyle(.primary)
                    .help("Capture lighting, actuation, Rapid Trigger, Rapid Tap, bindings and the screen")
                Button("Import…") { importProfile() }.buttonStyle(.secondary)
                Spacer(minLength: 0)
            }

            if store.profiles.isEmpty {
                EmptyState(
                    icon: "square.stack.3d.up",
                    title: "No profiles yet",
                    message: "Set the keyboard up the way you like it, then save it here. Switch back to it any time, or export it to share."
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(store.profiles) { profile in row(profile) }
                }
            }
        } accessory: {
            if !store.profiles.isEmpty {
                Readout("\(store.profiles.count)", size: 11, color: Theme.ink3)
            }
        }
    }

    @ViewBuilder
    private func row(_ profile: SoftwareProfile) -> some View {
        let isSelected = store.selectedProfileID == profile.id
        let isApplied = store.appliedProfileID == profile.id
        let isEdited = isApplied && !controller.matches(profile)

        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                LightingStrip(config: profile.lighting)
                    .frame(width: 4, height: 26)
                    .clipShape(Capsule())

                if renamingID == profile.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.apex)
                        .focused($renameFocused)
                        .frame(maxWidth: 220)
                        .onSubmit { commitRename(profile) }
                        .onExitCommand { renamingID = nil }
                } else {
                    Text(profile.name).font(Typo.bodyMedium).foregroundStyle(Theme.ink)
                }

                if isApplied {
                    Chip(text: isEdited ? "In use · edited" : "In use",
                         color: isEdited ? Theme.warn : Theme.signal, filled: true)
                }

                Spacer(minLength: 0)

                if !isSelected {
                    Text(profile.summary)
                        .font(Typo.caption).foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }

            if isSelected {
                Text(profile.summary)
                    .font(Typo.caption).foregroundStyle(Theme.ink3)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Button("Apply") {
                        controller.apply(profile)
                        store.markApplied(profile.id)
                    }
                    .buttonStyle(ApexButton(role: .primary, compact: true))
                    .disabled(!controller.isConnected)

                    Button("Save over it") {
                        var updated = controller.captureCurrent(name: profile.name)
                        updated.id = profile.id
                        updated.createdAt = profile.createdAt
                        store.update(updated)
                        controller.note("Updated “\(profile.name)”")
                    }
                    .buttonStyle(.compactSecondary)
                    .help("Replace this profile with what the keyboard is doing now")

                    Button("Rename") { beginRename(profile) }.buttonStyle(.compactQuiet)
                    Button("Duplicate") { store.duplicate(id: profile.id) }.buttonStyle(.compactQuiet)
                    Button("Export…") { export(profile) }.buttonStyle(.compactQuiet)

                    Spacer(minLength: 0)

                    IconButton(systemName: "trash", help: "Delete this profile", role: .destructive) {
                        confirmDeleteID = profile.id
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.surfaceHi.opacity(0.9) : Theme.surfaceHi.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(isSelected ? Theme.signal.opacity(0.55) : Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectedProfileID = profile.id }
        .animation(Theme.Motion.snap, value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name). \(profile.summary)")
    }

    // MARK: - Onboard slots

    private var onboardSlots: some View {
        Card(title: "Keyboard's own slots") {
            Note("The keyboard stores five setups of its own. They work on any computer with nothing installed. "
                 + "Apex Control can switch between them and saves your bindings, actuation, Rapid Trigger and "
                 + "Rapid Tap into the first one by itself; writing a chosen profile into a chosen slot is not "
                 + "built yet.")

            VStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { slot in slotRow(slot) }
            }

            Rule()

            SwitchRow(
                title: "Switch temporarily",
                detail: "Go back to the previous slot when the keyboard loses power. This command is not "
                    + "confirmed on this firmware — if it does nothing, the switch is simply permanent.",
                isOn: $switchTemporarily
            )
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: Int) -> some View {
        let isActive = store.lastCommandedSlot == UInt8(slot)
        HStack(spacing: Theme.Space.s) {
            Text("\(slot + 1)")
                .font(Typo.readout(11, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(isActive ? Theme.signal.opacity(0.22) : Theme.surfaceHi))
                .foregroundStyle(isActive ? Theme.signal : Theme.ink3)

            Picker("", selection: slotBinding(slot)) {
                Text("Not labelled").tag(UUID?.none)
                ForEach(store.profiles) { (p: SoftwareProfile) in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            .apexPicker()
            .help("A label for your own reference — it does not change what is stored in the keyboard")

            Button("Switch") {
                controller.setProfileVolatile(switchTemporarily)
                controller.loadOnboardSlot(UInt8(slot))
                store.noteCommandedSlot(UInt8(slot))
                controller.note("Told the keyboard to load slot \(slot + 1)")
            }
            .buttonStyle(.compactSecondary)
            .disabled(!controller.isConnected)
        }
    }

    private func slotBinding(_ slot: Int) -> Binding<UUID?> {
        Binding<UUID?>(
            get: { store.onboardSlots.indices.contains(slot) ? store.onboardSlots[slot] : nil },
            set: { store.assign(profileID: $0, toSlot: slot) }
        )
    }

    // MARK: - Actions

    private func beginRename(_ profile: SoftwareProfile) {
        renameText = profile.name
        renamingID = profile.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ profile: SoftwareProfile) {
        store.rename(id: profile.id, to: renameText)
        renamingID = nil
    }

    private func saveCurrent() {
        let created = store.add(controller.captureCurrent(name: store.nextProfileName()))
        store.markApplied(created.id)
        controller.note("Saved “\(created.name)”")
    }

    private func export(_ profile: SoftwareProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            store.export(id: profile.id, to: url)
            controller.note("Exported “\(profile.name)”")
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            if let imported = store.importProfile(from: url) {
                controller.note("Imported “\(imported.name)”")
            }
        }
    }
}

// MARK: - Lighting strip

/// A thin vertical slice of a profile's lighting, so the list is scannable by
/// colour rather than only by name.
struct LightingStrip: View {
    let config: LightingConfig

    var body: some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var colors: [Color] {
        switch config.kind {
        case .staticColor, .breathe:
            return [Color(config.baseColor), Color(config.baseColor).opacity(0.5)]
        case .perKey:
            let used = config.perKeyColors.values.values.filter { $0.luminance > 0.05 }
            guard !used.isEmpty else { return [Theme.ink3.opacity(0.3), Theme.ink3.opacity(0.3)] }
            return used.prefix(6).map { Color($0) }
        case .rainbowWave, .spectrumCycle:
            return stride(from: 0.0, through: 1.0, by: 0.2).map { LEDColor.hsv($0, 1, 1).color }
        case .reactive:
            return [Color(config.baseColor), Color(config.secondaryColor).opacity(0.5)]
        }
    }
}
