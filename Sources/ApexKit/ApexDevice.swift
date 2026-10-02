import Foundation

/// High-level controller for the Apex Pro TKL Gen 3.
///
/// Wraps `HIDTransport` and the protocol builders into an ergonomic API:
/// lighting, actuation, rapid trigger, rapid tap, key mappings, OLED, profiles,
/// and queries. All reports use report ID 0. Feature reports carry bulk
/// payloads; Output reports carry short commands and query requests.
public final class ApexDevice: @unchecked Sendable {

    private let transport: HIDTransport

    /// Called on the HID thread when the keyboard connects (`true`) or
    /// disconnects (`false`).
    public var onConnectionChange: (@Sendable (Bool) -> Void)? {
        get { transport.onConnectionChange }
        set { transport.onConnectionChange = newValue }
    }

    public var isConnected: Bool { transport.isConnected }

    public init() {
        transport = HIDTransport(inputBufferSize: 64)
    }

    /// Begin matching/opening the keyboard.
    public func connect() throws {
        let match = HIDTransport.Match(
            vendorID: ApexProTKLGen3.vendorID,
            productID: ApexProTKLGen3.productID,
            usagePage: ApexProTKLGen3.usagePage,
            usage: ApexProTKLGen3.usage
        )
        try transport.start(match: match)
    }

    public func disconnect() {
        transport.stop()
    }

    // MARK: - Lighting

    /// Enable software direct-lighting mode (community-derived 0x4B init).
    public func enableDirectMode() throws {
        try transport.sendOutputReport(Queries.initDirectMode())
    }

    /// Set every addressable LED from a HID→color map (missing LEDs → black).
    public func setColors(_ map: [UInt8: LEDColor]) throws {
        try transport.sendFeatureReport(DirectLighting.frame(map))
    }

    /// Set an explicit ordered list of (LED, color) pairs.
    public func setColors(_ list: [(hid: UInt8, color: LEDColor)]) throws {
        try transport.sendFeatureReport(DirectLighting.directWrite(colors: list))
    }

    /// Solid color across all LEDs.
    public func setSolid(_ color: LEDColor) throws {
        try transport.sendFeatureReport(DirectLighting.solid(color))
    }

    /// Return control to the onboard lighting profile (clears direct mode).
    public func clearLighting() throws {
        try transport.sendOutputReport(DirectLighting.clearDirect())
    }

    // MARK: - Actuation & rapid trigger

    /// Set the primary actuation point. `perKeyLevel` maps HID → level (1…40,
    /// where level N ≈ N/10 mm); keys not listed use `defaultLevel`.
    public func setActuation(perKeyLevel: [UInt8: Int] = [:], defaultLevel: Int) throws {
        try transport.sendFeatureReport(Actuation.hallThresholds(perKeyLevel: perKeyLevel, defaultLevel: defaultLevel))
    }

    /// Set the optional second actuation point (dual bind). Keys absent from the
    /// map, or mapped to nil, have no second actuation point.
    public func setSecondActuation(perKeyLevel: [UInt8: Int?]) throws {
        try transport.sendFeatureReport(Actuation.secondActuation(perKeyLevel: perKeyLevel))
    }

    /// Set the rapid-trigger release mode per key.
    public func setRapidTriggerMode(perKeyMode: [UInt8: Actuation.ReleaseMode], defaultMode: Actuation.ReleaseMode = .off) throws {
        try transport.sendFeatureReport(Actuation.releaseMode(perKeyMode: perKeyMode, defaultMode: defaultMode))
    }

    /// Set rapid-trigger sensitivity per key (0.1 mm units; default 2).
    public func setRapidTriggerSensitivity(perKey: [UInt8: UInt8], defaultSensitivity: UInt8 = 2) throws {
        try transport.sendFeatureReport(Actuation.rapidTriggerSensitivity(perKey: perKey, defaultSensitivity: defaultSensitivity))
    }

    // MARK: - Rapid tap (SOCD)

    public func setRapidTapEnabled(_ enabled: Bool) throws {
        try transport.sendOutputReport(Actuation.rapidTapEnable(enabled))
    }

    public func setRapidTapPairs(_ pairs: [Actuation.RapidTapPair]) throws {
        try transport.sendOutputReport(Actuation.rapidTapPairs(pairs))
    }

    // MARK: - Key mappings (PRD-01 / 02 / 03)

    /// Write one mapping layer. The frame is always complete for that layer, so
    /// keys absent from `bindings` are reset to the layer's blank (`Layer.blankBinding`).
    public func writeMappings(layer: Mappings.Layer, bindings: [UInt8: Mappings.Binding]) throws {
        for chunk in Mappings.writeChunks(layer: layer, bindings: bindings) {
            try transport.sendFeatureReport(chunk)
        }
    }

    /// Read a mapping layer back off the keyboard.
    ///
    /// Mirrors `read_button_mappings`: write the request (`0xB6`) as a Feature
    /// report, then read the reply as a Feature report.
    ///
    /// Firmware 1.19.7 answers this **intermittently** — see
    /// `docs/PROTOCOL.md` §"Reading bindings back". The request is always
    /// acknowledged (the reply echoes the layer and count), but the payload is
    /// only filled in some of the time; otherwise the error byte is 1 and no
    /// blocks come back. Hence the retries, and hence every caller must cope
    /// with this throwing.
    public func readMappings(layer: Mappings.Layer, attempts: Int = 4) throws -> [UInt8: Mappings.Binding] {
        var lastError: Error = HIDError.malformedReply
        for attempt in 0..<max(1, attempts) {
            do { return try readMappingsOnce(layer: layer) }
            catch {
                lastError = error
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        throw lastError
    }

    private func readMappingsOnce(layer: Mappings.Layer) throws -> [UInt8: Mappings.Binding] {
        var out: [UInt8: Mappings.Binding] = [:]
        for request in Mappings.readRequests(layer: layer) {
            let expected = Int(request[2])
            let reply = try transport.queryFeature(request, responseLength: Mappings.featurePayloadSize)
            guard let parsed = Mappings.parseReadReply(reply, layer: layer, expectedCount: expected) else {
                throw HIDError.malformedReply
            }
            out.merge(parsed) { _, new in new }
        }
        guard out.count == layer.hidOrder.count else { throw HIDError.malformedReply }
        return out
    }

    /// Choose which key toggles the meta/Fn layer (`meta_toggle_hid`, `0x35`).
    public func setMetaToggleKey(hid: UInt8) throws {
        try transport.sendOutputReport(Mappings.metaToggle(hid: hid))
    }

    /// Tell the firmware which keys carry an Fn binding, so it can highlight
    /// them (`0x3C` + 32-byte bitmask).
    public func setMetaHighlight(metaBindings: [UInt8: Mappings.Binding]) throws {
        try transport.sendOutputReport(Mappings.metaHighlight(metaBindings: metaBindings))
    }

    /// Apply a complete binding set in a fixed order: normal layer,
    /// meta layer, second-actuation layer, then the meta-highlight bitmask.
    ///
    /// Macro data (`0x37`) is not written here; with no macros defined there is
    /// nothing to send (PRD-04 will add it).
    public func applyBindings(
        normal: [UInt8: Mappings.Binding],
        meta: [UInt8: Mappings.Binding] = [:],
        secondActuation: [UInt8: Mappings.Binding] = [:],
        metaToggleHID: UInt8? = nil
    ) throws {
        try writeMappings(layer: .normal, bindings: normal)
        try writeMappings(layer: .meta, bindings: meta)
        try writeMappings(layer: .secondActuation, bindings: secondActuation)
        if let metaToggleHID { try setMetaToggleKey(hid: metaToggleHID) }
        try setMetaHighlight(metaBindings: meta)
    }

    /// Restore the normal and second-actuation layers to factory behaviour —
    /// the escape hatch for a keyboard someone has remapped into unusability.
    ///
    /// The **Fn layer is untouched**. It ships populated with the keyboard's own
    /// brightness / media / OLED shortcuts (function `0x62` with a payload we
    /// know of no command to restore), so blanking it would erase them. Pass
    /// `includingFnLayer: true` only when the caller means exactly that.
    public func resetAllBindings(includingFnLayer: Bool = false) throws {
        try writeMappings(layer: .normal, bindings: [:])
        try writeMappings(layer: .secondActuation, bindings: [:])
        if includingFnLayer {
            try writeMappings(layer: .meta, bindings: [:])
            try setMetaHighlight(metaBindings: [:])
        }
    }

    // MARK: - Onboard profiles

    /// Switch the active onboard profile slot (`load_profile`, `0xB2`).
    public func loadProfile(slot: UInt8) throws {
        guard slot < 5 else { throw ApexError.invalidProfileSlot(slot) }
        try transport.sendOutputReport(Queries.loadProfile(slot))
    }

    /// `set_profile_volatile` (`0x34`). Confirmed on hardware (fw 1.19.7):
    /// **neither** argument makes live config writes reach flash — persistence
    /// only happens through `writeOnboardProfile`.
    public func setProfileVolatile(_ volatile: Bool) throws {
        try transport.sendOutputReport(Queries.setProfileVolatile(volatile))
    }

    /// Read a slot's flash image — the exact bytes the keyboard will boot from.
    ///
    /// Chunked Feature queries (`0x83`), retried per chunk; the assembled image
    /// is CRC- and schema-validated, so a successful return is a faithful,
    /// bootable snapshot. ~1 s of bus traffic.
    public func readOnboardProfile(slot: UInt8) throws -> OnboardProfile.Image {
        guard slot < OnboardProfile.slotCount else { throw ApexError.invalidProfileSlot(slot) }
        var image = [UInt8]()
        image.reserveCapacity(OnboardProfile.Layout.imageSize)
        var offset = 0
        while image.count < OnboardProfile.Layout.imageSize {
            let request = OnboardProfile.readChunkRequest(slot: slot, offset: offset)
            var lastError: Error = HIDError.malformedReply
            var chunk: ArraySlice<UInt8>?
            for attempt in 0..<4 {
                do {
                    let reply = try transport.queryFeature(
                        request, responseLength: OnboardProfile.featurePayloadSize,
                        settleTime: OnboardProfile.interChunkDelay)
                    guard reply.count >= OnboardProfile.readReplyHeaderSize + OnboardProfile.chunkSize,
                          reply[0] == OnboardProfile.readCommand, reply[1] == 0 else {
                        throw HIDError.malformedReply
                    }
                    chunk = reply[OnboardProfile.readReplyHeaderSize
                        ..< (OnboardProfile.readReplyHeaderSize + OnboardProfile.chunkSize)]
                    break
                } catch {
                    lastError = error
                    if attempt < 3 { Thread.sleep(forTimeInterval: 0.05) }
                }
            }
            guard let chunk else { throw lastError }
            image.append(contentsOf: chunk)
            offset += OnboardProfile.chunkSize
        }
        return try OnboardProfile.Image(validating: Array(image.prefix(OnboardProfile.Layout.imageSize)))
    }

    /// Write a slot's flash image — the only operation that makes settings
    /// survive a power cycle.
    ///
    /// The procedure for schema 8: seal the CRC,
    /// erase the flash entry (`0x02`, acknowledged when the erase finishes),
    /// stream the chunks (`0x03`, paced), then ask the firmware to
    /// validate (`0xB1`). With `verify` on (the default) the image is read back
    /// and compared byte-for-byte, so "written" means *proven on the keyboard*,
    /// not "sent". Takes a few seconds; do not stream lighting concurrently.
    public func writeOnboardProfile(_ image: OnboardProfile.Image, slot: UInt8,
                                    verify: Bool = true) throws {
        guard slot < OnboardProfile.slotCount else { throw ApexError.invalidProfileSlot(slot) }
        var sealed = image
        sealed.sealCRC()
        // Re-run the schema/size checks; a caller must not be able to flash
        // an image that would not validate as read.
        sealed = try OnboardProfile.Image(validating: sealed.bytes)

        // Erase. The reply only arrives once flash is actually clear.
        _ = try transport.query(OnboardProfile.eraseRequest(slot: slot),
                                timeout: OnboardProfile.eraseTimeout)

        for report in OnboardProfile.writeChunkReports(image: sealed, slot: slot) {
            try transport.sendFeatureReport(report)
            Thread.sleep(forTimeInterval: OnboardProfile.interChunkDelay)
        }

        // Firmware-side validation. The reply's contents are undocumented, so
        // a timeout here is not treated as fatal — the read-back below is the
        // authoritative check.
        _ = try? transport.query(OnboardProfile.validateRequest(slot: slot), timeout: 2.0)

        if verify {
            let readBack = try readOnboardProfile(slot: slot)
            guard readBack.bytes == sealed.bytes else {
                throw ApexError.onboardProfileVerifyFailed
            }
        }
    }

    // MARK: - OLED

    /// Live OLED write (volatile). Use for animated / frequently-updated content.
    public func showOLED(_ bitmap: MonoBitmap) throws {
        try transport.sendFeatureReport(OLED.liveWrite(bitmap))
    }

    /// Persist an image to the OLED (survives app exit).
    public func persistOLED(_ bitmap: MonoBitmap) throws {
        try transport.sendFeatureReport(OLED.persist(bitmap))
    }

    /// Hand the OLED back to firmware/onboard control.
    public func resetOLED() throws {
        try transport.sendOutputReport(OLED.resetDirect())
    }

    // MARK: - Queries

    public func firmwareVersion(timeout: TimeInterval = 1.0) throws -> String {
        let reply = try transport.query(Queries.firmwareVersionRequest(), timeout: timeout)
        return Queries.parseFirmware(reply) ?? "unknown"
    }

    public func region(timeout: TimeInterval = 1.0) throws -> Queries.RegionInfo? {
        let reply = try transport.query(Queries.readRegionRequest(), timeout: timeout)
        return Queries.parseRegion(reply)
    }

    public func layout(timeout: TimeInterval = 1.0) throws -> KeyboardLayout? {
        let reply = try transport.query(Queries.readLayoutRequest(), timeout: timeout)
        guard let raw = Queries.parseLayout(reply) else { return nil }
        return KeyboardLayout(rawValue: raw)
    }

    // MARK: - Raw escape hatch (for experimentation / verification)

    public func sendRawFeature(_ data: [UInt8]) throws { try transport.sendFeatureReport(data) }
    public func sendRawOutput(_ data: [UInt8]) throws { try transport.sendOutputReport(data) }
    public func readRawFeature(length: Int) throws -> [UInt8] { try transport.getFeatureReport(length: length) }
}

public enum ApexError: Error, CustomStringConvertible, Sendable {
    case invalidProfileSlot(UInt8)
    case notMappable(UInt8)
    /// The flash image uses a schema this build does not understand. Writing
    /// anyway could brick the profile, so both read and write refuse.
    case onboardProfileUnsupported(String)
    /// The flash image failed its own CRC or size checks.
    case onboardProfileCorrupt(String)
    /// A flash write did not read back byte-for-byte.
    case onboardProfileVerifyFailed

    public var description: String {
        switch self {
        case .invalidProfileSlot(let s): return "Onboard profile slot \(s) is out of range (0…4)"
        case .notMappable(let hid): return String(format: "Key 0x%02X cannot be rebound", hid)
        case .onboardProfileUnsupported(let why): return "Onboard profile not supported: \(why)"
        case .onboardProfileCorrupt(let why): return "Onboard profile unreadable: \(why)"
        case .onboardProfileVerifyFailed: return "The keyboard's flash did not read back what was written"
        }
    }
}

extension ApexError: LocalizedError {
    public var errorDescription: String? { description }
}
