import Foundation
import AppKit
import ApexKit

/// Prints the truth about reactive lighting's key listener, from inside the app
/// bundle, and exits.
///
/// The permission this needs is granted to a *bundle*, so a command-line probe
/// answers a different question than the one being asked: it reports the
/// terminal's permissions, not Apex Control's. This harness has to run as the
/// app for its answer to mean anything.
///
///     APEX_INPUT_DIAGNOSTIC=1 "build/Apex Control.app/Contents/MacOS/Apex Control"
///
/// Exits non-zero when the listener could not be started, so it doubles as a
/// check that can be scripted.
enum InputDiagnostic {

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["APEX_INPUT_DIAGNOSTIC"] != nil }

    /// How long to sit and report key presses. Long enough to type on.
    private static var duration: TimeInterval {
        ProcessInfo.processInfo.environment["APEX_INPUT_DIAGNOSTIC_SECONDS"]
            .flatMap(Double.init) ?? 6
    }

    @MainActor
    static func runIfEnabled() {
        guard isEnabled else { return }

        print("Apex Control — reactive input diagnostic")
        print("  bundle:              \(Bundle.main.bundleURL.path)")
        print("  bundle id:           \(Bundle.main.bundleIdentifier ?? "—")")
        print("  Accessibility:       \(KeyMonitor.isAccessibilityTrusted ? "granted" : "not granted")")
        print("  Input Monitoring:    \(describe(KeyMonitor.inputMonitoring))")
        print("  secure input active: \(KeyMonitor.isSecureInputActive)")

        let seen = Counter()
        let lastStatus = StatusBox()
        let monitor = KeyMonitor(
            onPress: { hid in
                seen.record(hid: hid)
                print(String(format: "  key press  0x%02X  %@", hid, ApexProTKLGen3.name(forHID: hid)))
            },
            onStatus: { status in
                lastStatus.set(status)
                print("  listener:            \(describe(status.listener))")
            })
        monitor.start()

        print("  …listening for \(Int(duration))s — type anything, including modifiers.")
        // A plain sleep would do, but running the loop lets the status callbacks
        // land on the main queue the way they do in the real app.
        RunLoop.current.run(until: Date().addingTimeInterval(duration))

        let (count, modifiers) = seen.value
        let status = lastStatus.value
        monitor.stop()
        print("  presses seen:        \(count)  (\(modifiers) modifier, \(count - modifiers) other)")

        // The degraded verdict outranks a non-zero count: a starved tap still
        // hears modifiers and this process's own keys, which is exactly the
        // trap this diagnostic exists to name.
        if status?.listener == .degraded {
            print("RESULT: filtered — the tap exists but macOS is withholding other apps' key presses; "
                  + "only modifiers (and this app's own keys) get through. The grant is missing, stale "
                  + "or was given after launch: remove Apex Control from System Settings → Privacy & "
                  + "Security → Input Monitoring, add this copy again, then relaunch. Rebuilds stop "
                  + "invalidating the grant once Scripts/make-signing-identity.sh has been run.")
            exit(4)
        }
        if count > 0 {
            if count == modifiers {
                print("RESULT: only modifier presses arrived. If letters were typed too, the tap is "
                      + "being filtered (stale or missing grant); if only modifiers were pressed, "
                      + "treat this as working.")
                exit(5)
            }
            print("RESULT: working.")
            exit(0)
        }
        if KeyMonitor.isSecureInputActive {
            print("RESULT: blocked by secure input — a password field is focused somewhere.")
            exit(2)
        }
        if KeyMonitor.isTrusted {
            print("RESULT: a permission is on record but no key presses arrived. If nothing was typed "
                  + "that is expected; otherwise the grant is stale — remove Apex Control from the "
                  + "System Settings list and add it again.")
            exit(3)
        }
        print("RESULT: no permission. Grant Input Monitoring or Accessibility to this bundle.")
        exit(1)
    }

    private static func describe(_ access: KeyMonitor.Access) -> String {
        switch access {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not asked yet"
        }
    }

    private static func describe(_ listener: ReactiveInputStatus.Listener) -> String {
        switch listener {
        case .off: return "stopped"
        case .listening: return "listening"
        case .needsPermission: return "refused — no permission"
        case .needsRelaunch: return "refused — granted after this process started"
        case .degraded: return "starved — macOS is withholding other apps' key presses (modifiers only)"
        }
    }

    /// Presses arrive on the listener thread; the counts are read on the main
    /// one. Modifiers are tallied separately because a starved tap still hears
    /// them — a modifiers-only tally is a diagnosis, not a success.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var modifiers = 0
        func record(hid: UInt8) {
            lock.lock()
            count += 1
            if (0xE0...0xE7).contains(hid) { modifiers += 1 }
            lock.unlock()
        }
        var value: (count: Int, modifiers: Int) {
            lock.lock(); defer { lock.unlock() }
            return (count, modifiers)
        }
    }

    /// The most recent status the listener reported, whichever thread said it.
    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: ReactiveInputStatus?
        func set(_ s: ReactiveInputStatus) { lock.lock(); status = s; lock.unlock() }
        var value: ReactiveInputStatus? { lock.lock(); defer { lock.unlock() }; return status }
    }
}
