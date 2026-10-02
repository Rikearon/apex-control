import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon
import IOKit.hid
import ApexKit

/// What the reactive effect's key listener is actually doing.
///
/// This exists because "the permission is granted" and "we can see key presses"
/// are different questions, and the app used to answer the first one while the
/// user was asking the second. A tap that macOS refused looks exactly like a
/// keyboard nobody is typing on.
struct ReactiveInputStatus: Equatable, Sendable {

    enum Listener: Equatable, Sendable {
        /// Reactive is not the selected effect, so nothing is listening.
        case off
        /// The event tap is live and key presses are arriving.
        case listening
        /// macOS refused the tap and no permission is on record. The user has to
        /// grant one.
        case needsPermission
        /// A permission *is* on record but this process was still refused —
        /// almost always because the grant landed after launch. Input Monitoring
        /// in particular only applies to processes that start after it is given.
        case needsRelaunch
        /// The tap exists but macOS is starving it: modifier presses and this
        /// app's own keys arrive, every other app's key presses are withheld.
        /// This is what an unhonoured grant looks like from the inside — never
        /// given, keyed to a stale code signature after a rebuild, or granted
        /// after this process started. On the keyboard it presents as "shift
        /// ripples, letters only while the app is frontmost".
        case degraded
    }

    var listener: Listener = .off
    /// Trusted for Accessibility (`AXIsProcessTrusted`).
    var accessibility = false
    /// Granted Input Monitoring (`kTCCServiceListenEvent`).
    var inputMonitoring = false
    /// A password field somewhere has secure event input on, which stops the
    /// window server delivering key presses to *any* tap.
    var secureInput = false

    var isListening: Bool { listener == .listening }
    /// Whether macOS has any grant on record, whether or not it is being honoured.
    var hasAnyGrant: Bool { accessibility || inputMonitoring }
}

/// Listens for global key presses and reports the pressed key's USB HID usage
/// code, to drive the reactive lighting effect.
///
/// Four things about this are not obvious and all four have bitten:
///
/// * **Two different permissions.** macOS 10.15 split keyboard event taps out of
///   Accessibility into Input Monitoring (`kTCCServiceListenEvent`). Either
///   grant lets a listen-only keyboard tap be created, they live in different
///   panes of System Settings, and only one of them has an API that can put a
///   prompt on screen. Both are checked; both are offered.
/// * **A tap can be switched off after it is created.** The window server
///   disables taps it thinks are misbehaving and simply posts an event saying
///   so. A tap that is never re-enabled goes silently deaf for the rest of the
///   session, which is indistinguishable from a keyboard nobody is using.
/// * **Modifiers are not `keyDown`.** Shift, control, option and command only
///   ever arrive as `flagsChanged`, so a mask without it leaves a fifth of the
///   board dark under the finger.
/// * **A created tap is not a hearing tap.** Without an honoured grant the
///   window server still hands the tap over — and then withholds every other
///   app's `keyDown`, so only modifiers and this app's own keys arrive.
///   Reporting the tap's existence as "listening" turns that into "letters
///   don't ripple", which looks like a lighting bug. `TapHealth` (ApexKit)
///   convicts the starved state from evidence; the status it produces is
///   `.degraded`.
final class KeyMonitor: @unchecked Sendable {

    /// Called on the listener thread for every key press, with its HID usage.
    private let onPress: @Sendable (UInt8) -> Void
    /// Called whenever the listener's state changes. Never called with the same
    /// status twice in a row.
    private let onStatus: @Sendable (ReactiveInputStatus) -> Void

    /// How often the listener wakes to check on itself. Also the longest a
    /// `stop()` can take to be noticed.
    private static let watchdogInterval: TimeInterval = 0.25
    /// Secure input is polled less often than the tap: it is a round trip to the
    /// window server and it changes at human speed.
    private static let secureInputEveryNTicks = 4

    private let lock = NSLock()
    private var thread: Thread?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var live = false
    private var lastPublished: ReactiveInputStatus?
    /// Judges whether the live tap is actually being fed (see `TapHealth`).
    /// Exists exactly as long as the tap does; guarded by `lock`.
    private var health: TapHealth?
    private let pid = Int64(ProcessInfo.processInfo.processIdentifier)

    init(onPress: @escaping @Sendable (UInt8) -> Void,
         onStatus: @escaping @Sendable (ReactiveInputStatus) -> Void) {
        self.onPress = onPress
        self.onStatus = onStatus
    }

    deinit { stop() }

    // MARK: - Permissions

    enum Access: Equatable, Sendable { case granted, denied, undetermined }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undetermined
        }
    }

    /// Whether macOS has recorded a grant that should let us tap the keyboard.
    /// Not a promise: the only way to know is to create the tap and see.
    static var isTrusted: Bool { isAccessibilityTrusted || inputMonitoring == .granted }

    /// The window server's own answer to "may this process listen to keyboard
    /// events?" (`CGPreflightListenEventAccess`), with Accessibility as the
    /// historical alternative grant. Preferred over `isTrusted` for judging a
    /// *live* tap because it asks the process that does the withholding —
    /// though still not a promise: a stale grant can pass every record check,
    /// which is why `TapHealth` also weighs the evidence.
    static var expectedToHear: Bool {
        CGPreflightListenEventAccess() || isAccessibilityTrusted
    }

    /// True while a password field has secure event input enabled. No tap in any
    /// app receives key presses in that state — including ours.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Ask for the permissions reactive lighting needs.
    ///
    /// Input Monitoring first: `IOHIDRequestAccess` is the only one of the two
    /// that reliably raises the system prompt, and either grant is sufficient.
    /// macOS shows each prompt once per app, ever — after that these calls are
    /// silent no-ops and the settings panes below are the only route.
    static func requestPermission() {
        // Documented to block while the prompt is up, so keep it off the main
        // thread; nothing depends on its answer.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        // Key value of kAXTrustedCheckOptionPrompt; used directly to avoid a
        // concurrency-unsafe global reference under Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    /// Start listening. Safe to call on a listener that is already running.
    func start() {
        lock.lock()
        guard !live else { lock.unlock(); return }
        live = true
        stopping = false
        // Captured strongly on purpose: the tap holds a pointer to this object,
        // so it must outlive the thread rather than the other way round.
        let t = Thread { self.run() }
        t.name = "io.github.rikearon.apex-control.keymonitor"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        thread = t
        lock.unlock()
        t.start()
    }

    /// Ask the listener to shut down. Returns immediately; the thread tears the
    /// tap down on its own and reports `.off` when it has.
    func stop() {
        lock.lock()
        guard live else { lock.unlock(); return }
        stopping = true
        let rl = runLoop
        lock.unlock()
        if let rl { CFRunLoopWakeUp(rl) }
    }

    /// Re-read the permission state and publish it, without disturbing a
    /// listener that is already working.
    func refreshStatus() {
        lock.lock()
        let hasTap = live && tap != nil
        lock.unlock()
        publish(hasTap ? evaluateHealth(expectedToHear: Self.expectedToHear) : .off)
    }

    // MARK: - Listener thread

    private func run() {
        // The tap's callback receives this pointer, so the retain has to outlive
        // every event it might still deliver — i.e. the whole of this function.
        let context = Unmanaged.passRetained(self).toOpaque()
        defer { Unmanaged<KeyMonitor>.fromOpaque(context).release() }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyMonitorTapCallback,
            userInfo: context
        ) else {
            // Refused. Distinguish "never granted" from "granted, but not to
            // this process" — they need completely different instructions.
            finish(reporting: Self.isTrusted ? .needsRelaunch : .needsPermission)
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl: CFRunLoop = CFRunLoopGetCurrent()

        lock.lock()
        if stopping {
            lock.unlock()
            CFMachPortInvalidate(tap)
            finish(reporting: .off)
            return
        }
        self.tap = tap
        self.source = src
        self.runLoop = rl
        self.health = TapHealth(startedAt: ProcessInfo.processInfo.systemUptime)
        lock.unlock()

        CFRunLoopAddSource(rl, src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Creating the tap proves nothing about being fed by it, so even the
        // first report asks the health arbiter instead of assuming
        // `.listening` — without an honoured grant this correctly comes back
        // `.degraded` before a single key has been pressed.
        publish(evaluateHealth(expectedToHear: Self.expectedToHear))

        // Poll instead of parking in `CFRunLoopRun`, so stopping never means
        // reaching into another thread's run loop, and so the tap gets a regular
        // health check. A disabled tap is put back: the window server switches
        // taps off on its own, and the event that says so can be missed if it
        // arrives while the source is being torn down or re-added.
        var tick = 0
        var expected = Self.expectedToHear
        while !shouldStop {
            CFRunLoopRunInMode(.defaultMode, Self.watchdogInterval, false)
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            tick &+= 1
            // Deafness is checked every tick — it is one cheap window-server
            // read — but the permission record (TCC round-trips) refreshes on
            // the slower cadence, and a full status goes out either on that
            // cadence or the moment the verdict changes.
            let slowTick = tick % Self.secureInputEveryNTicks == 0
            if slowTick { expected = Self.expectedToHear }
            let state = evaluateHealth(expectedToHear: expected)
            if slowTick || state != lastPublishedListener() { publish(state) }
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, src, .commonModes)
        CFRunLoopSourceInvalidate(src)
        CFMachPortInvalidate(tap)

        lock.lock()
        self.tap = nil
        self.source = nil
        self.runLoop = nil
        self.health = nil
        lock.unlock()
        finish(reporting: .off)
    }

    /// Ask the health arbiter what the live tap's state really is.
    /// `.listening` only when nothing contradicts full delivery.
    private func evaluateHealth(expectedToHear: Bool) -> ReactiveInputStatus.Listener {
        let secure = Self.isSecureInputActive
        let sinceKeyDown = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .keyDown)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard tap != nil,
              let verdict = health?.evaluate(expectedToHear: expectedToHear,
                                             secureInput: secure,
                                             systemSecondsSinceKeyDown: sinceKeyDown,
                                             at: now)
        else { return .off }
        return verdict == .filtered ? .degraded : .listening
    }

    private func lastPublishedListener() -> ReactiveInputStatus.Listener? {
        lock.lock(); defer { lock.unlock() }
        return lastPublished?.listener
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    private func finish(reporting state: ReactiveInputStatus.Listener) {
        lock.lock()
        live = false
        stopping = false
        thread = nil
        lock.unlock()
        publish(state)
    }

    // MARK: - Events

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // These arrive whatever the event mask says. Left alone, the
            // listener is deaf from here on with nothing to show for it.
            lock.lock(); let t = tap; lock.unlock()
            if let t { CGEvent.tapEnable(tap: t, enable: true) }

        case .keyDown:
            // Feed the health arbiter before anything else. Whether the press
            // was aimed at another process is the one airtight proof that
            // macOS is delivering — our own keys arrive even to a starved tap
            // — and an unpopulated target (0) must never count as foreign.
            let target = event.getIntegerValueField(.eventTargetUnixProcessID)
            lock.lock()
            health?.heardKeyDown(foreign: target > 0 && target != pid,
                                 at: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let hid = MacKeyCode.hid(for: code) { onPress(hid) }

        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let hid = MacKeyCode.pressedUsage(forFlagsChanged: code, flags: event.flags.rawValue) {
                onPress(hid)
            }

        default:
            break
        }
    }

    // MARK: - Status

    private func publish(_ state: ReactiveInputStatus.Listener) {
        let status = ReactiveInputStatus(
            listener: state,
            accessibility: Self.isAccessibilityTrusted,
            inputMonitoring: Self.inputMonitoring == .granted,
            secureInput: (state == .listening || state == .degraded)
                ? Self.isSecureInputActive : false
        )
        lock.lock()
        guard lastPublished != status else { lock.unlock(); return }
        lastPublished = status
        lock.unlock()
        onStatus(status)
    }
}

/// Top-level so it can be used as a C function pointer.
private func keyMonitorTapCallback(proxy: CGEventTapProxy,
                                   type: CGEventType,
                                   event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    // Listen-only: the event is passed straight through, always. Returning nil
    // from a listen-only tap is harmless but returning the event is what the
    // contract describes, and it keeps this honest if the tap is ever made
    // active.
    return Unmanaged.passUnretained(event)
}

/// Quit and start again.
///
/// Not folklore: a process that was running when Input Monitoring was granted
/// stays refused until it is relaunched, so this is the last step of that flow.
@MainActor
enum AppRelaunch {
    static func now() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The delay lets this process exit first, so the new one is not turned
        // away by the single-instance check in AppDelegate.
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
