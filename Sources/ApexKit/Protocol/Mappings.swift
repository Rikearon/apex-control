import Foundation

/// Button-mapping (key remapping) protocol for the Apex Pro TKL Gen 3.
///
/// Provenance: the layout below is from the vendor's description of the device
/// and is confirmed on hardware (docs/PROTOCOL.md says how sure each part is).
///
/// One binding block is 6 bytes: `hid_code` (1), `function` (1), `key_codes` (4).
/// The values `function` can take are listed in `Function`.
///
/// Writes go out as Feature reports:
///
///     [0x36][layer][count][ (hid, fn, kc0…kc3) × count ]
///
/// Read-back is the same shape with command `0xB6`: you send the list of HID
/// codes you want (function/key-codes zeroed) and the device answers with the
/// same blocks filled in.
///
/// There are three independent layers, all addressed by HID code:
///  * `0x00` normal — what a key does on its own,
///  * `0x01` meta — what it does while the Fn/meta key is held (PRD-02),
///  * `0x02` second actuation — what it does past the *second* actuation point
///    on an analog key (PRD-03).
public enum Mappings {

    public static let featurePayloadSize = 644
    public static let outputPayloadSize = 64

    public static let writeCommand: UInt8 = 0x36
    public static let readCommand: UInt8 = 0xB6
    /// Output report carrying the 32-byte "these keys have a meta binding"
    /// bitmask the firmware uses to highlight Fn-bound keys.
    public static let metaHighlightCommand: UInt8 = 0x3C
    /// Output report selecting which key acts as the meta/Fn trigger.
    public static let metaToggleCommand: UInt8 = 0x35

    /// `(feature-report-size − 5) / 6` — 5 accounts for the report-ID byte, the
    /// command, the layer, the count, and (on reads) the error byte.
    public static let keysPerChunk = (645 - 5) / 6      // 106

    /// Byte offset of the first block in a read reply, in a macOS Feature
    /// buffer (report-ID byte excluded): `[0]` command echo, `[1]` error byte,
    /// `[2]` layer, `[3]` count.
    ///
    /// The four-byte size comes from the vendor's description of the device (a
    /// read reply spends 5 bytes on its header and error byte, one of which is
    /// the report-ID byte macOS strips). The field *order* — error byte
    /// immediately after the command, matching `read_layout`/`read_region` —
    /// was confirmed on hardware: a request with no block list answers
    /// `B6 01 00 5B`, i.e. command, err = 1, layer 0, count 91.
    static let readHeaderSize = 4

    // MARK: - Layers

    public enum Layer: UInt8, Sendable, CaseIterable, Codable, Identifiable {
        case normal = 0x00
        case meta = 0x01
        case secondActuation = 0x02

        public var id: UInt8 { rawValue }

        public var displayName: String {
            switch self {
            case .normal: return "Normal"
            case .meta: return "Fn Layer"
            case .secondActuation: return "Second Actuation"
            }
        }

        /// The keys this layer addresses, in the order the firmware expects.
        public var hidOrder: [UInt8] {
            switch self {
            case .normal, .meta: return ApexProTKLGen3.mappableHIDOrder
            case .secondActuation: return ApexProTKLGen3.analogHIDOrder
            }
        }

        /// What to write for a key the user has not configured.
        ///
        /// Every mapping write is a **complete** frame for its layer, so this
        /// value decides what happens to the other 90 keys — it has to be
        /// exactly right.
        ///
        /// * Normal layer → the key's **own HID usage** as a `KEYBOARD`
        ///   mapping. This is not a guess: reading the layer back off an
        ///   unmodified keyboard returns `04 51 04 00 00 00`, `05 51 05 …` —
        ///   every key explicitly mapped to itself. Writing that restores
        ///   precisely the observed resting state.
        /// * Meta / second-actuation layers → `unbound`. A self-mapping there
        ///   would make every key fire itself on the Fn layer; the descriptor's
        ///   own blank for the second-actuation layer is likewise
        ///   `{function: 0, key_codes: [0 0 0 0]}`.
        public func blankBinding(forHID hid: UInt8) -> Binding {
            switch self {
            case .normal: return .keyboard(usage: hid)
            case .meta, .secondActuation: return .unbound
            }
        }

        /// Whether a complete frame may be built for this layer when the
        /// keyboard's current contents are **not** known.
        ///
        /// A mapping write is always a complete frame, so writing one without
        /// having read the layer first replaces every key the frame does not
        /// mention with `blankBinding(forHID:)`.
        ///
        /// For the normal and second-actuation layers that blank *is* the
        /// factory resting state, so an unmentioned key is restored. The meta
        /// layer is different in kind: it ships with nine `0x62` firmware
        /// shortcuts — brightness, media, the screen — that this app cannot
        /// reconstruct: they exist only on the keyboard and in any profile dump.
        /// A frame built without them erases them, so it is never written
        /// unread, however badly the user wants their one Fn binding applied.
        public var isSafeToWriteUnread: Bool { self != .meta }
    }

    // MARK: - Functions

    /// The `function` byte of a binding block. The values are the ones the
    /// vendor's description of the device lists.
    public enum Function: UInt8, Sendable, Codable, CaseIterable {
        /// No override: the blank for the meta and second-actuation layers. On
        /// the normal layer a stock keyboard reads back each key mapped to its
        /// own usage (`51 <hid> 00 00 00`), and that self-mapping, not `function 0`,
        /// is what the app writes as the blank there (see `Layer.blankBinding`).
        case unbound = 0x00
        case mouseButton1 = 0x01
        case mouseButton2 = 0x02
        case mouseButton3 = 0x03
        case mouseButton4 = 0x04
        case mouseButton5 = 0x05
        case mouseButton6 = 0x06
        case mouseButton7 = 0x07
        case mouseButton8 = 0x08
        /// Mouse DPI step. Meaningless on a keyboard; present for completeness.
        case cpi = 0x30
        case mouseWheelUp = 0x31
        case mouseWheelDown = 0x32
        case panLeft = 0x33
        case panRight = 0x34
        /// Send one or more HID keyboard usages (`key_codes`).
        case keyboard = 0x51
        /// Send a HID consumer-page usage (`key_codes[0..1]`, little-endian).
        case consumer = 0x61
        /// Make this key the meta/Fn trigger.
        case meta = 0x62
        /// Play an onboard macro (PRD-04).
        case macro = 0x71
        /// Emit a host-assisted sentinel; the host performs the action (PRD-14).
        case external = 0x72
    }

    // MARK: - Binding

    /// One `button_mapping` payload — what a key does, minus the key itself.
    public struct Binding: Equatable, Hashable, Sendable, Codable {
        public var function: UInt8
        /// Always exactly 4 bytes.
        public var keyCodes: [UInt8]

        public init(function: UInt8, keyCodes: [UInt8] = []) {
            self.function = function
            var kc = Array(keyCodes.prefix(4))
            while kc.count < 4 { kc.append(0) }
            self.keyCodes = kc
        }

        public init(function: Function, keyCodes: [UInt8] = []) {
            self.init(function: function.rawValue, keyCodes: keyCodes)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fn = try c.decode(UInt8.self, forKey: .function)
            let kc = try c.decodeIfPresent([UInt8].self, forKey: .keyCodes) ?? []
            self.init(function: fn, keyCodes: kc)
        }

        /// The decoded function, or nil for a value the firmware documents but
        /// we do not model (kept round-trippable rather than dropped).
        public var knownFunction: Function? { Function(rawValue: function) }

        // MARK: Factories

        /// Factory behaviour / no override. See `Function.unbound`.
        public static let unbound = Binding(function: .unbound)

        /// Emit HID keyboard usages together, e.g. `[0xE3, 0xE1, 0x21]` for
        /// Cmd+Shift+4. Up to four usages; extras are dropped.
        ///
        /// `key_codes` is a raw 4-byte array in the descriptor with no
        /// documented modifier/usage split, so we send the usages as a simple
        /// simultaneous set — modifiers first, matching the order a HID report
        /// lists them. Verify with `ApexDevice.readMappings` round-trip.
        ///
        /// The combination is canonicalised (de-duplicated, modifiers in ⌃⌥⇧⌘
        /// order) so that the same chord always produces the same four bytes.
        /// Over the limit, **modifiers** are dropped, not the key.
        ///
        /// `key_codes` holds four usages and canonical order puts modifiers
        /// first, so a plain `prefix(4)` on ⌃⌥⇧⌘K wrote the four modifiers and
        /// silently threw K away — a chord that presses nothing, while the
        /// editor went on displaying K. The key someone names is the point of
        /// the binding; a modifier they happened to be holding is not.
        public static func keyboard(usages: [UInt8]) -> Binding {
            let ordered = HIDUsage.canonical(usages)
            guard ordered.count > maxKeyboardUsages else {
                return Binding(function: .keyboard, keyCodes: ordered)
            }
            let keys = Array(ordered.filter { !HIDUsage.isModifier($0) }.prefix(maxKeyboardUsages))
            let modifiers = ordered.filter(HIDUsage.isModifier).prefix(maxKeyboardUsages - keys.count)
            return Binding(function: .keyboard, keyCodes: Array(modifiers) + keys)
        }

        /// How many usages one mapping can carry — the width of `key_codes`.
        public static let maxKeyboardUsages = 4

        public static func keyboard(usage: UInt8, modifiers: [UInt8] = []) -> Binding {
            keyboard(usages: modifiers + [usage])
        }

        /// A key that produces nothing. Encoded as KEYBOARD with no usages.
        /// (`function 0` means "use the default", not "disabled".)
        public static let disabled = Binding(function: .keyboard)

        /// Send a HID consumer-page usage (little-endian `uint16`).
        public static func consumer(_ usage: UInt16) -> Binding {
            Binding(function: .consumer, keyCodes: [UInt8(usage & 0xFF), UInt8(usage >> 8)])
        }

        public static func consumer(_ action: ConsumerAction) -> Binding { consumer(action.usage) }

        /// Mouse button 1…8.
        public static func mouse(button: Int) -> Binding {
            let n = UInt8(max(1, min(8, button)))
            return Binding(function: n)
        }

        public static func mouse(_ action: MouseAction) -> Binding { Binding(function: action.function) }

        /// A built-in firmware function, selected by `key_codes` (PRD-02).
        ///
        /// The vendor's description calls `0x62` META, which reads like "the Fn trigger",
        /// but reading a stock keyboard back shows otherwise: the Fn layer
        /// ships with nine `0x62` entries carrying distinct payloads —
        /// `F9 → 01 00`, `F10 → 02 01`, `F11 → 03 01`, `F12 → 04 01`,
        /// `Q → 0A`, `T → 08`, `I → 07`, `O → 06`, `Left Cmd → 05` — which are
        /// the SteelSeries-key shortcuts for brightness, media, and the OLED.
        /// So `0x62` means "run firmware function *n*", and the key that
        /// *activates* the layer is chosen separately with `metaToggle(hid:)`.
        ///
        /// The individual function ids are not documented anywhere we can
        /// check, so this is a pass-through: read them, keep them, write them
        /// back unchanged.
        public static func firmwareFunction(id: UInt8, page: UInt8 = 0) -> Binding {
            Binding(function: .meta, keyCodes: [id, page])
        }

        /// Play onboard macro `id` (PRD-04). The id encoding inside `key_codes`
        /// is not documented in the descriptor; byte 0 is the working
        /// assumption and is unverified.
        public static func macro(id: UInt8) -> Binding {
            Binding(function: .macro, keyCodes: [id])
        }

        /// Host-assisted action (PRD-14). The keyboard emits a sentinel and the
        /// host performs the action; `actionID` identifies it. The sentinel
        /// format is unverified.
        public static func external(actionID: UInt16) -> Binding {
            Binding(function: .external, keyCodes: [UInt8(actionID & 0xFF), UInt8(actionID >> 8)])
        }

        // MARK: Interpretation

        public var isDefault: Bool { function == Function.unbound.rawValue }

        public var isDisabled: Bool {
            function == Function.keyboard.rawValue && keyCodes.allSatisfy { $0 == 0 }
        }

        /// The HID usages a KEYBOARD binding sends, in order, zeros stripped.
        public var keyboardUsages: [UInt8] {
            guard function == Function.keyboard.rawValue else { return [] }
            return keyCodes.filter { $0 != 0 }
        }

        /// A KEYBOARD mapping read as an editor reads it: one key, plus the
        /// modifiers held with it.
        ///
        /// The base is the **last non-modifier** usage. When the combination is
        /// nothing but modifiers the last of them is the base and the rest are
        /// held with it, because a key bound to Left Shift sends Left Shift —
        /// it does not send "nothing, with Shift held".
        ///
        /// That distinction is not academic. Every key on this keyboard rests
        /// mapped to itself, so the resting state of the Shift key *is* a
        /// modifier-only mapping; treating it as "no base key" made the editor
        /// light up the Shift toggle and claim the key sent some unrelated
        /// letter, and writing that claim back produced `E1 E1 00 00`.
        public var keyboardCombination: (base: UInt8?, modifiers: [UInt8]) {
            let usages = HIDUsage.canonical(keyboardUsages)
            guard !usages.isEmpty else { return (nil, []) }
            if let base = usages.last(where: { !HIDUsage.isModifier($0) }) {
                return (base, usages.filter(HIDUsage.isModifier))
            }
            return (usages.last, Array(usages.dropLast()))
        }

        public var consumerUsage: UInt16? {
            guard function == Function.consumer.rawValue else { return nil }
            return UInt16(keyCodes[0]) | (UInt16(keyCodes[1]) << 8)
        }

        /// A short human-readable description, for the key cap and the list UI.
        public var summary: String {
            if isDisabled { return "Disabled" }
            guard let fn = knownFunction else { return String(format: "Function 0x%02X", function) }
            switch fn {
            case .unbound: return "Default"
            case .keyboard:
                let usages = keyboardUsages
                if usages.isEmpty { return "Disabled" }
                return usages.map { HIDUsage.name($0) }.joined(separator: " + ")
            case .consumer:
                let code = consumerUsage ?? 0
                return ConsumerAction.name(for: code)
            case .meta:
                let id = keyCodes[1] == 0 ? "\(keyCodes[0])" : "\(keyCodes[1]).\(keyCodes[0])"
                return "Firmware function \(id)"
            case .macro: return "Macro \(keyCodes[0])"
            case .external: return "Host action \(UInt16(keyCodes[0]) | (UInt16(keyCodes[1]) << 8))"
            case .cpi: return "CPI step"
            default: return MouseAction(function: fn.rawValue)?.displayName ?? fn.description
            }
        }
    }

    // MARK: - Mouse & consumer catalogues

    public enum MouseAction: String, Sendable, CaseIterable, Identifiable, Codable {
        case button1, button2, button3, button4, button5, button6, button7, button8
        case wheelUp, wheelDown, panLeft, panRight

        public var id: String { rawValue }

        public var function: UInt8 {
            switch self {
            case .button1: return 0x01
            case .button2: return 0x02
            case .button3: return 0x03
            case .button4: return 0x04
            case .button5: return 0x05
            case .button6: return 0x06
            case .button7: return 0x07
            case .button8: return 0x08
            case .wheelUp: return 0x31
            case .wheelDown: return 0x32
            case .panLeft: return 0x33
            case .panRight: return 0x34
            }
        }

        public init?(function: UInt8) {
            guard let m = MouseAction.allCases.first(where: { $0.function == function }) else { return nil }
            self = m
        }

        public var displayName: String {
            switch self {
            case .button1: return "Left Click"
            case .button2: return "Right Click"
            case .button3: return "Middle Click"
            case .button4: return "Mouse 4 (Back)"
            case .button5: return "Mouse 5 (Forward)"
            case .button6: return "Mouse 6"
            case .button7: return "Mouse 7"
            case .button8: return "Mouse 8"
            case .wheelUp: return "Wheel Up"
            case .wheelDown: return "Wheel Down"
            case .panLeft: return "Pan Left"
            case .panRight: return "Pan Right"
            }
        }
    }

    /// HID consumer-page usages worth offering in the UI.
    ///
    /// The first six are **verified**: they are the factory bindings this exact
    /// firmware assigns to its own media/OLED buttons
    /// (function `0x61` with consumer usages 205, 181, 182, 226, 233 and 234).
    /// The rest are standard consumer-page usages that the firmware accepts
    /// structurally but which we have not each confirmed it honours.
    public enum ConsumerAction: String, Sendable, CaseIterable, Identifiable, Codable {
        case playPause, nextTrack, previousTrack, mute, volumeUp, volumeDown
        case play, pause, stop, fastForward, rewind
        case brightnessUp, brightnessDown
        case launchEmail, launchCalculator, launchBrowser, launchMediaPlayer
        case browserHome, browserBack, browserForward, browserRefresh, browserSearch

        public var id: String { rawValue }

        public var usage: UInt16 {
            switch self {
            case .playPause: return 0x00CD        // 205 — verified
            case .nextTrack: return 0x00B5        // 181 — verified
            case .previousTrack: return 0x00B6    // 182 — verified
            case .mute: return 0x00E2             // 226 — verified
            case .volumeUp: return 0x00E9         // 233 — verified
            case .volumeDown: return 0x00EA       // 234 — verified
            case .play: return 0x00B0
            case .pause: return 0x00B1
            case .stop: return 0x00B7
            case .fastForward: return 0x00B3
            case .rewind: return 0x00B4
            case .brightnessUp: return 0x006F
            case .brightnessDown: return 0x0070
            case .launchEmail: return 0x018A
            case .launchCalculator: return 0x0192
            case .launchBrowser: return 0x0196
            case .launchMediaPlayer: return 0x0183
            case .browserHome: return 0x0223
            case .browserBack: return 0x0224
            case .browserForward: return 0x0225
            case .browserRefresh: return 0x0227
            case .browserSearch: return 0x0221
            }
        }

        /// True for the six usages this firmware demonstrably drives itself.
        public var isVerifiedOnThisFirmware: Bool {
            switch self {
            case .playPause, .nextTrack, .previousTrack, .mute, .volumeUp, .volumeDown: return true
            default: return false
            }
        }

        public var displayName: String {
            switch self {
            case .playPause: return "Play / Pause"
            case .nextTrack: return "Next Track"
            case .previousTrack: return "Previous Track"
            case .mute: return "Mute"
            case .volumeUp: return "Volume Up"
            case .volumeDown: return "Volume Down"
            case .play: return "Play"
            case .pause: return "Pause"
            case .stop: return "Stop"
            case .fastForward: return "Fast Forward"
            case .rewind: return "Rewind"
            case .brightnessUp: return "Brightness Up"
            case .brightnessDown: return "Brightness Down"
            case .launchEmail: return "Launch Mail"
            case .launchCalculator: return "Launch Calculator"
            case .launchBrowser: return "Launch Browser"
            case .launchMediaPlayer: return "Launch Media Player"
            case .browserHome: return "Browser Home"
            case .browserBack: return "Browser Back"
            case .browserForward: return "Browser Forward"
            case .browserRefresh: return "Browser Refresh"
            case .browserSearch: return "Browser Search"
            }
        }

        static func name(for usage: UInt16) -> String {
            allCases.first { $0.usage == usage }?.displayName
                ?? String(format: "Consumer 0x%04X", usage)
        }
    }

    /// True when a binding is this layer's "nothing configured here" value.
    ///
    /// There are two spellings on the normal layer — `function 0` and the
    /// self-mapping the hardware actually rests in — and both must read as
    /// "default" everywhere the UI, the CLI, and the read-back comparison ask.
    public static func isBlank(_ binding: Binding, layer: Layer, hid: UInt8) -> Bool {
        binding.isDefault || equivalent(binding, layer.blankBinding(forHID: hid))
    }

    /// Whether two bindings would behave identically on the keyboard.
    ///
    /// Byte equality is too strict for a KEYBOARD mapping: `key_codes` is a set
    /// of usages sent together, so `E3 06` and `06 E3` are the same ⌘C. This app
    /// always writes them in canonical order, but other software and the onboard
    /// profiles do not, and comparing what we would write against what the
    /// keyboard reports has to say "the same" when it is.
    public static func equivalent(_ a: Binding, _ b: Binding) -> Bool {
        guard a.function == b.function else { return false }
        guard a.function == Function.keyboard.rawValue else { return a.keyCodes == b.keyCodes }
        return HIDUsage.canonical(a.keyboardUsages) == HIDUsage.canonical(b.keyboardUsages)
    }

    // MARK: - Packet builders

    /// Split a layer's bindings into the chunks the firmware expects. Every
    /// chunk is a full-size Feature payload.
    ///
    /// The frame is always **complete** — every key the layer addresses is
    /// present — because a partial frame would leave unlisted keys at whatever
    /// the previous write (or the onboard profile) left there. Keys absent from
    /// `bindings` get `layer.blankBinding(forHID:)`.
    public static func writeChunks(layer: Layer, bindings: [UInt8: Binding]) -> [[UInt8]] {
        let order = layer.hidOrder
        var chunks: [[UInt8]] = []
        var index = 0
        while index < order.count {
            let slice = order[index..<min(index + keysPerChunk, order.count)]
            var data = [UInt8](repeating: 0, count: featurePayloadSize)
            data[0] = writeCommand
            data[1] = layer.rawValue
            data[2] = UInt8(slice.count)
            var off = 3
            for hid in slice {
                let b = bindings[hid] ?? layer.blankBinding(forHID: hid)
                data[off] = hid
                data[off + 1] = b.function
                data[off + 2] = b.keyCodes[0]
                data[off + 3] = b.keyCodes[1]
                data[off + 4] = b.keyCodes[2]
                data[off + 5] = b.keyCodes[3]
                off += 6
            }
            chunks.append(data)
            index += keysPerChunk
        }
        return chunks
    }

    /// The read requests for a layer — one per chunk. Each carries the HID
    /// codes being asked about with zeroed payloads, exactly as
    /// `read_button_mappings` builds them.
    public static func readRequests(layer: Layer) -> [[UInt8]] {
        let order = layer.hidOrder
        var requests: [[UInt8]] = []
        var index = 0
        while index < order.count {
            let slice = order[index..<min(index + keysPerChunk, order.count)]
            var data = [UInt8](repeating: 0, count: featurePayloadSize)
            data[0] = readCommand
            data[1] = layer.rawValue
            data[2] = UInt8(slice.count)
            var off = 3
            for hid in slice {
                data[off] = hid
                off += 6
            }
            requests.append(data)
            index += keysPerChunk
        }
        return requests
    }

    /// Parse one read reply into HID → binding.
    ///
    /// Reply layout (macOS Feature buffer, report-ID byte excluded):
    /// `[0xB6][err][layer][count][ (hid, fn, kc×4) × count ]`. A leading
    /// report-ID byte is tolerated in case a transport surfaces it.
    ///
    /// Returns nil when the reply is not a well-formed answer for `layer`,
    /// including when the keyboard sets a non-zero error byte.
    /// - Parameter expectedCount: how many blocks the request asked for. The
    ///   device sometimes answers with a short frame; accepting it would look
    ///   like "these keys are all at default" when we simply were not told.
    public static func parseReadReply(_ reply: [UInt8], layer: Layer, expectedCount: Int? = nil) -> [UInt8: Binding]? {
        var bytes = reply
        if bytes.first == 0x00, bytes.count > 1, bytes[1] == readCommand { bytes.removeFirst() }
        guard bytes.count > readHeaderSize, bytes[0] == readCommand else { return nil }
        guard bytes[1] == 0 else { return nil }                 // error byte
        guard bytes[2] == layer.rawValue else { return nil }
        let count = Int(bytes[3])
        guard count > 0, bytes.count >= readHeaderSize + count * 6 else { return nil }
        if let expectedCount, count != expectedCount { return nil }

        var out: [UInt8: Binding] = [:]
        for i in 0..<count {
            let off = readHeaderSize + i * 6
            let hid = bytes[off]
            guard hid != 0 else { continue }
            out[hid] = Binding(function: bytes[off + 1], keyCodes: Array(bytes[(off + 2)...(off + 5)]))
        }
        return out
    }

    // MARK: - Meta (Fn) layer support

    /// Select which key toggles the meta/Fn layer.
    /// Wire (Output): `[0x35][hid]`.
    public static func metaToggle(hid: UInt8) -> [UInt8] { [metaToggleCommand, hid] }

    /// The 32-byte "this key has a meta binding" bitmask the firmware uses to
    /// light Fn-bound keys. Bit `hid & 7` of byte `hid / 8`.
    ///
    /// The firmware's rule: a key counts when its
    /// meta binding is not `unbound` **and** not a KEYBOARD mapping with no
    /// usages (the firmware's "soft unbound").
    public static func metaHighlightMask(metaBindings: [UInt8: Binding]) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: 32)
        for (hid, binding) in metaBindings {
            guard !binding.isDefault, !binding.isDisabled else { continue }
            let byte = Int(hid) / 8
            guard byte < mask.count else { continue }
            mask[byte] |= UInt8(1 << (Int(hid) & 7))
        }
        return mask
    }

    /// Wire (Output): `[0x3C][32-byte mask]`.
    public static func metaHighlight(metaBindings: [UInt8: Binding]) -> [UInt8] {
        [metaHighlightCommand] + metaHighlightMask(metaBindings: metaBindings)
    }
}

extension Mappings.Function: CustomStringConvertible {
    public var description: String { String(format: "0x%02X", rawValue) }
}
