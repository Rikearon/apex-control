import Foundation
import SwiftUI
import Combine
import ApexKit

/// The single source of truth for the UI. Owns the device, the lighting engine,
/// and all live settings; applies changes to hardware as they happen.
///
/// Every USB write happens on `deviceQueue`, never on the main actor, so a slow
/// or wedged control transfer can never freeze the UI. Failures surface in
/// `lastError` rather than being swallowed.
@MainActor
final class DeviceController: ObservableObject {

    // MARK: - Device state

    @Published private(set) var isConnected = false
    @Published private(set) var firmware = "—"
    @Published private(set) var regionName = "—"
    @Published private(set) var layout: KeyboardLayout?
    @Published private(set) var statusMessage = "Searching for keyboard…"
    @Published var lastError: String?
    /// A short confirmation for discrete actions the user asked for — saving to
    /// flash, resetting bindings, applying a profile. Never used for the
    /// continuous writes that happen while dragging a control.
    @Published private(set) var actionNote: String?

    // MARK: - Live settings

    @Published var lighting = LightingConfig() { didSet { scheduleLighting() } }
    @Published var actuation = ActuationConfig()
    @Published var rapidTap = RapidTapConfig()
    @Published var bindings = BindingsConfig()
    @Published var oled = OLEDConfig()

    /// Currently selected key in the editor (per-key lighting / actuation /
    /// bindings all share it).
    @Published var selectedKey: UInt8?
    /// Which mapping layer the Bindings pane is editing.
    @Published var bindingLayer: Mappings.Layer = .normal

    /// True while the keyboard is drawing its own lighting because we asked it
    /// to. Cleared by any lighting edit.
    @Published private(set) var isHandedBack = false

    /// What the reactive effect's key listener is really doing. The UI reports
    /// this rather than the permission checkbox, because macOS granting a
    /// permission and macOS honouring it for this process are different facts.
    @Published private(set) var reactiveInput = ReactiveInputStatus()

    /// Bindings last read back off the keyboard, per layer (PRD-17). Nil until
    /// a read succeeds.
    @Published private(set) var deviceBindings: [Mappings.Layer: [UInt8: Mappings.Binding]] = [:]
    @Published private(set) var isReadingBindings = false
    @Published private(set) var bindingReadBackSupported: Bool?

    /// Whether the keyboard-stored settings have actually reached the
    /// keyboard's **flash**. Live writes (`0x36`, `0x38 61`, …) only change
    /// RAM — proven on hardware: after a `0x36` write the flash image is
    /// byte-for-byte unchanged — so a power cycle reverts to whatever the
    /// onboard profile holds. This is the honest answer to "will it survive
    /// unplugging?", and the UI must never claim more than it says.
    enum PersistState: Equatable {
        /// No flash image read yet (still connecting, or disconnected).
        case unknown
        /// The keyboard's profile uses a schema this build cannot patch;
        /// persistence is off rather than risking the flash contents.
        case unsupported(String)
        /// Flash holds exactly what the live settings would persist.
        case saved
        /// There are live changes not yet in flash; a save is scheduled.
        case pending
        case saving
        case failed(String)
    }
    @Published private(set) var persistState: PersistState = .unknown

    /// The Fn-trigger key the keyboard's flash profile declares (factory:
    /// `0xF0`, the SteelSeries key). Read at connect; the editor falls back to
    /// it while the user has not chosen their own.
    @Published private(set) var deviceMetaToggleHID: UInt8?

    /// Undo history for key bindings (PRD-01).
    ///
    /// Bindings are written into the keyboard and outlive the app, so a mistake
    /// here follows the user to every computer they plug the board into. That
    /// makes an undo stack a correctness feature rather than a convenience.
    @Published private(set) var undoDepth = 0
    @Published private(set) var redoDepth = 0
    /// What the last undoable change was, so the UI can name it.
    @Published private(set) var lastBindingChange: String?

    // MARK: - Internals

    let device = ApexDevice()
    private lazy var engine = LightingEngine(device: device)
    private var keyMonitor: KeyMonitor?
    private var lightingDebounce: AnyCancellable?
    private let lightingSubject = PassthroughSubject<Void, Never>()
    private var bindingsDebounce: AnyCancellable?
    private let bindingsSubject = PassthroughSubject<Void, Never>()
    private var actuationDebounce: AnyCancellable?
    private let actuationSubject = PassthroughSubject<Void, Never>()
    private var persistDebounce: AnyCancellable?
    private let persistSubject = PassthroughSubject<Void, Never>()
    /// The slot-0 flash image as last read from or verified onto the keyboard —
    /// the state the keyboard will boot into, and the base every persist
    /// patches. Nil until the first successful read; never invented.
    private var flashImage: OnboardProfile.Image?
    /// Binding states to go back to, newest last. Bounded — a long editing
    /// session should not accumulate megabytes of configuration snapshots.
    /// Layers an apply had to leave alone because the keyboard had not been
    /// read yet. Retried the moment a read succeeds, so a profile applied at
    /// launch is not quietly half-applied for the rest of the session.
    private var deferredLayers: Set<Mappings.Layer> = []
    /// Bumped every time the key listener is replaced, so a listener that has
    /// already been retired cannot report state for its successor.
    private var monitorGeneration = 0
    private var undoStack: [BindingHistoryEntry] = []
    private var redoStack: [BindingHistoryEntry] = []
    private static let undoLimit = 64
    private let deviceQueue = DispatchQueue(label: "io.github.rikearon.apex-control.device", qos: .userInitiated)
    private var oledTimer: DispatchSourceTimer?
    private var isPaused = false
    private var noteTask: Task<Void, Never>?
    /// What to go back to when lighting is switched on again.
    private var restoreEffect: EffectKind = .rainbowWave
    private var restoreColor: LEDColor = .steelOrange

    init() {
        device.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.handleConnectionChange(connected) }
        }
        // Lighting is streamed at 30 fps from a background thread; without this
        // a stream that has started failing looks exactly like one that works.
        engine.onStreamHealthChange = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = "Lighting stopped reaching the keyboard: \(error.localizedDescription)"
                } else if self.lastError?.hasPrefix("Lighting stopped reaching") == true {
                    self.lastError = nil
                }
            }
        }
        // Coalesce rapid slider changes before re-applying static frames.
        lightingDebounce = lightingSubject
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                guard let self else { return }
                self.engine.apply(self.lighting)
            }

        // A binding write is a complete frame for all three layers — about two
        // kilobytes over the control endpoint. Toggling four modifiers or
        // sweeping a slider must not send four of them. `latest: true` still
        // sends the first change immediately, so the keyboard responds at once
        // and only the storm behind it is coalesced.
        bindingsDebounce = bindingsSubject
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.applyBindings() }

        actuationDebounce = actuationSubject
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.applyActuation() }

        // Persisting rewrites the keyboard's flash — erase plus twenty-five
        // chunks, seconds of bus time — so it waits for a quiet moment after
        // the last edit rather than chasing every slider tick. A debounce, not
        // a throttle: nothing should hit flash *during* a drag.
        persistDebounce = persistSubject
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] in self?.persistToKeyboard() }
    }

    func start() {
        do {
            try device.connect()
            if device.isConnected { handleConnectionChange(true) }
        } catch {
            statusMessage = "Connection error: \(error.localizedDescription)"
        }
    }

    private func handleConnectionChange(_ connected: Bool) {
        isConnected = connected
        if connected {
            statusMessage = "Connected"
            refreshInfo()
            applyAll(includingBindings: false)
            // Read the boot (flash) profile first: it is the reliable source —
            // the RAM read below is intermittent on this firmware — and it
            // seeds the Fn-trigger key plus a merge base for every layer, so a
            // failed RAM read no longer locks the Fn layer out of editing.
            readOnboardFlash()
            // Read before writing any layer. With no bindings of our own we
            // adopt whatever is already on the keyboard (possibly written by other
            // software or an onboard profile); with bindings of our own we still need
            // the read first, so the write can merge instead of blanking the
            // Fn layer's factory shortcuts.
            readBindingsFromDevice(seedEditor: bindings.isEmpty, quiet: true, thenApply: true)
        } else {
            statusMessage = "Keyboard disconnected — reconnect and it will resume"
            firmware = "—"; regionName = "—"; layout = nil
            deviceBindings = [:]
            flashImage = nil
            deviceMetaToggleHID = nil
            persistState = .unknown
            stopOLEDLoop()
        }
    }

    private func refreshInfo() {
        perform("Read device info") { [weak self] dev in
            let fw = (try? dev.firmwareVersion()) ?? "unknown"
            let region = try? dev.region()
            let lay = try? dev.layout()
            Task { @MainActor in
                self?.firmware = fw
                self?.regionName = region?.name ?? "unknown"
                self?.layout = lay ?? nil
            }
        }
    }

    // MARK: - Apply everything

    /// Push the full live state to the keyboard in a defined, idempotent order.
    /// Safe to repeat; used on connect, on wake, and when applying a profile.
    /// - Parameter includingBindings: pass `false` on connect, where the
    ///   binding write is deferred until the read-back has told us what is
    ///   already on each layer.
    func applyAll(includingBindings: Bool = true) {
        guard isConnected else { return }
        perform("Enable direct mode") { try $0.enableDirectMode() }
        engine.apply(lighting)
        // A profile applied at launch can select reactive without ever going
        // through the lighting setter's edit path.
        syncKeyMonitor()
        applyActuation()
        applyRapidTap()
        // Bindings live in the keyboard and survive this app, so only push when
        // we actually have bindings to push — otherwise connecting would wipe
        // remaps someone set elsewhere. "Reset All Bindings" is the explicit
        // way to clear them.
        if includingBindings, !bindings.isEmpty { applyBindings() }
        applyOLED()
    }

    /// Re-establish everything after sleep/wake or a re-plug. On wake the
    /// keyboard has dropped host direct mode, so the enable and a full frame
    /// have to go out again.
    func reapply() {
        isPaused = false
        applyAll()
    }

    // MARK: - Lighting

    private func scheduleLighting() {
        syncKeyMonitor()
        // Any lighting edit takes control back from the firmware.
        if isHandedBack {
            isHandedBack = false
            perform("Enable direct mode") { try $0.enableDirectMode() }
        }
        lightingSubject.send(())
    }

    func applyLightingNow() { engine.apply(lighting) }

    /// Choose an effect, and make sure it will actually be visible.
    ///
    /// "Turn lighting off" is a black static colour, so selecting a
    /// colour-driven effect while the lights are off would otherwise pick an
    /// effect that renders entirely black. Reactive is the one where that is
    /// indistinguishable from a broken feature: every key is off, pressing a key
    /// lights it black, and there is nothing on screen to say why.
    ///
    /// Every effect button goes through here — the pane and the menu bar — so
    /// the rule cannot be implemented in one and forgotten in the other.
    func selectEffect(_ kind: EffectKind) {
        if lighting.baseColor == .black {
            lighting.baseColor = restoreColor == .black ? .steelOrange : restoreColor
        }
        lighting.kind = kind
    }

    func setColor(_ color: LEDColor, forKey hid: UInt8) {
        lighting.perKeyColors[hid] = color
        if lighting.kind != .perKey { lighting.kind = .perKey }
    }

    /// True when every key is being driven to black. Distinct from
    /// `isHandedBack`: this app is still in control, the board is just dark.
    var isLightingOff: Bool {
        lighting.kind == .staticColor && lighting.baseColor == .black
    }

    func setLightingOff(_ off: Bool) {
        if off {
            guard !isLightingOff else { return }
            restoreEffect = lighting.kind
            restoreColor = lighting.baseColor == .black ? .steelOrange : lighting.baseColor
            lighting.kind = .staticColor
            lighting.baseColor = .black
        } else {
            // Only restore when the lights are actually off. Without this,
            // "turn on" while already on would replace whatever effect the user
            // had picked with whatever was saved last time they turned it off.
            guard isLightingOff else {
                takeOverLighting()
                return
            }
            lighting.kind = restoreEffect == .staticColor && restoreColor == .black
                ? .rainbowWave : restoreEffect
            lighting.baseColor = restoreColor
        }
    }

    /// Start driving the LEDs again after handing them back, without changing
    /// which effect is selected.
    func takeOverLighting() {
        guard isHandedBack else { return }
        isHandedBack = false
        perform("Enable direct mode") { try $0.enableDirectMode() }
        engine.apply(lighting)
    }

    /// Stop driving the LEDs and let the keyboard's own lighting take over.
    /// Different from turning the lights off — the board lights itself again.
    func handBackToKeyboard() {
        engine.stop()
        isHandedBack = true
        perform("Hand lighting back") { try $0.clearLighting() }
        note("Lighting handed back to the keyboard")
    }

    // MARK: - Reactive key listening

    /// Start or stop the key listener to match the selected effect.
    ///
    /// Every path that can change either the effect or our ability to listen
    /// comes through here — an edit, a profile being applied, connecting, waking
    /// — so the listener cannot end up running for an effect that does not want
    /// it, or missing for one that does. It used to be started from the lighting
    /// setter alone, which meant launching straight into a saved reactive
    /// profile listened to nothing at all.
    private func syncKeyMonitor() {
        guard lighting.kind.usesReactive, !isPaused else {
            stopKeyMonitor()
            return
        }
        guard keyMonitor == nil else { return }

        monitorGeneration &+= 1
        let generation = monitorGeneration
        // The engine is captured directly: this closure runs on the listener
        // thread for every key press and must not hop to the main actor to get
        // at it. `LightingEngine` is internally locked for exactly this.
        let engine = self.engine
        engine.clearReactiveHits()
        let monitor = KeyMonitor(
            onPress: { hid in engine.registerKeyPress(hid: hid) },
            onStatus: { [weak self] status in
                Task { @MainActor in
                    // A listener that has been replaced still reports its own
                    // shutdown. Without this the stale `.off` lands after the
                    // new one's `.listening` and the UI claims it is broken.
                    guard let self, self.monitorGeneration == generation else { return }
                    self.reactiveInput = status
                }
            })
        keyMonitor = monitor
        monitor.start()
    }

    private func stopKeyMonitor() {
        monitorGeneration &+= 1          // ignore anything the old one still says
        keyMonitor?.stop()
        keyMonitor = nil
        if reactiveInput.listener != .off {
            reactiveInput = ReactiveInputStatus(
                listener: .off,
                accessibility: KeyMonitor.isAccessibilityTrusted,
                inputMonitoring: KeyMonitor.inputMonitoring == .granted)
        }
    }

    /// Re-check whether we can listen, and try again if we could not before.
    ///
    /// Called when the app comes back to the front, which is precisely when
    /// someone returns from granting the permission in System Settings, and from
    /// the buttons that send them there.
    func refreshReactiveInput() {
        guard lighting.kind.usesReactive else {
            reactiveInput = ReactiveInputStatus(
                listener: .off,
                accessibility: KeyMonitor.isAccessibilityTrusted,
                inputMonitoring: KeyMonitor.inputMonitoring == .granted)
            return
        }
        if reactiveInput.isListening {
            keyMonitor?.refreshStatus()
            return
        }
        if reactiveInput.listener == .degraded {
            // Degraded is a *live* listener that macOS is starving. The only
            // grant that starts being honoured mid-process is Accessibility —
            // Input Monitoring reaches processes started after it — so restart
            // only when Accessibility has just appeared. Restarting for any
            // other reason would discard the deafness evidence and put a false
            // "watching key presses" on screen until the next missed press.
            if !reactiveInput.accessibility, KeyMonitor.isAccessibilityTrusted {
                stopKeyMonitor()
                syncKeyMonitor()
            } else {
                keyMonitor?.refreshStatus()
            }
            return
        }
        // Blocked, or never started. Drop the old listener and make a fresh
        // attempt — the permission may have arrived since the last one failed.
        stopKeyMonitor()
        syncKeyMonitor()
    }

    /// Ask macOS for the permission, then retry shortly afterwards so a grant
    /// made in the prompt takes effect without the user touching anything else.
    func requestReactiveInputPermission() {
        KeyMonitor.requestPermission()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshReactiveInput()
        }
    }

    /// The live key-press map, so the on-screen keyboard shows the same reactive
    /// frame the hardware is being sent.
    func reactiveHits() -> [UInt8: TimeInterval] { engine.reactiveSnapshot() }

    /// The name of the last key the listener saw, while it is recent enough to
    /// be worth showing. Read by the UI on a slow timer rather than published,
    /// so typing does not invalidate the whole pane on every keystroke.
    func lastReactiveKeyName(within window: TimeInterval = 3) -> String? {
        guard let press = engine.lastReactivePress(), press.secondsAgo <= window else { return nil }
        return ApexProTKLGen3.name(forHID: press.hid)
    }

    /// Stop rendering (display asleep / user paused) without losing state.
    func pauseRendering() {
        guard !isPaused else { return }
        isPaused = true
        engine.stop()
        stopOLEDLoop()
        // Nothing is being drawn, so there is nothing for a key press to do.
        stopKeyMonitor()
    }

    func resumeRendering() {
        guard isPaused else { return }
        isPaused = false
        engine.apply(lighting)
        syncKeyMonitor()
        applyOLED()
    }

    // MARK: - Actuation & rapid trigger

    /// Everything the actuation commands send, per analog key — computed once
    /// so the live RAM writes and the flash persist cannot drift apart.
    private struct ActuationFrame {
        var modes: [UInt8: Actuation.ReleaseMode] = [:]
        var senses: [UInt8: UInt8] = [:]
        var second: [UInt8: Int?] = [:]
        var primary: [UInt8: Int] = [:]
    }

    private func actuationFrame() -> ActuationFrame {
        let config = actuation
        // Keys that have something bound past the second point. Without a depth
        // for each of them the firmware is told they have no second point at
        // all — `secondActuationLevel(for:)` answers nil for any key the user
        // has not dragged a slider for — and the binding can never fire. The
        // global depth stands in, which is also what the editor displays.
        let deeplyBound = ApexProTKLGen3.analogHIDOrder.filter {
            !bindings.isBlank($0, layer: .secondActuation)
        }
        let standIn = Set(config.secondActuationEnabled ? deeplyBound : [])
        var frame = ActuationFrame()
        for hid in ApexProTKLGen3.analogHIDOrder {
            frame.primary[hid] = config.level(for: hid)
            frame.modes[hid] = config.rapidTriggerEnabled(for: hid) ? config.releaseMode : .off
            frame.senses[hid] = config.rapidTriggerSensitivity
            var level: Int? = config.secondActuationLevel(for: hid)
            if level == nil, standIn.contains(hid) {
                level = max(config.secondActuationLevel, config.level(for: hid) + 1)
            }
            frame.second[hid] = level
        }
        return frame
    }

    func applyActuation() {
        guard isConnected else { return }
        let config = actuation
        let frame = actuationFrame()
        perform("Apply actuation") { dev in
            try dev.setActuation(perKeyLevel: config.usePerKey ? config.perKey.values : [:],
                                 defaultLevel: config.globalLevel)
            try dev.setRapidTriggerSensitivity(perKey: frame.senses)
            try dev.setRapidTriggerMode(perKeyMode: frame.modes)
            try dev.setSecondActuation(perKeyLevel: frame.second)
        }
        schedulePersist()
    }

    // MARK: - Rapid tap (SOCD)

    func applyRapidTap() {
        guard isConnected else { return }
        let config = rapidTap
        perform("Apply rapid tap") { dev in
            let pairs = config.validPairs.map {
                Actuation.RapidTapPair(hid1: $0.key1, hid2: $0.key2, mode: $0.mode, reportBoth: $0.reportBoth)
            }
            try dev.setRapidTapPairs(pairs)
            try dev.setRapidTapEnabled(config.enabled && !pairs.isEmpty)
        }
        schedulePersist()
    }

    // MARK: - Bindings (PRD-01 / 02 / 03)

    /// What a complete frame for a layer should be built on top of, or nil when
    /// the layer must not be written at all yet.
    ///
    /// Every mapping write is a **complete** frame, so this decides the fate of
    /// the ninety keys the user did not touch.
    ///
    /// * A layer already read off the keyboard is merged over, so entries this
    ///   app does not model — firmware functions, macros — survive the trip.
    /// * The **Fn layer unread is never written**. It ships with nine `0x62`
    ///   firmware shortcuts (brightness, media, the screen) that we know of no
    ///   command to restore, and a frame built without them erases them. One
    ///   edit plus a read that did not answer used to be enough: the old guard
    ///   was `!mine.isEmpty || known != nil`, and the left half let a single
    ///   binding authorise a frame of ninety blanks.
    /// * The other two layers unread are safe to build from nothing, because
    ///   their blanks *are* the factory resting state — self-mapping on the
    ///   normal layer, unbound on the deeper one — so an unmentioned key is
    ///   restored rather than destroyed.
    private func writeBase(for layer: Mappings.Layer,
                           mine: [UInt8: Mappings.Binding]) -> [UInt8: Mappings.Binding]? {
        if let known = deviceBindings[layer] { return known }
        guard layer.isSafeToWriteUnread, !mine.isEmpty else { return nil }
        return [:]
    }

    /// Write the mapping layers plus the meta trigger and highlight mask.
    func applyBindings() {
        guard isConnected else { return }

        var built: [Mappings.Layer: [UInt8: Mappings.Binding]] = [:]
        var skipped: [String] = []
        for layer in Mappings.Layer.allCases {
            let mine = bindings[layer].values
            guard let base = writeBase(for: layer, mine: mine) else {
                if !mine.isEmpty { skipped.append(layer.displayName) }
                continue
            }
            built[layer] = base.merging(mine) { _, new in new }
        }

        let frames = built
        // nil means "never touched" — leave the keyboard's own Fn trigger
        // alone. Writing 0 here used to disable the factory Fn key (the
        // SteelSeries key) on every connect. An explicit "no Fn key" is stored
        // as 0, which really does clear it.
        let toggle = bindings.metaToggleHID
        let highlight = frames[.meta] ?? (deviceBindings[.meta] ?? [:])

        perform("Apply key bindings") { [weak self] dev in
            // In layer order, so a crash mid-write leaves a predictable state.
            for layer in Mappings.Layer.allCases {
                guard let frame = frames[layer] else { continue }
                try dev.writeMappings(layer: layer, bindings: frame)
            }
            if let toggle { try dev.setMetaToggleKey(hid: toggle) }
            try dev.setMetaHighlight(metaBindings: highlight)
            Task { @MainActor in self?.adoptWrittenFrames(frames) }
        }

        deferredLayers = Set(Mappings.Layer.allCases.filter {
            !bindings[$0].isEmpty && frames[$0] == nil
        })
        if !skipped.isEmpty {
            let names = skipped.joined(separator: ", ")
            statusMessage = "Connected — \(names) left untouched until it has been read"
        }
        schedulePersist()
    }

    /// Record that the keyboard now holds exactly what was just written.
    ///
    /// A frame is complete for its layer, so this is not a guess: keys the
    /// frame did not mention were filled in with the layer's blank by
    /// `writeChunks`. Without this the model of the device stays frozen at the
    /// last explicit read, which made "Reset all keys" reversible by accident
    /// — the next edit merged the pre-reset remaps straight back onto the
    /// hardware — and left the read-back card reporting a mismatch after every
    /// successful write.
    private func adoptWrittenFrames(_ frames: [Mappings.Layer: [UInt8: Mappings.Binding]]) {
        for (layer, frame) in frames {
            var complete: [UInt8: Mappings.Binding] = [:]
            for hid in layer.hidOrder {
                complete[hid] = frame[hid] ?? layer.blankBinding(forHID: hid)
            }
            deviceBindings[layer] = complete
        }
    }

    func setBinding(_ binding: Mappings.Binding, forKey hid: UInt8, layer: Mappings.Layer? = nil,
                    describedAs description: String? = nil) {
        let target = layer ?? bindingLayer
        guard ApexProTKLGen3.mappableHIDCodeSet.contains(hid) else {
            lastError = ApexError.notMappable(hid).description
            return
        }
        // The deeper layer is addressed by the 68 adjustable keys only.
        // `writeChunks` iterates `analogHIDOrder`, so a mechanical key accepted
        // here would sit in the configuration for ever, counted as a change,
        // and never reach the keyboard.
        guard target != .secondActuation || ApexProTKLGen3.analogHIDCodes.contains(hid) else {
            lastError = "\(ApexProTKLGen3.name(forHID: hid)) is not one of the 68 adjustable keys, "
                + "so it cannot tell a light press from a deep one."
            return
        }
        guard bindings.binding(for: hid, layer: target) != binding else { return }
        recordUndo(description ?? "\(ApexProTKLGen3.name(forHID: hid)) → \(binding.summary)")
        bindings[target][hid] = binding
        scheduleBindingsApply()
        if target == .secondActuation { scheduleActuationApply() }
    }

    func resetBinding(forKey hid: UInt8, layer: Mappings.Layer? = nil) {
        let target = layer ?? bindingLayer
        // Already explicitly blank and not the Fn trigger: nothing to do. This
        // keeps re-selecting "Default" on an untouched key out of the undo
        // history and off the wire.
        if bindings[target][hid] == target.blankBinding(forHID: hid) { return }
        recordUndo("\(ApexProTKLGen3.name(forHID: hid)) back to normal")
        // Store the blank explicitly rather than removing the entry: the apply
        // path merges over what the keyboard already has, so a missing entry
        // would leave the old binding in place and the reset would do nothing.
        bindings[target][hid] = target.blankBinding(forHID: hid)
        // Being the Fn trigger is not a binding on any layer, so it is not this
        // button's business. Clearing it here meant that resetting the ordinary
        // behaviour of whichever key was Fn switched the entire Fn layer off.
        scheduleBindingsApply()
    }

    // MARK: Undo

    /// One step of binding history.
    ///
    /// The device's own contents ride along with the app's configuration
    /// because some of what a change destroys is not in the configuration at
    /// all: the Fn layer's factory shortcuts live only on the keyboard, and the
    /// only copy of them we will ever have is the one the read-back produced.
    private struct BindingHistoryEntry {
        var config: BindingsConfig
        var label: String
    }

    private func recordUndo(_ label: String, restoringDeviceLayers layers: [Mappings.Layer] = []) {
        var config = bindings
        for layer in layers {
            guard let onDevice = deviceBindings[layer] else { continue }
            // Fold what the keyboard currently holds into the snapshot, so
            // undoing writes it back byte for byte.
            var merged = onDevice
            merged.merge(config[layer].values) { _, mine in mine }
            config[layer] = HIDMap(merged)
        }
        undoStack.append(BindingHistoryEntry(config: config, label: label))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshHistory(label)
    }

    private func refreshHistory(_ label: String?) {
        undoDepth = undoStack.count
        redoDepth = redoStack.count
        lastBindingChange = label
    }

    var canUndoBindings: Bool { !undoStack.isEmpty }
    var canRedoBindings: Bool { !redoStack.isEmpty }

    /// The name of the change undo would reverse, for the menu item.
    var undoBindingLabel: String? { undoStack.last?.label }
    var redoBindingLabel: String? { redoStack.last?.label }

    func undoBindingChange() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(BindingHistoryEntry(config: bindings, label: entry.label))
        bindings = entry.config
        refreshHistory(nil)
        applyBindings()
        note("Undid “\(entry.label)”")
    }

    func redoBindingChange() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(BindingHistoryEntry(config: bindings, label: entry.label))
        bindings = entry.config
        refreshHistory(entry.label)
        applyBindings()
        note("Redid “\(entry.label)”")
    }

    private func scheduleBindingsApply() { bindingsSubject.send(()) }

    /// Coalesced actuation write, for controls that change while dragging.
    func scheduleActuationApply() { actuationSubject.send(()) }

    /// Return every key to its factory behaviour. Reachable from the menu bar
    /// so a keyboard remapped into unusability can be rescued.
    ///
    /// The Fn layer is deliberately left alone: it holds the keyboard's own
    /// brightness / media / OLED shortcuts, which we know of no command to restore once
    /// overwritten. Use `resetFnLayer()` to clear it explicitly.
    func resetAllBindings() {
        recordUndo("Reset every key", restoringDeviceLayers: [.normal, .secondActuation])
        bindings.normal.removeAll()
        bindings.secondActuation.removeAll()
        guard isConnected else { return }
        perform("Reset bindings") { [weak self] dev in
            try dev.writeMappings(layer: .normal, bindings: [:])
            try dev.writeMappings(layer: .secondActuation, bindings: [:])
            Task { @MainActor in self?.adoptWrittenFrames([.normal: [:], .secondActuation: [:]]) }
        }
        readBindingsFromDevice(quiet: true)
        schedulePersist()
        note("Every key is back to normal. The Fn layer was left as it was.")
    }

    /// Clear the Fn layer, including the shortcuts the keyboard shipped with.
    ///
    /// We know of no command that restores those shortcuts, so the snapshot taken here folds
    /// in the layer as it was read off the keyboard: for as long as this session
    /// lasts, Undo really can put them back.
    func resetFnLayer() {
        recordUndo("Clear the Fn layer", restoringDeviceLayers: [.meta])
        bindings.meta.removeAll()
        bindings.metaToggleHID = 0        // explicit "no Fn key", not "follow the keyboard"
        guard isConnected else { return }
        perform("Reset Fn layer") { [weak self] dev in
            try dev.writeMappings(layer: .meta, bindings: [:])
            try dev.setMetaToggleKey(hid: 0)
            try dev.setMetaHighlight(metaBindings: [:])
            Task { @MainActor in self?.adoptWrittenFrames([.meta: [:]]) }
        }
        readBindingsFromDevice(quiet: true)
        schedulePersist()
        note("Fn layer cleared")
    }

    /// The key that currently activates the Fn layer: the user's choice when
    /// they have made one, otherwise whatever the keyboard's own profile says
    /// (factory: the SteelSeries key). 0 / nil mean no key does.
    var effectiveMetaToggleHID: UInt8? {
        if let mine = bindings.metaToggleHID { return mine == 0 ? nil : mine }
        return deviceMetaToggleHID
    }

    /// Choose the Fn key. `nil` means "no Fn key" and is stored as an explicit
    /// 0 — in the configuration, nil is reserved for "never touched, follow
    /// the keyboard", which must not clear the factory trigger.
    func setMetaToggleKey(_ hid: UInt8?) {
        if let hid, !ApexProTKLGen3.mappableHIDCodeSet.contains(hid) {
            lastError = ApexError.notMappable(hid).description
            return
        }
        let newValue = hid ?? 0
        let current = bindings.metaToggleHID ?? deviceMetaToggleHID ?? 0
        guard current != newValue else { return }
        // Materialise the keyboard's own value before the first change, so
        // undo can put the real previous trigger back instead of clearing it.
        if bindings.metaToggleHID == nil { bindings.metaToggleHID = current }
        recordUndo(hid.map { "Fn key → \(ApexProTKLGen3.name(forHID: $0))" } ?? "No Fn key")
        bindings.metaToggleHID = newValue
        scheduleBindingsApply()
    }


    /// Read the keyboard's current bindings so the editor reflects reality —
    /// including whatever other software or an onboard profile last wrote (PRD-01 FR-1).
    /// - Parameter quiet: suppress the error banner. Used for the automatic read
    ///   on connect, where a keyboard that does not answer should not raise an
    ///   alert every time it is plugged in.
    /// - Parameter thenApply: write our bindings once the read completes, so
    ///   the write can merge over the device's real contents.
    func readBindingsFromDevice(seedEditor: Bool = false, quiet: Bool = false, thenApply: Bool = false) {
        guard isConnected, !isReadingBindings else { return }
        isReadingBindings = true
        perform("Read bindings") { [weak self] dev in
            var result: [Mappings.Layer: [UInt8: Mappings.Binding]] = [:]
            var failure: String?
            for layer in Mappings.Layer.allCases {
                do {
                    result[layer] = try dev.readMappings(layer: layer)
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.isReadingBindings = false
                if let failure {
                    self.bindingReadBackSupported = false
                    self.statusMessage = "Connected (binding read-back unavailable)"
                    if !quiet {
                        self.lastError = "Could not read bindings from the keyboard: \(failure)"
                    }
                    // The boot profile stands in for the layers RAM would not
                    // report: flash *is* RAM at power-up, and it always carries
                    // the Fn layer's factory shortcuts — so a flaky RAM read no
                    // longer locks the Fn layer against editing.
                    if let image = self.flashImage {
                        for layer in Mappings.Layer.allCases where self.deviceBindings[layer] == nil {
                            self.deviceBindings[layer] = image.bindings(layer: layer)
                        }
                        if seedEditor { self.seedEditorIfEmpty(from: image) }
                    }
                    // Still push what we have. `applyBindings` only touches
                    // layers it has bindings for, so a failed read costs us
                    // accuracy, not the ability to configure the keyboard.
                    if thenApply, !self.bindings.isEmpty { self.applyBindings() }
                    return
                }
                self.bindingReadBackSupported = true
                self.deviceBindings = result
                // A layer skipped for want of a read can be written now.
                let deferred = !self.deferredLayers.isEmpty
                self.deferredLayers = []
                if seedEditor {
                    // Keep only genuine customisations: the keyboard reports
                    // every key explicitly (self-mapped on the normal layer),
                    // and carrying all 91 into the editor would make a stock
                    // keyboard look fully remapped.
                    for (layer, map) in result {
                        self.bindings[layer] = HIDMap(map.filter { hid, binding in
                            !Mappings.isBlank(binding, layer: layer, hid: hid)
                        })
                    }
                }
                if (thenApply || deferred), !self.bindings.isEmpty { self.applyBindings() }
            }
        }
    }

    /// True when a layer's live state matches what we last wrote — the
    /// round-trip check PRD-01 AC-4 asks for.
    func bindingsMatchDevice(layer: Mappings.Layer) -> Bool? {
        guard let onDevice = deviceBindings[layer] else { return nil }
        let mine = bindings[layer].values
        for hid in layer.hidOrder {
            // What `applyBindings` would put on this key: this app's binding if
            // it has one, otherwise whatever the keyboard already holds, which
            // the merge deliberately preserves. Comparing the layer's blank
            // instead reported every stock keyboard's nine factory Fn shortcuts
            // as a disagreement, permanently.
            let wanted = mine[hid] ?? onDevice[hid] ?? layer.blankBinding(forHID: hid)
            guard let actual = onDevice[hid] else { continue }
            // A keyboard mapping is a set of usages, so compare it as one:
            // whatever wrote the keyboard last was under no obligation to order
            // the four bytes the way this app does.
            if Mappings.equivalent(wanted, actual) { continue }
            // The firmware has two spellings of "nothing set here" — function 0
            // and the self-mapping it rests in — so treat both as equal.
            if Mappings.isBlank(wanted, layer: layer, hid: hid),
               Mappings.isBlank(actual, layer: layer, hid: hid) { continue }
            return false
        }
        return true
    }

    // MARK: - Persistence (keyboard flash)

    /// Read the slot-0 boot profile off the keyboard's flash.
    ///
    /// This is the ground truth for "what survives a power cycle": every live
    /// command writes RAM only (verified on hardware — see PROTOCOL.md
    /// §Onboard profiles), and at power-up the keyboard reloads this image.
    /// It also carries the one setting nothing else can read back: the Fn
    /// trigger key.
    private func readOnboardFlash() {
        perform("Read the keyboard's saved profile") { [weak self] dev in
            do {
                let image = try dev.readOnboardProfile(slot: 0)
                Task { @MainActor in
                    guard let self, self.isConnected else { return }
                    self.flashImage = image
                    self.deviceMetaToggleHID = image.metaToggleHID
                    // The boot profile is the best available estimate of RAM
                    // for any layer the flaky RAM read has not supplied.
                    for layer in Mappings.Layer.allCases where self.deviceBindings[layer] == nil {
                        self.deviceBindings[layer] = image.bindings(layer: layer)
                    }
                    // Untouched app config adopts the keyboard's saved values
                    // rather than imposing defaults. The connect-time apply
                    // already pushed the defaults to RAM; without this, the
                    // persist below would burn them into flash, permanently
                    // overwriting actuation someone set through other software
                    // or the keyboard's own OLED menu.
                    var reapply = false
                    if self.actuation == ActuationConfig() {
                        self.actuation = image.actuationConfigSeed()
                        reapply = true
                    }
                    if self.rapidTapIsPristine {
                        self.rapidTap = image.rapidTapConfigSeed()
                        reapply = true
                    }
                    if reapply {
                        self.applyActuation()
                        self.applyRapidTap()
                    }
                    // If the app already holds settings the flash lacks (edits
                    // made while unplugged, a profile applied at launch), get
                    // them saved; otherwise just report the truthful state.
                    self.schedulePersist()
                }
            } catch let error as ApexError {
                Task { @MainActor in
                    guard let self else { return }
                    switch error {
                    case .onboardProfileUnsupported(let why), .onboardProfileCorrupt(let why):
                        self.persistState = .unsupported(why)
                    default:
                        self.persistState = .failed(error.description)
                    }
                }
            } catch {
                Task { @MainActor in
                    self?.persistState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// True while the rapid-tap config is factory-fresh. `RapidTapConfig()`
    /// carries one disabled template pair whose `id` is a fresh UUID, so plain
    /// `==` against a new instance can never say "untouched" — compare the
    /// fields that mean something instead.
    private var rapidTapIsPristine: Bool {
        guard !rapidTap.enabled, rapidTap.pairs.count == 1 else { return false }
        let pair = rapidTap.pairs[0]
        let blank = RapidTapConfig.Pair()
        return pair.key1 == blank.key1 && pair.key2 == blank.key2
            && pair.mode == blank.mode && pair.reportBoth == blank.reportBoth
    }

    /// Adopt a flash image's customisations into an empty editor — the cold-
    /// boot path when the RAM read did not answer.
    private func seedEditorIfEmpty(from image: OnboardProfile.Image) {
        guard bindings.isEmpty else { return }
        for layer in Mappings.Layer.allCases {
            bindings[layer] = HIDMap(image.bindings(layer: layer).filter { hid, binding in
                !Mappings.isBlank(binding, layer: layer, hid: hid)
            })
        }
    }

    /// Note that the keyboard-stored settings may have drifted from flash, and
    /// queue a save for the next quiet moment. Cheap to call from every apply.
    private func schedulePersist() {
        guard isConnected, flashImage != nil else { return }
        if case .unsupported = persistState { return }
        // Report truthfully straight away — "pending" only when something
        // actually differs; the debounced write still does its own comparison.
        if let image = patchedImage(), persistState != .saving {
            persistState = image == flashImage ? .saved : .pending
        }
        persistSubject.send(())
    }

    /// The flash image the current live state should boot into: the last image
    /// read off the keyboard, with every field this app owns patched to match
    /// what the live writes sent. Fields the app does not model — profile
    /// name, GUID, onboard lighting colours, zone settings, macros, the OLED
    /// bitmap — ride along byte-for-byte.
    private func patchedImage() -> OnboardProfile.Image? {
        guard var image = flashImage else { return nil }

        // Bindings: the same complete frames applyBindings writes. A layer
        // with no safe write base keeps its flash contents untouched.
        for layer in Mappings.Layer.allCases {
            let mine = bindings[layer].values
            guard let base = writeBase(for: layer, mine: mine) else { continue }
            let frame = base.merging(mine) { _, new in new }
            image.setBindings(layer: layer, frame: frame)
            if layer == .meta { image.setMetaMask(metaBindings: frame) }
        }
        if let toggle = bindings.metaToggleHID {
            image.setMetaToggleHID(toggle == 0 ? nil : toggle)
        }

        // Actuation and rapid trigger — the exact values applyActuation sends.
        let frame = actuationFrame()
        image.setActuation(perKeyHL: frame.primary.mapValues { Actuation.hl(forLevel: $0) })
        image.setSecondActuation(perKeyHL: frame.second.mapValues { level in
            level.map { Actuation.hl(forLevel: $0) } ?? Actuation.disabledHL
        })
        image.setReleaseModes(perKeyRawMode: frame.modes.mapValues(\.rawValue))
        image.setRapidTriggerSensitivity(perKey: frame.senses)

        let pairs = rapidTap.validPairs.map {
            Actuation.RapidTapPair(hid1: $0.key1, hid2: $0.key2, mode: $0.mode, reportBoth: $0.reportBoth)
        }
        image.setRapidTap(pairs: pairs, enabled: rapidTap.enabled)

        image.sealCRC()
        return image
    }

    /// Write the live state into the keyboard's boot profile, if it differs.
    ///
    /// This is what makes "stored in the keyboard" true across a power cycle.
    /// The write is erase-then-rewrite of the whole image plus a byte-for-byte
    /// read-back, several seconds of bus time, so the lighting stream and the
    /// OLED clock pause around it and everything is diff-gated: identical
    /// content never touches flash.
    private func persistToKeyboard() {
        guard isConnected, let target = patchedImage() else { return }
        if case .unsupported = persistState { return }
        guard target != flashImage else {
            persistState = .saved
            return
        }
        persistState = .saving

        // Flash writes stall the control pipe; a concurrent 30 fps lighting
        // stream would time out mid-frame.
        engine.stop()
        stopOLEDLoop()

        perform("Save to keyboard") { [weak self] dev in
            do {
                try dev.writeOnboardProfile(target, slot: 0)
                Task { @MainActor in
                    guard let self else { return }
                    self.flashImage = target
                    self.deviceMetaToggleHID = target.metaToggleHID
                    self.persistState = .saved
                    self.resumeAfterPersist()
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.persistState = .failed(error.localizedDescription)
                    self.lastError = "Saving to the keyboard failed: \(error.localizedDescription)"
                    self.resumeAfterPersist()
                }
            }
        }
    }

    private func resumeAfterPersist() {
        guard isConnected, !isPaused else { return }
        if !isHandedBack { engine.apply(lighting) }
        if oled.mode == .clock { startOLEDLoop() }
    }

    /// Best-effort synchronous save on quit, so an edit made seconds before
    /// quitting is not lost with the debounce. Skips the read-back verify to
    /// keep quit fast; the next launch re-reads flash anyway.
    private func flushPersistOnQuit() {
        guard isConnected, let target = patchedImage(), target != flashImage else { return }
        if case .unsupported = persistState { return }
        let dev = device
        let done = DispatchSemaphore(value: 0)
        deviceQueue.async {
            try? dev.writeOnboardProfile(target, slot: 0, verify: false)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 8)
    }

    // MARK: - OLED

    func applyOLED() {
        guard isConnected else { return }
        stopOLEDLoop()
        let config = oled
        switch config.mode {
        case .off:
            perform("Reset OLED") { try $0.resetOLED() }
        case .text, .image:
            guard let bmp = config.render() else {
                lastError = "Could not render the OLED image."
                return
            }
            perform("Update OLED") { try $0.showOLED(bmp) }
        case .clock:
            startOLEDLoop()
        }
    }

    /// A live clock changes every second, so there is nothing stable to write
    /// into flash.
    var canPersistOLED: Bool {
        isConnected && (oled.mode == .text || oled.mode == .image)
    }

    /// What the OLED is showing right now, for the on-screen previews. `nil`
    /// when the keyboard is drawing its own screen.
    var oledBitmap: MonoBitmap? { oled.render() }

    /// Store the current OLED content in the keyboard's flash so it survives
    /// quitting the app.
    func persistOLED() {
        guard let bmp = oled.render() else { return }
        perform("Save OLED image") { try $0.persistOLED(bmp) }
        note("Screen saved to the keyboard")
    }

    func resetOLED() {
        stopOLEDLoop()
        oled.mode = .off
        perform("Reset OLED") { try $0.resetOLED() }
    }

    private func startOLEDLoop() {
        let config = oled
        let dev = device
        let timer = DispatchSource.makeTimerSource(queue: deviceQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler {
            guard let bmp = config.render() else { return }
            try? dev.showOLED(bmp)
        }
        oledTimer = timer
        timer.resume()
    }

    private func stopOLEDLoop() {
        oledTimer?.cancel()
        oledTimer = nil
    }

    // MARK: - Profiles (PRD-06)

    /// Snapshot the live state as a profile.
    func captureCurrent(name: String = "New Profile") -> SoftwareProfile {
        var p = SoftwareProfile()
        p.name = name
        p.lighting = lighting
        p.actuation = actuation
        p.rapidTap = rapidTap
        p.bindings = bindings
        p.oled = oled
        return p
    }

    /// Load a profile into the live state and push it to the keyboard.
    func apply(_ profile: SoftwareProfile) {
        lighting = profile.lighting        // didSet schedules the lighting apply
        actuation = profile.actuation
        rapidTap = profile.rapidTap
        bindings = profile.bindings
        oled = profile.oled
        applyAll()
        note("Applied “\(profile.name)”")
    }

    /// True when the live state still equals the given profile.
    func matches(_ profile: SoftwareProfile) -> Bool {
        captureCurrent(name: profile.name).hasSameSettings(as: profile)
    }

    func loadOnboardSlot(_ slot: UInt8) {
        perform("Switch onboard profile") { try $0.loadProfile(slot: slot) }
    }

    func setProfileVolatile(_ volatile: Bool) {
        perform("Set profile volatility") { try $0.setProfileVolatile(volatile) }
    }

    // MARK: - Lifecycle

    func shutdown() {
        engine.stop()
        stopOLEDLoop()
        stopKeyMonitor()
        // An edit made moments ago may still be inside the persist debounce;
        // losing it to a power cycle later would be this bug all over again.
        flushPersistOnQuit()
        // Leave the user's lighting in place; do not force onboard mode on quit.
    }

    // MARK: - Helpers

    /// Show a short confirmation that clears itself. Only for actions the user
    /// explicitly triggered — a write they can see the result of needs no note.
    func note(_ message: String) {
        actionNote = message
        noteTask?.cancel()
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.actionNote = nil
        }
    }

    /// Run device I/O off the main actor and report failures to the UI.
    private func perform(_ label: String, _ work: @escaping @Sendable (ApexDevice) throws -> Void) {
        let dev = device
        deviceQueue.async { [weak self] in
            do {
                try work(dev)
            } catch HIDError.notConnected, HIDError.deviceDisconnected {
                // Expected while unplugged; the connection callback already
                // tells the user, so don't stack a second message on top.
                return
            } catch {
                Task { @MainActor in self?.lastError = "\(label) failed: \(error.localizedDescription)" }
            }
        }
    }
}
