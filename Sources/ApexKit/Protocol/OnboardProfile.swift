import Foundation

/// Onboard-profile persistence for the Apex Pro TKL Gen 3 — the flash image the
/// keyboard boots from.
///
/// Layout: from descriptor (schema 8), confirmed on hardware (fw 1.19.7): a
/// slot-0 read parses exactly as laid out here and its stored CRC matches
/// `stm32CRC` over the preceding 12 320 bytes.
///
/// **Why this exists:** every live configuration command — `0x36` bindings,
/// `0x38 61` actuation, `0x38 66/67` rapid tap, `0x35` meta toggle — writes
/// keyboard **RAM only**. Verified on hardware: after a `0x36` write the flash
/// image is unchanged, with `set_profile_volatile` (`0x34`) at either value.
/// At power-up the firmware loads this flash image, so anything not written
/// here is silently lost when the keyboard loses power, so persisting
/// means rewriting the whole image.
///
/// The pipeline:
///
///  1. erase the profile's flash-filesystem entry — Output `02 01 <fs>`, then
///     wait for the Input-report acknowledgement (the erase is slow),
///  2. write the image in 500-byte chunks — Feature
///     `03 01 <fs> <size u16 LE> <offset u32 LE> <data>`, ~13 ms apart
///     (the pacing that works on hardware), padded with `0xFF`,
///  3. ask the firmware to validate the slot — Output `B1 <slot>`, await Input.
///
/// Reads are Feature queries: SET_REPORT `83 01 <fs> <size u16> <offset u32>`,
/// then GET_REPORT returns `83 <err> <data…>` (confirmed on hardware).
///
/// `<fs>` is `0x80 + slot`; slots 0…4.
public enum OnboardProfile {

    // MARK: - Wire constants

    public static let featurePayloadSize = 644
    /// Flash payload bytes per Feature report.
    public static let chunkSize = 500
    /// Flash-filesystem id of profile slot 0.
    public static let fsBase: UInt8 = 0x80

    public static let eraseCommand: UInt8 = 0x02
    public static let writeCommand: UInt8 = 0x03
    public static let readCommand: UInt8 = 0x83
    public static let validateCommand: UInt8 = 0xB1

    /// Flash-write chunks are paced about this far apart.
    public static let interChunkDelay: TimeInterval = 0.013
    /// The erase is slow: allow several seconds.
    public static let eraseTimeout: TimeInterval = 6.0

    public static let slotCount = 5

    // MARK: - Image layout (schema 3 / device schema 8, fw ≥ 1.19.0)

    /// Byte offsets into the flash image. The image is a 12 320-byte body
    /// followed by a 4-byte STM32 CRC — 12 324 bytes total.
    public enum Layout {
        public static let schema = 0                    // u32 LE, == 3
        public static let name = 4                      // 24 bytes, ASCII, 0-padded
        public static let lighting = 28                 // onboard lighting block, 48 bytes
        /// The Fn-highlight mask — the same 32-byte mask as command `0x3C`.
        public static let metaMask = 40
        public static let metaKey = 76                  // u32 LE — the Fn trigger HID
        /// Normal-layer bindings — 100 slots × 5 bytes (function + 4 key codes),
        /// indexed by firmware key slot (`ApexProTKLGen3.deviceKeyIndexToHID`).
        public static let normalMappings = 80
        public static let metaMappings = 580            // same shape, Fn layer
        public static let deviceSchema = 1080           // u32 LE, == 8
        public static let sensitivityH = 1084           // 70 bytes, primary actuation
        public static let sensitivityL = 1154           // 70 bytes
        public static let zoneLevels = 1224             // 3 × u32, onboard-only
        public static let zoneSubscriptions = 1236      // 70 bytes, onboard-only
        public static let maSensitivityH = 1306         // 70 bytes, second actuation
        public static let maSensitivityL = 1376         // 70 bytes
        public static let maReleaseMode = 1446          // 70 bytes, rapid trigger
        public static let maAdaptive = 1516             // 70 bytes, RT sensitivity (0.1 mm)
        public static let protectionDuration = 1586     // u32 LE, firmware default 500
        public static let protectionDistance = 1590     // 70 bytes, firmware default 20
        public static let maMappings = 1660             // 70 slots × 5 bytes
        public static let oled = 2010                   // 640 bytes, SSD1306 page-major
        public static let rapidTap = 2650               // 10 × 5-byte pairs + enable
        public static let macroEvents = 2704            // 9 600 bytes, opaque
        public static let guid = 12304                  // 16 bytes
        public static let crc = 12320                   // u32 LE, STM32 CRC of 0..<12320
        public static let imageSize = 12324

        public static let mappingSlotCount = 100        // length of deviceKeyIndexToHID
        public static let analogSlotCount = 70          // firmware analog-key slots
    }

    public static let expectedSchema: UInt32 = 3
    public static let expectedDeviceSchema: UInt32 = 8

    // MARK: - CRC

    /// STM32 hardware-CRC32: polynomial `0x04C11DB7`, init `0xFFFFFFFF`, no
    /// reflection, no final XOR, fed 32-bit little-endian words. Confirmed on
    /// hardware: reproduces the trailing CRC of a factory slot-0 image.
    /// `bytes.count` must be a multiple of 4 (the image body is 12 320 bytes).
    public static func stm32CRC<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        var word: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes {
            word |= UInt32(byte) << shift
            shift += 8
            guard shift == 32 else { continue }
            crc ^= word
            for _ in 0..<32 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
            word = 0
            shift = 0
        }
        return crc
    }

    // MARK: - Packet builders

    static func fsID(slot: UInt8) -> UInt8 { fsBase + slot }

    /// Output request that erases a slot's flash entry. The reply (an Input
    /// report) arrives when the erase has finished — up to seconds later.
    public static func eraseRequest(slot: UInt8) -> [UInt8] {
        [eraseCommand, 0x01, fsID(slot: slot)]
    }

    /// Output request asking the firmware to CRC-check the slot it just
    /// received. Answered with an Input report.
    public static func validateRequest(slot: UInt8) -> [UInt8] {
        [validateCommand, slot]
    }

    /// Feature request for one read chunk. The reply (GET_REPORT) is
    /// `[0x83][err][chunk bytes…]`.
    public static func readChunkRequest(slot: UInt8, offset: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: featurePayloadSize)
        data[0] = readCommand
        data[1] = 0x01
        data[2] = fsID(slot: slot)
        data[3] = UInt8(chunkSize & 0xFF)
        data[4] = UInt8(chunkSize >> 8)
        data[5] = UInt8(offset & 0xFF)
        data[6] = UInt8((offset >> 8) & 0xFF)
        data[7] = UInt8((offset >> 16) & 0xFF)
        data[8] = UInt8((offset >> 24) & 0xFF)
        return data
    }

    /// Byte offset of the chunk data in a read reply: `[0x83][err]`, then data.
    public static let readReplyHeaderSize = 2

    /// The Feature reports that write a complete image, in order. The payload
    /// is padded with `0xFF` to a whole number of chunks.
    public static func writeChunkReports(image: Image, slot: UInt8) -> [[UInt8]] {
        var padded = image.bytes
        let chunkCount = (Layout.imageSize + chunkSize - 1) / chunkSize
        padded.append(contentsOf: [UInt8](repeating: 0xFF, count: chunkCount * chunkSize - padded.count))

        var reports: [[UInt8]] = []
        for chunk in 0..<chunkCount {
            let offset = chunk * chunkSize
            var data = [UInt8](repeating: 0, count: featurePayloadSize)
            data[0] = writeCommand
            data[1] = 0x01
            data[2] = fsID(slot: slot)
            data[3] = UInt8(chunkSize & 0xFF)
            data[4] = UInt8(chunkSize >> 8)
            data[5] = UInt8(offset & 0xFF)
            data[6] = UInt8((offset >> 8) & 0xFF)
            data[7] = UInt8((offset >> 16) & 0xFF)
            data[8] = UInt8((offset >> 24) & 0xFF)
            data.replaceSubrange(9..<(9 + chunkSize), with: padded[offset..<(offset + chunkSize)])
            reports.append(data)
        }
        return reports
    }

    // MARK: - Image

    /// A complete onboard-profile flash image, with typed access to the fields
    /// this app owns. Everything it does not model — profile name, GUID,
    /// onboard lighting colours, zone settings, macros, the OLED bitmap — rides
    /// along untouched, which is why persisting is always read-modify-write.
    public struct Image: Equatable, Sendable {
        public var bytes: [UInt8]

        /// Wrap raw image bytes. Throws unless the size, schemas, and CRC all
        /// check out — an image that fails here must never be written back.
        public init(validating bytes: [UInt8]) throws {
            guard bytes.count == Layout.imageSize else {
                throw ApexError.onboardProfileCorrupt(
                    "image is \(bytes.count) bytes, expected \(Layout.imageSize)")
            }
            self.bytes = bytes
            guard schema == expectedSchema else {
                throw ApexError.onboardProfileUnsupported(
                    "profile schema \(schema), expected \(expectedSchema)")
            }
            guard deviceSchema == expectedDeviceSchema else {
                throw ApexError.onboardProfileUnsupported(
                    "device schema \(deviceSchema), expected \(expectedDeviceSchema) (firmware ≥ 1.19.0)")
            }
            guard storedCRC == computedCRC else {
                throw ApexError.onboardProfileCorrupt(String(
                    format: "CRC mismatch: stored %08X, computed %08X", storedCRC, computedCRC))
            }
        }

        /// Wrap bytes without validating. For tests and for building fixtures.
        public init(unchecked bytes: [UInt8]) { self.bytes = bytes }

        // MARK: Scalars

        func u32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        mutating func setU32(_ value: UInt32, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        public var schema: UInt32 { u32(at: Layout.schema) }
        public var deviceSchema: UInt32 { u32(at: Layout.deviceSchema) }
        public var storedCRC: UInt32 { u32(at: Layout.crc) }
        public var computedCRC: UInt32 { OnboardProfile.stm32CRC(bytes[0..<Layout.crc]) }

        /// Recompute and store the CRC. Call after any patch, before writing.
        public mutating func sealCRC() { setU32(computedCRC, at: Layout.crc) }

        public var name: String {
            let raw = bytes[Layout.name..<(Layout.name + 24)].prefix { $0 != 0 }
            return String(decoding: raw, as: UTF8.self)
        }

        /// The key that activates the Fn/meta layer, or
        /// nil when the profile has none. Factory state is `0xF0`, the
        /// SteelSeries key.
        public var metaToggleHID: UInt8? {
            let value = u32(at: Layout.metaKey)
            return value == 0 ? nil : UInt8(truncatingIfNeeded: value)
        }

        public mutating func setMetaToggleHID(_ hid: UInt8?) {
            setU32(UInt32(hid ?? 0), at: Layout.metaKey)
        }

        // MARK: Bindings

        /// Image offset of a layer's mapping slot for a firmware key index.
        static func slotOffset(layer: Mappings.Layer, index: Int) -> Int? {
            switch layer {
            case .normal: return Layout.normalMappings + index * 5
            case .meta: return Layout.metaMappings + index * 5
            case .secondActuation:
                guard index < Layout.analogSlotCount else { return nil }
                return Layout.maMappings + index * 5
            }
        }

        /// A layer's bindings, keyed by HID code. Slots the firmware reserves
        /// (empty and media-button slots) are skipped.
        public func bindings(layer: Mappings.Layer) -> [UInt8: Mappings.Binding] {
            var out: [UInt8: Mappings.Binding] = [:]
            for (index, hid) in ApexProTKLGen3.deviceKeyIndexToHID.enumerated() {
                guard hid != 0, !ApexProTKLGen3.ignoredHIDCodes.contains(hid) else { continue }
                guard let offset = Image.slotOffset(layer: layer, index: index) else { continue }
                out[hid] = Mappings.Binding(
                    function: bytes[offset],
                    keyCodes: Array(bytes[(offset + 1)...(offset + 4)]))
            }
            return out
        }

        /// Replace a layer's user-rebindable slots with a **complete frame**
        /// (the same shape `Mappings.writeChunks` sends): every key the layer
        /// addresses must be present in `frame`; a key genuinely absent falls
        /// back to the layer's blank. Reserved slots — empty (`hid 0`) and the
        /// six hard-wired media buttons — are left exactly as read, as are the
        /// meta layer's slots for keys outside the frame.
        public mutating func setBindings(layer: Mappings.Layer, frame: [UInt8: Mappings.Binding]) {
            for (index, hid) in ApexProTKLGen3.deviceKeyIndexToHID.enumerated() {
                guard hid != 0, !ApexProTKLGen3.ignoredHIDCodes.contains(hid) else { continue }
                guard layer != .secondActuation || ApexProTKLGen3.analogHIDCodes.contains(hid) else { continue }
                guard let offset = Image.slotOffset(layer: layer, index: index) else { continue }
                let binding = frame[hid] ?? layer.blankBinding(forHID: hid)
                bytes[offset] = binding.function
                for i in 0..<4 { bytes[offset + 1 + i] = binding.keyCodes[i] }
            }
        }

        /// Update the Fn-highlight mask to match a
        /// meta-layer frame — the flash twin of Output command `0x3C`.
        public mutating func setMetaMask(metaBindings: [UInt8: Mappings.Binding]) {
            let mask = Mappings.metaHighlightMask(metaBindings: metaBindings)
            bytes.replaceSubrange(Layout.metaMask..<(Layout.metaMask + mask.count), with: mask)
        }

        // MARK: Analog per-key arrays

        /// Write one byte per analog key into a 70-byte firmware-slot array.
        /// Keys absent from `values` keep what the image already holds.
        mutating func setAnalogArray(at base: Int, values: [UInt8: UInt8]) {
            for (index, hid) in ApexProTKLGen3.deviceKeyIndexToHID.prefix(Layout.analogSlotCount).enumerated() {
                guard let value = values[hid] else { continue }
                bytes[base + index] = value
            }
        }

        /// Primary actuation thresholds, as raw Hall values (`h` and `l` per
        /// key) — the flash twin of `38 61 44 00`.
        public mutating func setActuation(perKeyHL: [UInt8: (h: UInt8, l: UInt8)]) {
            setAnalogArray(at: Layout.sensitivityH, values: perKeyHL.mapValues(\.h))
            setAnalogArray(at: Layout.sensitivityL, values: perKeyHL.mapValues(\.l))
        }

        /// Second-actuation thresholds — the flash twin of `38 61 44 02`.
        public mutating func setSecondActuation(perKeyHL: [UInt8: (h: UInt8, l: UInt8)]) {
            setAnalogArray(at: Layout.maSensitivityH, values: perKeyHL.mapValues(\.h))
            setAnalogArray(at: Layout.maSensitivityL, values: perKeyHL.mapValues(\.l))
        }

        /// Rapid-trigger release modes — the flash twin of `38 62 44`.
        public mutating func setReleaseModes(perKeyRawMode: [UInt8: UInt8]) {
            setAnalogArray(at: Layout.maReleaseMode, values: perKeyRawMode)
        }

        /// Rapid-trigger sensitivity (0.1 mm units) — the flash twin of `38 65 44`.
        public mutating func setRapidTriggerSensitivity(perKey: [UInt8: UInt8]) {
            setAnalogArray(at: Layout.maAdaptive, values: perKey)
        }

        /// One byte per analog key out of a 70-byte firmware-slot array.
        func analogArray(at base: Int) -> [UInt8: UInt8] {
            var out: [UInt8: UInt8] = [:]
            for (index, hid) in ApexProTKLGen3.deviceKeyIndexToHID.prefix(Layout.analogSlotCount).enumerated()
            where hid != 0 && !ApexProTKLGen3.ignoredHIDCodes.contains(hid) {
                out[hid] = bytes[base + index]
            }
            return out
        }

        // MARK: Seeding the app's configuration from flash

        /// The actuation/rapid-trigger configuration this image boots into.
        ///
        /// This exists so the app can *adopt* a keyboard's saved actuation
        /// instead of imposing its own defaults: the app has always pushed its
        /// config to RAM on connect, and now that it also persists, silently
        /// overwriting flash values the user set through other software or the keyboard's
        /// own OLED menu would make that loss permanent. Threshold pairs map
        /// back through `Actuation.level(forH:l:)`.
        public func actuationConfigSeed() -> ActuationConfig {
            var config = ActuationConfig()

            let h = analogArray(at: Layout.sensitivityH)
            let l = analogArray(at: Layout.sensitivityL)
            var levels: [UInt8: Int] = [:]
            for (hid, hv) in h {
                if let level = Actuation.level(forH: hv, l: l[hid] ?? 0) { levels[hid] = level }
            }
            let distinct = Set(levels.values)
            if distinct.count == 1, let only = distinct.first {
                config.globalLevel = only
            } else if !distinct.isEmpty {
                config.usePerKey = true
                config.perKey = HIDMap(levels)
                config.globalLevel = levels.values.mostCommon ?? config.globalLevel
            }

            let modes = analogArray(at: Layout.maReleaseMode)
            let enabledModes = modes.values.filter { $0 != 0 }
            if !enabledModes.isEmpty {
                config.releaseMode = enabledModes.mostCommon
                    .flatMap { Actuation.ReleaseMode(rawValue: $0) } ?? .rapidTrigger
                if enabledModes.count == modes.count {
                    config.rapidTrigger = true
                } else {
                    config.usePerKey = true
                    config.rapidTrigger = false
                    config.perKeyRapidTrigger = HIDMap(modes.mapValues { $0 != 0 })
                }
            }

            if let sensitivity = analogArray(at: Layout.maAdaptive).values.mostCommon {
                config.rapidTriggerSensitivity = sensitivity
            }

            let mh = analogArray(at: Layout.maSensitivityH)
            let ml = analogArray(at: Layout.maSensitivityL)
            var secondLevels: [UInt8: Int] = [:]
            for (hid, hv) in mh {
                if let level = Actuation.level(forH: hv, l: ml[hid] ?? 0) { secondLevels[hid] = level }
            }
            if !secondLevels.isEmpty {
                config.secondActuationEnabled = true
                config.perKeySecondActuation = HIDMap(secondLevels)
                config.secondActuationLevel = secondLevels.values.mostCommon ?? config.secondActuationLevel
            }
            return config
        }

        /// The rapid-tap (SOCD) configuration this image boots into.
        public func rapidTapConfigSeed() -> RapidTapConfig {
            var config = RapidTapConfig()
            var pairs: [RapidTapConfig.Pair] = []
            for slot in 0..<10 {
                let offset = Layout.rapidTap + slot * 5
                guard bytes[offset] != 0, bytes[offset + 1] != 0 else { continue }
                var pair = RapidTapConfig.Pair()
                pair.key1 = bytes[offset]
                pair.key2 = bytes[offset + 1]
                pair.mode = bytes[offset + 2] & 0x7F
                pair.reportBoth = bytes[offset + 2] & 0x80 != 0
                pairs.append(pair)
            }
            if !pairs.isEmpty { config.pairs = pairs }
            config.enabled = bytes[Layout.rapidTap + 50] != 0 && !pairs.isEmpty
            return config
        }

        // MARK: Rapid tap

        /// Rapid-tap pairs and master switch — the flash twin of `38 66`/`38 67`.
        /// Slots past `pairs.count` are zeroed, matching a `38 67` write.
        public mutating func setRapidTap(pairs: [Actuation.RapidTapPair], enabled: Bool) {
            for slot in 0..<10 {
                let offset = Layout.rapidTap + slot * 5
                if slot < pairs.count {
                    let p = pairs[slot]
                    bytes[offset] = p.hid1
                    bytes[offset + 1] = p.hid2
                    bytes[offset + 2] = p.mode | (p.reportBoth ? 0x80 : 0)
                } else {
                    bytes[offset] = 0
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 0
                }
                bytes[offset + 3] = 0
                bytes[offset + 4] = 0
            }
            bytes[Layout.rapidTap + 50] = enabled && !pairs.isEmpty ? 1 : 0
        }
    }
}

extension Collection where Element: Hashable {
    /// The most frequent element — for collapsing a per-key firmware array to
    /// the single value the app's "global" controls should display.
    var mostCommon: Element? {
        Dictionary(grouping: self) { $0 }.max { $0.value.count < $1.value.count }?.key
    }
}
