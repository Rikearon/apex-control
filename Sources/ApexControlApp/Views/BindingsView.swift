import SwiftUI
import ApexKit

/// How the inspector presents a binding.
enum BindingCategory: String, CaseIterable, Identifiable {
    case standard = "Default"
    case keyboard = "Key"
    case media = "Media"
    case mouse = "Mouse"
    case disabled = "Off"
    case advanced = "Raw"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard: return "arrow.uturn.backward"
        case .keyboard: return "keyboard"
        case .media: return "playpause.fill"
        case .mouse: return "computermouse.fill"
        case .disabled: return "nosign"
        case .advanced: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Whether choosing this category is itself a decision about the key, or
    /// merely a request to see a different editor. Only the first kind is
    /// allowed to write to the keyboard on selection.
    var writesImmediately: Bool {
        self == .standard || self == .disabled
    }

    static func of(_ binding: Mappings.Binding) -> BindingCategory {
        if binding.isDisabled { return .disabled }
        if binding.isDefault { return .standard }
        switch binding.knownFunction {
        case .keyboard: return .keyboard
        case .consumer: return .media
        case .mouseButton1, .mouseButton2, .mouseButton3, .mouseButton4,
             .mouseButton5, .mouseButton6, .mouseButton7, .mouseButton8,
             .mouseWheelUp, .mouseWheelDown, .panLeft, .panRight: return .mouse
        default: return .advanced
        }
    }
}

extension Mappings.Binding {
    /// Short label for a keycap badge. Kept to a couple of glyphs — the keycap
    /// is small and the inspector carries the full description.
    var compactSummary: String? {
        if isDefault { return nil }
        if isDisabled { return "✕" }
        switch knownFunction {
        case .keyboard:
            let usages = keyboardUsages
            guard !usages.isEmpty else { return "✕" }
            return KeyComboFormatter.compactSymbols(for: usages)
        case .consumer:
            return Mappings.ConsumerAction.allCases.first { $0.usage == consumerUsage }
                .map { Self.mediaGlyph($0) } ?? "media"
        case .macro: return "M\(keyCodes.first ?? 0)"
        case .external: return "app"
        case .meta: return "fn"
        default:
            return Mappings.MouseAction(function: function).map { Self.mouseGlyph($0) } ?? "•"
        }
    }

    private static func mediaGlyph(_ a: Mappings.ConsumerAction) -> String {
        switch a {
        case .playPause, .play, .pause: return "⏯"
        case .nextTrack, .fastForward: return "⏭"
        case .previousTrack, .rewind: return "⏮"
        case .stop: return "⏹"
        case .mute: return "🔇"
        case .volumeUp: return "🔊"
        case .volumeDown: return "🔉"
        default: return "media"
        }
    }

    private static func mouseGlyph(_ a: Mappings.MouseAction) -> String {
        switch a {
        case .wheelUp: return "↑"
        case .wheelDown: return "↓"
        case .panLeft: return "←"
        case .panRight: return "→"
        default: return "M\(a.function)"
        }
    }
}

// MARK: - Pane

struct BindingsView: View {
    @EnvironmentObject var controller: DeviceController

    /// What the board is being asked for, if anything: a remap source, or the
    /// Fn key. Nil means the board is in its ordinary selecting state.
    private enum BoardQuestion: Equatable {
        case remapSource(UInt8)
        case metaToggle
    }

    /// The editor the user last chose. Held separately from the binding itself
    /// so picking a category that has not been written yet — "Raw", above all —
    /// does not snap straight back to whatever is currently on the key.
    @State private var editorCategory: BindingCategory?
    @State private var question: BoardQuestion?
    @State private var showingUsagePicker = false
    @State private var showRightModifiers = false
    @State private var confirmResetAll = false
    @State private var confirmClearFn = false
    /// A change that would erase one of the keyboard's own Fn shortcuts, held
    /// until the user says yes.
    @State private var pendingFactoryReplacement: FactoryReplacement?
    @State private var rawFunction: String = "0x51"
    @State private var rawCodes: String = "00 00 00 00"

    private var layer: Mappings.Layer { controller.bindingLayer }

    var body: some View {
        content
            .onChange(of: controller.selectedKey) { _, _ in resetEditorState() }
            .onChange(of: controller.bindingLayer) { _, _ in resetEditorState() }
            .confirmationDialog(item: $pendingFactoryReplacement,
                                title: \.title, message: \.explanation) { change in
                Button("Erase it", role: .destructive) { change.perform() }
                Button("Leave it alone", role: .cancel) {}
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            layerPicker
            board

            HStack(alignment: .top, spacing: Theme.Space.l) {
                inspector
                sideColumn.frame(width: 310)
            }
        }
    }

    /// Identifiable so the confirmation can be driven by the change itself
    /// rather than by a separate boolean that can fall out of step with it.
    private struct FactoryReplacement: Identifiable {
        let id = UUID()
        let keyLabel: String
        let what: String
        let perform: () -> Void

        var title: String { "Erase a shortcut the keyboard came with?" }
        var explanation: String {
            "Holding Fn with \(keyLabel) runs one of the keyboard's built-in shortcuts — "
            + "brightness, media or the screen. Having it \(what) erases that shortcut from "
            + "the hardware. Undo can bring it back while Apex Control stays open; after "
            + "that, the only way back we know of is a profile backup made beforehand."
        }
    }

    /// Run `change`, or ask first when it would destroy a shortcut the keyboard
    /// shipped with. Those nine `0x62` entries exist only on the hardware (and in
    /// any profile dump), and only Undo, only in this session, can put one back.
    private func guardingFactoryShortcut(_ hid: UInt8, _ what: String, _ change: @escaping () -> Void) {
        guard isFactoryShortcut(hid) else { return change() }
        pendingFactoryReplacement = FactoryReplacement(
            keyLabel: ApexProTKLGen3.name(forHID: hid), what: what, perform: change)
    }

    private func resetEditorState() {
        editorCategory = nil
        question = nil
        showingUsagePicker = false
        showRightModifiers = false
    }

    // MARK: - Layer

    private var layerPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Theme.Space.m) {
                SegmentedRail(
                    selection: Binding(get: { controller.bindingLayer },
                                       set: { controller.bindingLayer = $0 }),
                    items: [
                        .init(Mappings.Layer.normal, "On its own"),
                        .init(Mappings.Layer.meta, "Holding Fn"),
                        .init(Mappings.Layer.secondActuation, "Pressed deeper"),
                    ],
                    fillsWidth: false
                )
                Spacer(minLength: 0)
                undoControls
                Button("Reset all keys") { confirmResetAll = true }
                    .buttonStyle(.compactSecondary)
                    .disabled(!controller.isConnected)
            }

            Text(layerExplanation)
                .font(Typo.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Put every key back to normal?",
                            isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset every key", role: .destructive) { controller.resetAllBindings() }
            Button("Keep my bindings", role: .cancel) {}
        } message: {
            Text("Every remap on the main layer and the deeper layer goes away, on the keyboard "
                 + "itself. The Fn layer is left alone. This can be undone while Apex Control stays open.")
        }
    }

    @ViewBuilder
    private var undoControls: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "arrow.uturn.backward",
                       help: controller.undoBindingLabel.map { "Undo \($0)" } ?? "Nothing to undo") {
                controller.undoBindingChange()
            }
            .disabled(!controller.canUndoBindings)
            .opacity(controller.canUndoBindings ? 1 : 0.35)

            IconButton(systemName: "arrow.uturn.forward",
                       help: controller.redoBindingLabel.map { "Redo \($0)" } ?? "Nothing to redo") {
                controller.redoBindingChange()
            }
            .disabled(!controller.canRedoBindings)
            .opacity(controller.canRedoBindings ? 1 : 0.35)
        }
    }

    private var layerExplanation: String {
        switch layer {
        case .normal:
            return "What each key does when you press it."
        case .meta:
            return "What each key does while the Fn key is held. Choose which key is Fn on the right."
        case .secondActuation:
            return "What an adjustable key does when you push it past a second, deeper point — "
                + "so one key can do two things. Only the 68 adjustable keys can do this."
        }
    }

    // MARK: - Board

    private var board: some View {
        VStack(spacing: Theme.Space.s) {
            if let question { pickBanner(question) }

            KeyboardView(
                colorFor: keyColor,
                isEnabled: isEditable,
                badgeFor: { isBlank($0.hid) ? nil : binding(for: $0.hid).compactSummary },
                markFor: { controller.effectiveMetaToggleHID == $0.hid ? Theme.readout : nil },
                selected: controller.selectedKey,
                layout: controller.layout ?? .ansi,
                style: .data,
                oled: controller.oledBitmap,
                onKey: { key in if isEditable(key) { controller.selectedKey = key.hid } },
                describe: describeKey,
                dragBehaviour: dragBehaviour,
                pickRequest: pickRequest
            )
            .frame(maxWidth: .infinity)

            boardHint
        }
    }

    private var boardHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 10)).foregroundStyle(Theme.ink3)
            Text("Drag any key onto another to make it send that key. "
                 + "Hold ⌘ ⌥ ⇧ ⌃ as you let go to add them.")
                .font(Typo.caption).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .opacity(question == nil ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func pickBanner(_ question: BoardQuestion) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.readout)
            Text(prompt(for: question))
                .font(Typo.captionMedium).foregroundStyle(Theme.ink)
            Button("Cancel") { self.question = nil }
                .buttonStyle(.compactQuiet)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 7)
        .background(Theme.readout.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.readout.opacity(0.4), lineWidth: 1))
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func prompt(for question: BoardQuestion) -> String {
        switch question {
        case .remapSource(let hid):
            return "Click the key whose signal \(ApexProTKLGen3.name(forHID: hid)) should send."
        case .metaToggle:
            return "Click the key you want to use as Fn."
        }
    }

    private var pickRequest: KeyPickRequest? {
        guard let question else { return nil }
        switch question {
        case .remapSource(let hid):
            return KeyPickRequest(
                prompt: prompt(for: question),
                isEligible: { HIDUsage.isKeyboardUsage($0.hid) },
                onPick: { source in
                    apply(source: source.hid, to: hid, modifiers: [])
                    self.question = nil
                },
                onCancel: { self.question = nil })
        case .metaToggle:
            return KeyPickRequest(
                prompt: prompt(for: question),
                isEligible: { $0.isMappable },
                onPick: { key in
                    controller.setMetaToggleKey(key.hid)
                    self.question = nil
                },
                onCancel: { self.question = nil })
        }
    }

    /// Drag one key onto another: the target starts sending the source's signal.
    ///
    /// This is the whole feature in four closures. The source is any key that
    /// carries a real HID keyboard usage — including the modifiers, so dropping
    /// Shift onto Caps Lock does the thing everyone actually wants from a Caps
    /// Lock key.
    private var dragBehaviour: KeyDragBehaviour {
        KeyDragBehaviour(
            canDrag: { HIDUsage.isKeyboardUsage($0.hid) },
            canDrop: { _, target in isEditable(target) },
            describeDrop: { source, target, mods in
                let written = Mappings.Binding.keyboard(usages: mods + [source.hid]).keyboardUsages
                let result = "\(target.label) sends \(KeyComboFormatter.symbols(for: written))"
                // The Fn layer ships with shortcuts we know of no command to restore.
                // Say so before the drop, not after.
                return isFactoryShortcut(target.hid) ? result + "  ·  replaces a factory shortcut" : result
            },
            onDrop: { source, target, mods in
                apply(source: source.hid, to: target.hid, modifiers: mods)
            }
        )
    }

    private func apply(source: UInt8, to target: UInt8, modifiers: [UInt8]) {
        let wanted = Mappings.Binding.keyboard(usages: modifiers + [source])
        controller.selectedKey = target
        editorCategory = .keyboard
        guard binding(for: target) != wanted else {
            // Dropping a key on itself on the main layer asks for the state it
            // is already in. Say nothing rather than claim a change.
            return
        }
        controller.setBinding(wanted, forKey: target)
        controller.note("\(ApexProTKLGen3.name(forHID: target)) now sends "
                        + KeyComboFormatter.symbols(for: wanted.keyboardUsages))
    }

    /// True for a key still carrying one of the shortcuts the keyboard shipped
    /// with on its Fn layer — brightness, media, the screen.
    private func isFactoryShortcut(_ hid: UInt8) -> Bool {
        layer == .meta && binding(for: hid).knownFunction == .meta
    }

    private func describeKey(_ key: Key) -> String {
        guard key.isMappable else { return "\(key.label), cannot be rebound" }
        if controller.effectiveMetaToggleHID == key.hid { return "\(key.label), the Fn key" }
        return isBlank(key.hid)
            ? "\(key.label), unchanged"
            : "\(key.label), sends \(binding(for: key.hid).summary)"
    }

    private func isEditable(_ key: Key) -> Bool {
        guard key.isMappable else { return false }
        return layer != .secondActuation || key.isAnalog
    }

    private func keyColor(_ key: Key) -> LEDColor {
        if controller.effectiveMetaToggleHID == key.hid { return LEDColor(r: 20, g: 92, b: 104) }
        let b = binding(for: key.hid)
        if b.isDisabled { return LEDColor(r: 18, g: 19, b: 22) }
        if !isBlank(key.hid) { return LEDColor(r: 208, g: 66, b: 8) }
        return LEDColor(r: 34, g: 38, b: 45)
    }

    private func binding(for hid: UInt8) -> Mappings.Binding {
        controller.bindings.binding(for: hid, layer: layer)
    }

    private func isBlank(_ hid: UInt8) -> Bool { controller.bindings.isBlank(hid, layer: layer) }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        Card(title: "This key") {
            if let hid = controller.selectedKey,
               let key = ApexProTKLGen3.key(forHID: hid),
               isEditable(key) {
                inspectorBody(hid: hid, key: key)
            } else {
                EmptyState(
                    icon: "cursorarrow.click",
                    title: layer == .secondActuation ? "Pick an adjustable key" : "Pick a key",
                    message: layer == .secondActuation
                        ? "Only the 68 adjustable keys can tell a light press from a deep one. They are the lit ones above."
                        : "Click a key on the board above to change what it does — or just drag one key onto another."
                )
            }
        }
    }

    @ViewBuilder
    private func inspectorBody(hid: UInt8, key: Key) -> some View {
        let current = binding(for: hid)
        let category = editorCategory ?? (isBlank(hid) ? .standard : BindingCategory.of(current))

        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(key.label).font(Typo.title).foregroundStyle(Theme.ink)
            Readout(String(format: "0x%02X", hid), size: 10, color: Theme.ink3)
            Spacer(minLength: Theme.Space.s)
            Text(isBlank(hid) ? "Unchanged" : headline(current))
                .font(Typo.calloutMedium)
                .foregroundStyle(isBlank(hid) ? Theme.ink3 : Theme.signal)
                .lineLimit(1)
        }

        SegmentedRail(
            selection: Binding(get: { category },
                               set: { choose($0, hid: hid, current: current) }),
            items: BindingCategory.allCases.map { .init($0, $0.rawValue, icon: $0.icon) }
        )

        Rule()

        switch category {
        case .standard:
            Note("This key does what its keycap says.")
        case .disabled:
            Note("This key sends nothing at all.")
        case .keyboard:
            keyboardEditor(hid: hid, key: key)
        case .media:
            mediaEditor(hid: hid)
        case .mouse:
            mouseEditor(hid: hid)
        case .advanced:
            rawEditor(hid: hid, current: current)
        }

        if layer == .secondActuation { secondActuationDepth(hid: hid) }

        if layer == .meta, current.knownFunction == .meta {
            Banner(kind: .warning,
                   message: "This is one of the shortcuts the keyboard shipped with — brightness, media or the "
                       + "screen. Undo can bring it back only while Apex Control stays open.")
        }

        Rule()

        HStack(spacing: Theme.Space.s) {
            Button("Reset this key") {
                guardingFactoryShortcut(hid, "put back to its normal job") {
                    controller.resetBinding(forKey: hid)
                }
            }
                .buttonStyle(.compactSecondary)
                .disabled(isBlank(hid))
            if let label = controller.undoBindingLabel, controller.canUndoBindings {
                Button {
                    controller.undoBindingChange()
                } label: {
                    Label("Undo \(label)", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.compactQuiet)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// A Mac reads ⌘C; only the combinations that have no symbol fall back to
    /// the protocol-level description.
    private func headline(_ binding: Mappings.Binding) -> String {
        guard binding.knownFunction == .keyboard, !binding.keyboardUsages.isEmpty else {
            return binding.summary
        }
        return KeyComboFormatter.symbols(for: binding.keyboardUsages)
    }

    /// Switching category opens an editor. It writes to the keyboard only for
    /// the two categories that *are* the decision — "Default" and "Off" — so
    /// that looking at what Media offers no longer rebinds the key to
    /// play/pause on the way past.
    private func choose(_ category: BindingCategory, hid: UInt8, current: Mappings.Binding) {
        editorCategory = category
        showingUsagePicker = false
        switch category {
        case .standard:
            guardingFactoryShortcut(hid, "put back to its normal job") {
                controller.resetBinding(forKey: hid)
            }
            editorCategory = nil
        case .disabled:
            guardingFactoryShortcut(hid, "switched off") {
                controller.setBinding(.disabled, forKey: hid)
            }
        case .keyboard:
            break
        case .media, .mouse:
            break
        case .advanced:
            rawFunction = String(format: "0x%02X", current.function)
            rawCodes = current.keyCodes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    // MARK: - Keyboard editor

    /// The combination on a key, plus whether it is real or merely proposed.
    ///
    /// A key with no keyboard mapping yet — one on the Fn layer, or one bound
    /// to a mouse button — shows its own signal greyed out, so the editor
    /// suggests a sensible starting point without ever claiming a change that
    /// has not been made.
    private func combo(for hid: UInt8) -> (base: UInt8?, mods: [UInt8], isProposal: Bool) {
        let split = binding(for: hid).keyboardCombination
        guard split.base != nil || !split.modifiers.isEmpty else {
            return (HIDUsage.isKeyboardUsage(hid) ? hid : nil, [], true)
        }
        return (split.base, split.modifiers, false)
    }

    @ViewBuilder
    private func keyboardEditor(hid: UInt8, key: Key) -> some View {
        let split = combo(for: hid)
        let isFull = split.mods.count + 1 >= Mappings.Binding.maxKeyboardUsages
        // A right-hand modifier already on the key is shown whether or not the
        // disclosure was opened; hiding a modifier that is set would leave no
        // way to remove it.
        let showRight = showRightModifiers || split.mods.contains { $0 > HIDUsage.leftGUI }

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(split.isProposal ? "Would send" : "Sends")
                comboWell(split: split, hid: hid, key: key)
            }

            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Hold with it")
                HStack(spacing: 5) {
                    ForEach(leftModifiers, id: \.self) { mod in
                        modifierToggle(mod, split: split, hid: hid, isFull: isFull, bothSides: showRight)
                    }
                    Spacer(minLength: 0)
                }
                if showRight {
                    HStack(spacing: 5) {
                        ForEach(rightModifiers, id: \.self) { mod in
                            modifierToggle(mod, split: split, hid: hid, isFull: isFull, bothSides: showRight)
                        }
                        Spacer(minLength: 0)
                    }
                }
                DisclosureRow(title: showRight
                              ? "Right-hand modifiers"
                              : "Tell the right-hand modifiers apart",
                              detail: "Most software treats the two sides the same. Games sometimes do not.",
                              isExpanded: $showRightModifiers)
                if isFull {
                    Note("Four keys at once is the most this keyboard can send.",
                         icon: "exclamationmark.circle", color: Theme.warn)
                }
            }

            Note("The keyboard sends the whole combination itself, so it works on any computer — "
                 + "no software needed at the other end.")
        }
    }

    private var leftModifiers: [UInt8] {
        [HIDUsage.leftControl, HIDUsage.leftAlt, HIDUsage.leftShift, HIDUsage.leftGUI]
    }
    private var rightModifiers: [UInt8] {
        [HIDUsage.rightControl, HIDUsage.rightAlt, HIDUsage.rightShift, HIDUsage.rightGUI]
    }

    /// The current combination, plus the three ways to change it — all visible
    /// at once, because each suits a different moment: dragging is fastest when
    /// the key is on the board, pressing is fastest when your hands are already
    /// on the keyboard, and the list is the only way to reach F13 or a keypad
    /// usage this board does not physically have.
    @ViewBuilder
    private func comboWell(split: (base: UInt8?, mods: [UInt8], isProposal: Bool),
                           hid: UInt8, key: Key) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ComboDisplay(usages: split.mods + (split.base.map { [$0] } ?? []),
                             muted: split.isProposal)

                Spacer(minLength: Theme.Space.s)

                Button {
                    showingUsagePicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet").font(.system(size: 11))
                        Text("Choose…")
                    }
                }
                .buttonStyle(.compactSecondary)
                .help("Pick from every key the keyboard can send, including ones this board does not have")
                .popover(isPresented: $showingUsagePicker, arrowEdge: .bottom) {
                    UsagePickerPopover(
                        current: split.isProposal ? nil : split.base,
                        onPick: { usage in
                            showingUsagePicker = false
                            write(base: usage, mods: split.mods, hid: hid)
                        },
                        onClose: { showingUsagePicker = false })
                }

                KeyCaptureButton { usages in
                    let mods = usages.filter(HIDUsage.isModifier)
                    let base = usages.last(where: { !HIDUsage.isModifier($0) }) ?? usages.last
                    guard let base else { return }
                    write(base: base, mods: mods, hid: hid)
                }
            }

            Button {
                question = .remapSource(hid)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.point.up.left").font(.system(size: 11))
                    Text("Copy from a key on the board…")
                }
            }
            .buttonStyle(.compactQuiet)
            .help("Then click any key above. Same result as dragging that key onto \(key.label).")
        }
    }

    private func write(base: UInt8, mods: [UInt8], hid: UInt8) {
        controller.setBinding(.keyboard(usages: mods + [base]), forKey: hid)
    }

    private func modifierToggle(_ mod: UInt8,
                                split: (base: UInt8?, mods: [UInt8], isProposal: Bool),
                                hid: UInt8, isFull: Bool, bothSides: Bool) -> some View {
        let isOn = split.mods.contains(mod)
        return Button {
            var next = split.mods.filter { $0 != mod }
            if !isOn { next.append(mod) }
            guard let base = split.base else { return }
            write(base: base, mods: next, hid: hid)
        } label: {
            VStack(spacing: 0) {
                Text(KeyComboFormatter.symbol(mod)).font(.system(size: 14, weight: .medium))
                if bothSides {
                    Text(mod <= HIDUsage.leftGUI ? "left" : "right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .opacity(0.6)
                }
            }
            .frame(width: 38, height: 34)
            .background(isOn ? Theme.signal : Theme.surfaceHi,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isOn ? .clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(isOn ? Color(srgb: 0x140A04) : Theme.ink2)
        }
        .buttonStyle(.plain)
        .disabled(split.base == nil || (isFull && !isOn))
        .opacity(split.base == nil || (isFull && !isOn) ? 0.4 : 1)
        .help(HIDUsage.name(mod))
        .accessibilityLabel(HIDUsage.name(mod))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Media editor

    @ViewBuilder
    private func mediaEditor(hid: UInt8) -> some View {
        let current = binding(for: hid).consumerUsage
            .flatMap { usage in Mappings.ConsumerAction.allCases.first { $0.usage == usage } }

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if current == nil {
                Note("Pick a control. Nothing is written until you do.")
            }
            MediaActionGrid(current: current) { action in
                controller.setBinding(.consumer(action), forKey: hid)
            }
            Note("The first six are the controls this keyboard already drives on its own media "
                 + "buttons, so they are known to work.")
        }
    }

    // MARK: - Mouse editor

    @ViewBuilder
    private func mouseEditor(hid: UInt8) -> some View {
        let current = Mappings.MouseAction(function: binding(for: hid).function)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if current == nil {
                Note("Pick a mouse action. Nothing is written until you do.")
            }
            MouseActionGrid(current: current) { action in
                controller.setBinding(.mouse(action), forKey: hid)
            }
        }
    }

    // MARK: - Raw editor

    @ViewBuilder
    private func rawEditor(hid: UInt8, current: Mappings.Binding) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Note("Write the mapping bytes yourself. Use this to try functions the app does not model — "
                 + "macros (0x71) or host actions (0x72) — then read them back to see what stuck. "
                 + "Values are hexadecimal.",
                 icon: "exclamationmark.triangle.fill", color: Theme.warn)

            HStack(alignment: .bottom, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Function")
                    TextField("0x51", text: $rawFunction)
                        .textFieldStyle(.apexMono)
                        .frame(width: 76)
                        .accessibilityLabel("Function byte, hexadecimal")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Key codes · 4 bytes")
                    TextField("00 00 00 00", text: $rawCodes)
                        .textFieldStyle(.apexMono)
                        .frame(width: 152)
                        .accessibilityLabel("Four key code bytes, hexadecimal")
                }
                Button("Write") { writeRaw(hid: hid) }
                    .buttonStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }

    private func writeRaw(hid: UInt8) {
        guard let fn = parseByte(rawFunction) else {
            controller.lastError = "“\(rawFunction)” is not a byte value. Try 0x51, or 51."
            return
        }
        let fields = rawCodes.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        // A closure, not `compactMap(parseByte)`: Swift 6.0 treats that method reference as
        // throwing ("call can throw"), which later compilers do not.
        let codes = fields.compactMap { parseByte($0) }
        guard codes.count == fields.count else {
            controller.lastError = "The key codes must be up to four hexadecimal bytes, "
                + "like “E3 06 00 00”."
            return
        }
        guard codes.count <= Mappings.Binding.maxKeyboardUsages else {
            controller.lastError = "A mapping carries four key-code bytes; that is \(codes.count)."
            return
        }
        controller.setBinding(Mappings.Binding(function: fn, keyCodes: codes), forKey: hid,
                              describedAs: "\(ApexProTKLGen3.name(forHID: hid)) → raw bytes")
    }

    /// Hexadecimal, because that is how the protocol documents every one of
    /// these bytes and how the read-back view shows them.
    private func parseByte(_ s: String) -> UInt8? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t = String(t.dropFirst(2)) }
        guard !t.isEmpty, t.count <= 2, t.allSatisfy(\.isHexDigit) else { return nil }
        return UInt8(t, radix: 16)
    }

    // MARK: - Second actuation

    @ViewBuilder
    private func secondActuationDepth(hid: UInt8) -> some View {
        Rule()

        if !controller.actuation.secondActuationEnabled, !isBlank(hid) {
            Banner(kind: .warning,
                   message: "This key has a deeper-press binding, but the second point is switched "
                       + "off, so nothing will happen. Turn it on below.")
        }

        SwitchRow(
            title: "Use a second, deeper point",
            detail: "Below the first point the key does its normal job; past this one it does the binding above.",
            isOn: Binding(
                get: { controller.actuation.secondActuationEnabled },
                set: { on in
                    controller.actuation.secondActuationEnabled = on
                    controller.scheduleActuationApply()
                })
        )

        if controller.actuation.secondActuationEnabled {
            ScaleControl.integer(
                label: "Deeper point",
                value: Binding(
                    get: { controller.actuation.perKeySecondActuation[hid]
                        ?? controller.actuation.secondActuationLevel },
                    set: { controller.actuation.perKeySecondActuation[hid] = $0 }),
                range: 1...40,
                majorEvery: 5,
                readout: { (String(format: "%.1f", Actuation.millimetres(forLevel: $0)), "mm") },
                tickLabel: { String(format: "%.1f", Actuation.millimetres(forLevel: $0)) }
            )
            .onChange(of: controller.actuation.perKeySecondActuation) { _, _ in
                controller.scheduleActuationApply()
            }

            let primary = Actuation.millimetres(forLevel: controller.actuation.level(for: hid))
            Note(String(format: "It has to sit below this key's first point (%.1f mm). "
                        + "Anything shallower is pushed down to just past it.", primary))
        }
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if layer == .meta { metaKeyCard }
            readBackCard
            safetyCard
        }
    }

    private var metaKeyCard: some View {
        Card(title: "The Fn key") {
            Note("Hold this key to reach the layer you are editing.")

            HStack(spacing: Theme.Space.s) {
                if let hid = controller.effectiveMetaToggleHID {
                    KeycapChip(label: ApexProTKLGen3.name(forHID: hid), tint: Theme.readout)
                } else {
                    Text("None").font(Typo.calloutMedium).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
                Button("Choose…") { question = .metaToggle }
                    .buttonStyle(.compactSecondary)
                if controller.effectiveMetaToggleHID != nil {
                    IconButton(systemName: "xmark", help: "Use no Fn key") {
                        controller.setMetaToggleKey(nil)
                    }
                }
            }

            if controller.effectiveMetaToggleHID == nil {
                Note("With no Fn key nothing on this layer can fire.", icon: "exclamationmark.triangle.fill",
                     color: Theme.warn)
            } else {
                Note("Ringed in blue on the board above.", icon: "circle.dashed", color: Theme.readout)
            }
        }
    }

    private var readBackCard: some View {
        Card(title: "What the keyboard says") {
            switch controller.bindingReadBackSupported {
            case .some(true):
                let matches = controller.bindingsMatchDevice(layer: layer)
                HStack(spacing: 6) {
                    Image(systemName: matches == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(matches == true ? Theme.ok : Theme.warn)
                        .font(.system(size: 12))
                    Text(matches == true ? "The keyboard agrees with this layer." : "The keyboard has something else.")
                        .font(Typo.callout).foregroundStyle(Theme.ink)
                }
                Note("Read straight off the keyboard, so this shows what is really there — including anything "
                     + "other software or one of the onboard setups left behind.")
            case .some(false):
                Note("This keyboard did not answer when asked for its bindings. Writing still works; "
                     + "Apex Control just cannot confirm the result.", icon: "questionmark.circle")
            case nil:
                Note(controller.isConnected
                     ? "Not read yet."
                     : "Connect the keyboard to read its bindings.")
            }

            if controller.isReadingBindings {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(Typo.caption).foregroundStyle(Theme.ink3)
                }
            } else {
                Button("Read from keyboard") { controller.readBindingsFromDevice() }
                    .buttonStyle(.compactSecondary)
                    .disabled(!controller.isConnected)
            }
        }
    }

    private var safetyCard: some View {
        Card(title: "If it goes wrong") {
            Note("Bindings live in the keyboard, so a key you switch off stays off with Apex Control closed, "
                 + "and once it is saved into the keyboard it should stay off on any other computer. “Reset all "
                 + "keys”, here or in the menu bar, puts everything back.")

            Rule()

            Note("Reset leaves the Fn layer alone. It holds the shortcuts the keyboard shipped with. Once "
                 + "they are gone, the only way back we know of is a profile backup made beforehand.",
                 icon: "lock.fill", color: Theme.warn)

            Button("Clear the Fn layer too") { confirmClearFn = true }
                .buttonStyle(ApexButton(role: .destructive, compact: true))
                .disabled(!controller.isConnected)
                .confirmationDialog("Clear the Fn layer?",
                                    isPresented: $confirmClearFn, titleVisibility: .visible) {
                    Button("Clear it", role: .destructive) { controller.resetFnLayer() }
                    Button("Leave it alone", role: .cancel) {}
                } message: {
                    Text("The brightness, media and screen shortcuts the keyboard shipped with are erased "
                         + "from the hardware. Undo can put them back while Apex Control stays open; once "
                         + "it quits, the only way back we know of is a profile backup made beforehand.")
                }
        }
    }
}

// MARK: - Small parts

/// A combination drawn as keycaps, which is how it appears on the hardware and
/// on the board above — not as a sentence of plus signs.
struct ComboDisplay: View {
    let usages: [UInt8]
    var muted = false

    var body: some View {
        HStack(spacing: 4) {
            if usages.isEmpty {
                Text("Nothing").font(Typo.calloutMedium).foregroundStyle(Theme.ink3)
            } else {
                ForEach(Array(HIDUsage.canonical(usages).enumerated()), id: \.offset) { _, usage in
                    KeycapChip(label: KeyComboFormatter.symbol(usage),
                               tint: muted ? Theme.ink3 : Theme.ink)
                }
            }
        }
        .opacity(muted ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usages.isEmpty
                            ? "Sends nothing"
                            : "Sends " + usages.map { HIDUsage.name($0) }.joined(separator: " plus "))
    }
}

/// One key, drawn as a key.
struct KeycapChip: View {
    let label: String
    var tint: Color = Theme.ink

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Theme.surfaceHi, Theme.surfaceHi.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}
