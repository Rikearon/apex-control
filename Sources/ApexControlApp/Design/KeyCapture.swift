import SwiftUI
import AppKit
import ApexKit

// MARK: - Recorder

/// "Press the key you want" — the fastest way to name a key combination.
///
/// The state lives in a class rather than in `@State` on a view struct for a
/// reason that cost this feature its correctness once already: the monitor's
/// lifetime has to be tied to something with an identity, so that stopping is
/// guaranteed to remove the *same* monitor that starting installed, and so that
/// a SwiftUI rebuild can never orphan a live monitor that goes on swallowing
/// every keystroke in the app.
///
/// Only one recorder can be listening at a time — `active` enforces it — because
/// a local monitor is app-wide and two of them would both eat the same press.
@MainActor
final class ShortcutRecorder: ObservableObject {

    /// What the recorder produced: the whole combination, modifiers first.
    typealias Commit = ([UInt8]) -> Void

    @Published private(set) var isRecording = false
    /// Modifiers held right now, so the button can show the chord forming.
    @Published private(set) var held: [UInt8] = []
    /// A short complaint about the last press. Clears itself.
    @Published private(set) var message: String?

    /// The monitor token, in a box so that `deinit` — which is not isolated to
    /// the main actor — can still guarantee removal. A monitor that outlives its
    /// recorder swallows every keystroke in the app for the rest of the session.
    private final class MonitorBox: @unchecked Sendable {
        var token: Any?
        var observers: [NSObjectProtocol] = []
        func remove() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
        }
    }

    private let box = MonitorBox()
    private var onCommit: Commit?
    /// The largest set of modifiers held during the current chord. Releasing
    /// them all commits *this*, not the empty set the last event reports.
    private var peak: [UInt8] = []
    private var messageTask: Task<Void, Never>?

    private static weak var active: ShortcutRecorder?

    deinit { box.remove() }

    // MARK: Control

    func toggle(onCommit: @escaping Commit) {
        isRecording ? cancel() : start(onCommit: onCommit)
    }

    func start(onCommit: @escaping Commit) {
        guard !isRecording else { return }
        Self.active?.cancel()
        Self.active = self

        self.onCommit = onCommit
        peak = []
        held = []
        message = nil
        isRecording = true

        box.token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            var swallow = false
            MainActor.assumeIsolated { swallow = self.handle(event) }
            return swallow ? nil : event
        }

        // A recorder that keeps listening after you switch away is a keyboard
        // that has stopped working, from the user's point of view.
        observe(NSApplication.didResignActiveNotification)
        observe(NSWindow.didResignKeyNotification)
    }

    /// Stop listening and keep the binding as it was.
    func cancel() {
        guard isRecording || box.token != nil else { return }
        finish()
    }

    private func observe(_ name: Notification.Name) {
        box.observers.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    private func finish() {
        box.remove()
        onCommit = nil
        peak = []
        held = []
        isRecording = false
        if Self.active === self { Self.active = nil }
    }

    private func commit(_ usages: [UInt8]) {
        let canonical = HIDUsage.canonical(usages)
        guard canonical.count <= Mappings.Binding.maxKeyboardUsages else {
            complain("That is \(canonical.count) keys at once. This keyboard can send four.")
            return
        }
        guard !canonical.isEmpty else { return }
        let commit = onCommit
        finish()
        commit?(canonical)
    }

    private func complain(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Event handling

    /// Returns true to swallow the event, so a recorded press never also types
    /// into the app behind the recorder or fires a menu shortcut.
    ///
    /// Flag changes are passed through: they type nothing, and letting AppKit
    /// see them keeps its idea of which modifiers are down in step with reality.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
            return true
        case .flagsChanged:
            handleFlagsChanged(event)
            return false
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }

        let mods = ModifierFlagsReader.usages(in: event.modifierFlags)

        // Escape on its own backs out. Held with a modifier it is a combination
        // like any other, and the picker can always reach a bare Escape.
        if event.keyCode == 0x35, mods.isEmpty {
            finish()
            return
        }

        if MacKeyCode.nonKeyboardVirtualCodes.contains(event.keyCode) {
            complain("The fn key and the Mac's own volume keys are not keyboard signals. "
                     + "Use Media for those.")
            return
        }

        guard let usage = MacKeyCode.hid(for: event.keyCode) else {
            complain("This Mac calls that key \(event.keyCode) and there is no keyboard "
                     + "signal for it. Pick one from the list instead.")
            return
        }

        commit(mods + [usage])
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Caps Lock reports as a flag change rather than a key press, so it can
        // only be recorded here. Its own lock state on the Mac toggles as a side
        // effect — unavoidable, and harmless.
        if event.keyCode == 0x39 {
            commit(held + [0x39])
            return
        }

        let now = ModifierFlagsReader.usages(in: event.modifierFlags)
        held = now

        if now.isEmpty {
            // Every modifier let go without a key being pressed: the chord the
            // user meant is the one they were holding a moment ago.
            if !peak.isEmpty { commit(peak) }
        } else if now.count >= peak.count {
            peak = now
        }
    }
}

// MARK: - Modifier flags

/// Turns an `NSEvent`'s modifier flags into HID usages, keeping left and right
/// apart.
///
/// `NSEvent.ModifierFlags` publishes `.shift`, `.control`, `.option` and
/// `.command` without a side, but the raw value still carries the device bits
/// AppKit inherits from `IOLLEvent.h`. Reading them is what lets recording the
/// right-hand Shift produce `0xE5` instead of quietly binding the left one.
enum ModifierFlagsReader {
    private static let leftControl: UInt = 0x0000_0001
    private static let leftShift: UInt = 0x0000_0002
    private static let rightShift: UInt = 0x0000_0004
    private static let leftCommand: UInt = 0x0000_0008
    private static let rightCommand: UInt = 0x0000_0010
    private static let leftOption: UInt = 0x0000_0020
    private static let rightOption: UInt = 0x0000_0040
    private static let rightControl: UInt = 0x0000_2000

    static func usages(in flags: NSEvent.ModifierFlags) -> [UInt8] {
        let raw = flags.rawValue
        var out: [UInt8] = []

        func add(_ generic: NSEvent.ModifierFlags,
                 _ leftBit: UInt, _ rightBit: UInt,
                 _ leftUsage: UInt8, _ rightUsage: UInt8) {
            guard flags.contains(generic) else { return }
            let left = raw & leftBit != 0
            let right = raw & rightBit != 0
            // Neither device bit set happens for synthesised events; assume the
            // left-hand key, which is what every other Mac app shows.
            if right { out.append(rightUsage) }
            if left || !right { out.append(leftUsage) }
        }

        add(.control, leftControl, rightControl, HIDUsage.leftControl, HIDUsage.rightControl)
        add(.option, leftOption, rightOption, HIDUsage.leftAlt, HIDUsage.rightAlt)
        add(.shift, leftShift, rightShift, HIDUsage.leftShift, HIDUsage.rightShift)
        add(.command, leftCommand, rightCommand, HIDUsage.leftGUI, HIDUsage.rightGUI)

        return HIDUsage.canonical(out)
    }
}

// MARK: - Button

/// The recorder as a control: one button that becomes a live readout of the
/// chord being pressed, with a way out that is always visible.
struct KeyCaptureButton: View {
    /// Called with the whole combination, modifiers first.
    var onCapture: ([UInt8]) -> Void

    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                if recorder.isRecording {
                    RecordingPip()
                    Text(prompt)
                        .font(Typo.captionMedium)
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Button("Cancel") { recorder.cancel() }
                        .buttonStyle(.compactQuiet)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        recorder.start(onCommit: onCapture)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 11))
                            Text("Press a key")
                        }
                    }
                    .buttonStyle(.compactSecondary)
                    .help("Press the key or combination you want this key to send")
                }
            }
            .padding(.horizontal, recorder.isRecording ? 8 : 0)
            .padding(.vertical, recorder.isRecording ? 4 : 0)
            .background {
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.signal.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(Theme.signal.opacity(0.45), lineWidth: 1))
                }
            }

            if let message = recorder.message {
                Text(message)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onDisappear { recorder.cancel() }
        .animation(Theme.Motion.snap, value: recorder.isRecording)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recorder.isRecording
                            ? "Listening for a key press. Press escape to cancel."
                            : "Record a key combination")
    }

    private var prompt: String {
        guard !recorder.held.isEmpty else { return "Press a key…  ⎋ cancels" }
        return KeyComboFormatter.symbols(for: recorder.held) + " + a key,  or let go"
    }
}

/// The one piece of motion in the app that means "happening right now".
private struct RecordingPip: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.signal)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .onAppear { on = true }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                       value: on)
            .accessibilityHidden(true)
    }
}

// MARK: - Formatting

/// Renders a combination the way a Mac user reads one: ⌘⇧4.
enum KeyComboFormatter {
    /// `⌘⇧4`. A chord of nothing but modifiers spells its last member out —
    /// "⌘ Left Shift" rather than "⌘⇧", which reads as an unfinished shortcut.
    static func symbols(for usages: [UInt8]) -> String {
        let ordered = HIDUsage.canonical(usages)
        let modifiers = ordered.filter(HIDUsage.isModifier)
        let base = ordered.filter { !HIDUsage.isModifier($0) }
        if base.isEmpty, let last = modifiers.last {
            return modifiers.dropLast().map(symbol).joined() + HIDUsage.name(last)
        }
        return modifiers.map(symbol).joined() + base.map { HIDUsage.name($0) }.joined(separator: " ")
    }

    /// The same combination at keycap size, where "Left Ctrl" does not fit and
    /// "⌃" says the same thing.
    static func compactSymbols(for usages: [UInt8]) -> String {
        let ordered = HIDUsage.canonical(usages)
        let base = ordered.filter { !HIDUsage.isModifier($0) }
        return ordered.filter(HIDUsage.isModifier).map(symbol).joined()
            + base.map { HIDUsage.name($0) }.joined(separator: " ")
    }

    static func symbol(_ usage: UInt8) -> String {
        switch usage {
        case HIDUsage.leftControl, HIDUsage.rightControl: return "⌃"
        case HIDUsage.leftShift, HIDUsage.rightShift: return "⇧"
        case HIDUsage.leftAlt, HIDUsage.rightAlt: return "⌥"
        case HIDUsage.leftGUI, HIDUsage.rightGUI: return "⌘"
        default: return HIDUsage.name(usage)
        }
    }
}
