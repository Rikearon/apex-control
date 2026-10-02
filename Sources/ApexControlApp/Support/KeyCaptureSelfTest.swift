import AppKit
import ApexKit

/// Development-only harness that drives the real `ShortcutRecorder` with
/// synthesised events and checks what it produces.
///
/// This exists because the recorder it replaced failed in a way no unit test
/// would have caught and no reading of the code made obvious: it listened for
/// `.keyDown` alone, so pressing a modifier on its own produced nothing at all
/// and the button sat there saying "Press any key…" forever. The only way to
/// know a key recorder works is to send it keys, so that is what this does —
/// through `NSApp.postEvent`, which walks the same `sendEvent` path a real
/// press does and therefore exercises the same monitor.
///
/// Inert unless `APEX_KEYCAPTURE_SELFTEST` is set:
///
/// ```
/// APEX_KEYCAPTURE_SELFTEST=1 .build/debug/ApexControlApp
/// ```
///
/// The app exits with a non-zero status if any case fails.
@MainActor
enum KeyCaptureSelfTest {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["APEX_KEYCAPTURE_SELFTEST"] != nil
    }

    private struct Case {
        let name: String
        /// Events to post, in order.
        let events: [Event]
        /// The combination the recorder should commit, or nil for "nothing, and
        /// it should have stopped listening".
        let expected: [UInt8]?
        /// Whether the recorder should still be listening afterwards.
        var stillRecording = false
    }

    private enum Event {
        case key(UInt16, NSEvent.ModifierFlags)
        case flags(UInt16, NSEvent.ModifierFlags)
    }

    private static let cases: [Case] = [
        Case(name: "a plain letter",
             events: [.key(0x0D, [])],                                  // W
             expected: [0x1A]),

        Case(name: "a letter with Command — a menu key equivalent",
             events: [.key(0x08, .command)],                            // ⌘C
             expected: [HIDUsage.leftGUI, 0x06]),

        Case(name: "a modifier on its own, committed on release",
             events: [.flags(0x37, .command), .flags(0x37, [])],
             expected: [HIDUsage.leftGUI]),

        Case(name: "two modifiers on their own",
             events: [.flags(0x3B, .control),
                      .flags(0x38, [.control, .shift]),
                      .flags(0x38, [])],
             expected: [HIDUsage.leftControl, HIDUsage.leftShift]),

        Case(name: "modifiers then a key, committed on the key",
             events: [.flags(0x38, .shift), .key(0x12, .shift)],        // ⇧1
             expected: [HIDUsage.leftShift, 0x1E]),

        Case(name: "the right-hand Shift keeps its side",
             events: [.flags(0x3C, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)),
                      .flags(0x3C, [])],
             expected: [HIDUsage.rightShift]),

        Case(name: "a keypad key the old table had no entry for",
             events: [.key(0x53, [])],                                  // keypad 1
             expected: [0x59]),

        Case(name: "F13, likewise",
             events: [.key(0x69, [])],
             expected: [0x68]),

        Case(name: "Caps Lock, which only ever reports as a flag change",
             events: [.flags(0x39, .capsLock)],
             expected: [0x39]),

        Case(name: "Escape cancels and records nothing",
             events: [.key(0x35, [])],
             expected: nil),

        Case(name: "Command-Escape is a combination, not a cancel",
             events: [.key(0x35, .command)],
             expected: [HIDUsage.leftGUI, 0x29]),

        Case(name: "the fn key says why it cannot be used and keeps listening",
             events: [.key(0x3F, [])],
             expected: nil,
             stillRecording: true),
    ]

    static func runIfEnabled() {
        guard isEnabled else { return }

        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(900))

            var failures = 0
            for test in cases {
                if await !run(test) { failures += 1 }
            }

            report(failures == 0
                   ? "key capture: all \(cases.count) cases passed"
                   : "key capture: \(failures) of \(cases.count) cases FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func run(_ test: Case) async -> Bool {
        let recorder = ShortcutRecorder()
        var captured: [UInt8]?
        recorder.start { captured = $0 }

        for event in test.events {
            post(event)
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(120))

        let stillRecording = recorder.isRecording
        recorder.cancel()

        let expectedUsages = test.expected.map(HIDUsage.canonical)
        guard captured == expectedUsages, stillRecording == test.stillRecording else {
            report("""
                   FAIL  \(test.name)
                         recorded \(describe(captured)), expected \(describe(expectedUsages))
                         still listening: \(stillRecording), expected \(test.stillRecording)
                   """)
            return false
        }
        report("ok    \(test.name) → \(describe(captured))")
        return true
    }

    private static func describe(_ usages: [UInt8]?) -> String {
        guard let usages else { return "nothing" }
        return usages.map { HIDUsage.name($0) }.joined(separator: " + ")
    }

    private static func post(_ event: Event) {
        let window = NSApp.windows.first { $0.canBecomeMain }
        let number = window?.windowNumber ?? 0
        let stamp = ProcessInfo.processInfo.systemUptime

        let made: NSEvent?
        switch event {
        case .key(let code, let flags):
            made = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                    timestamp: stamp, windowNumber: number, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ",
                                    isARepeat: false, keyCode: code)
        case .flags(let code, let flags):
            made = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                    timestamp: stamp, windowNumber: number, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code)
        }
        guard let made else { return report("could not synthesise an event") }
        NSApp.postEvent(made, atStart: false)
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
