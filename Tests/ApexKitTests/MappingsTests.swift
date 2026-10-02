import XCTest
@testable import ApexKit

/// Framing tests for the button-mapping protocol (PRD-01/02/03).
///
/// Ground truth is docs/PROTOCOL.md: a write is `[report-id][0x36][layer][count][blocks]`
/// and a read the same with `0xB6`; each block is 6 bytes,
/// `{ hid_code, function, key_codes[4] }`.
final class MappingsTests: XCTestCase {

    // MARK: - Write framing

    func testWriteFrameHeaderAndSize() {
        let chunks = Mappings.writeChunks(layer: .normal, bindings: [:])
        XCTAssertEqual(chunks.count, 1, "91 keys fit in one 644-byte feature report")
        let data = chunks[0]
        XCTAssertEqual(data.count, 644)
        XCTAssertEqual(data[0], 0x36)                                  // command
        XCTAssertEqual(data[1], 0x00)                                  // layer
        XCTAssertEqual(data[2], UInt8(ApexProTKLGen3.mappingBlockCount)) // 91
    }

    /// An unconfigured key on the normal layer must be written as the state the
    /// hardware actually rests in — KEYBOARD with the key's own usage — not as
    /// function 0. Confirmed by reading an unmodified keyboard back:
    /// `04 51 04 00 00 00`, `05 51 05 00 00 00`, …
    func testWriteFrameIsCompleteAndRestoresSelfMappingOnNormalLayer() {
        let data = Mappings.writeChunks(layer: .normal, bindings: [:])[0]
        let order = ApexProTKLGen3.mappableHIDOrder
        for (i, hid) in order.enumerated() {
            let off = 3 + i * 6
            XCTAssertEqual(data[off], hid, "block \(i) should address HID \(hid)")
            XCTAssertEqual(data[off + 1], 0x51, "unconfigured keys map to KEYBOARD")
            XCTAssertEqual(data[off + 2], hid, "…with their own usage")
            XCTAssertEqual(Array(data[(off + 3)...(off + 5)]), [0, 0, 0])
        }
        // Everything after the last block is padding.
        XCTAssertTrue(data[(3 + order.count * 6)...].allSatisfy { $0 == 0 })
    }

    /// The meta and second-actuation layers must stay blank instead — a
    /// self-mapping there would make every key fire itself on the Fn layer.
    func testOverlayLayersBlankToUnbound() {
        for layer in [Mappings.Layer.meta, .secondActuation] {
            let data = Mappings.writeChunks(layer: layer, bindings: [:])[0]
            for (i, hid) in layer.hidOrder.enumerated() {
                let off = 3 + i * 6
                XCTAssertEqual(data[off], hid)
                XCTAssertEqual(data[off + 1], 0x00, "\(layer.displayName) blanks must be UNBOUND")
            }
            XCTAssertEqual(layer.blankBinding(forHID: 0x04), .unbound)
        }
        XCTAssertEqual(Mappings.Layer.normal.blankBinding(forHID: 0x04), .keyboard(usage: 0x04))
    }

    func testWriteFrameCarriesBinding() {
        // Caps Lock (0x39) → Left Ctrl.
        let data = Mappings.writeChunks(layer: .normal, bindings: [0x39: .keyboard(usage: HIDUsage.leftControl)])[0]
        let index = ApexProTKLGen3.mappableHIDOrder.firstIndex(of: 0x39)!
        let off = 3 + index * 6
        XCTAssertEqual(data[off], 0x39)
        XCTAssertEqual(data[off + 1], 0x51)            // KEYBOARD
        XCTAssertEqual(data[off + 2], 0xE0)            // Left Ctrl usage
        XCTAssertEqual(Array(data[(off + 3)...(off + 5)]), [0, 0, 0])
    }

    func testSecondActuationLayerUsesAnalogKeysOnly() {
        let chunks = Mappings.writeChunks(layer: .secondActuation, bindings: [:])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0][1], 0x02)
        XCTAssertEqual(chunks[0][2], 68)
        XCTAssertEqual(chunks[0][3], ApexProTKLGen3.analogHIDOrder[0])
    }

    func testMetaLayerUsesLayerByte1() {
        XCTAssertEqual(Mappings.writeChunks(layer: .meta, bindings: [:])[0][1], 0x01)
    }

    func testKeysPerChunkMatchesDescriptorFormula() {
        // (feature-report-size − 5) / 6, feature-report-size = 645.
        XCTAssertEqual(Mappings.keysPerChunk, 106)
        XCTAssertLessThanOrEqual(ApexProTKLGen3.mappingBlockCount, Mappings.keysPerChunk)
    }

    // MARK: - Read framing & parsing

    func testReadRequestFraming() {
        let requests = Mappings.readRequests(layer: .normal)
        XCTAssertEqual(requests.count, 1)
        let r = requests[0]
        XCTAssertEqual(r.count, 644)
        XCTAssertEqual(r[0], 0xB6)
        XCTAssertEqual(r[1], 0x00)
        XCTAssertEqual(r[2], 91)
        // Each block is the HID code with a zeroed payload for the device to fill.
        for (i, hid) in ApexProTKLGen3.mappableHIDOrder.enumerated() {
            XCTAssertEqual(r[3 + i * 6], hid)
            XCTAssertEqual(Array(r[(3 + i * 6 + 1)...(3 + i * 6 + 5)]), [0, 0, 0, 0, 0])
        }
    }

    /// Build the reply the firmware would send for a set of bindings:
    /// `[0xB6][err][layer][count][blocks]` — the error byte comes *before* the
    /// layer, confirmed on hardware by a request with no block list answering
    /// `B6 01 00 5B`. Worth stating exactly, because the obvious reading of the
    /// descriptor puts it last and that mistake decodes every field wrong.
    private func syntheticReply(layer: Mappings.Layer,
                                bindings: [UInt8: Mappings.Binding],
                                includeReportID: Bool = false) -> [UInt8] {
        let order = layer.hidOrder
        var data = [UInt8](repeating: 0, count: 644)
        data[0] = 0xB6
        data[1] = 0                                    // error byte
        data[2] = layer.rawValue
        data[3] = UInt8(order.count)
        for (i, hid) in order.enumerated() {
            let b = bindings[hid] ?? .unbound
            let off = 4 + i * 6
            data[off] = hid
            data[off + 1] = b.function
            for k in 0..<4 { data[off + 2 + k] = b.keyCodes[k] }
        }
        return includeReportID ? [0x00] + data : data
    }

    func testParseReadReply() {
        let expected: [UInt8: Mappings.Binding] = [
            0x39: .keyboard(usage: HIDUsage.leftControl),
            0x2C: .consumer(.playPause),
            0x14: .disabled,
        ]
        let parsed = Mappings.parseReadReply(syntheticReply(layer: .normal, bindings: expected), layer: .normal)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, ApexProTKLGen3.mappingBlockCount)
        XCTAssertEqual(parsed?[0x39], expected[0x39])
        XCTAssertEqual(parsed?[0x2C], expected[0x2C])
        XCTAssertEqual(parsed?[0x14], expected[0x14])
        XCTAssertEqual(parsed?[0x04], .unbound)
    }

    func testParseTolerateLeadingReportID() {
        let reply = syntheticReply(layer: .meta, bindings: [0x04: .mouse(.button4)], includeReportID: true)
        let parsed = Mappings.parseReadReply(reply, layer: .meta)
        XCTAssertEqual(parsed?[0x04], .mouse(.button4))
    }

    func testParseRejectsWrongCommandLayerOrTruncation() {
        var wrongCommand = syntheticReply(layer: .normal, bindings: [:])
        wrongCommand[0] = 0x40
        XCTAssertNil(Mappings.parseReadReply(wrongCommand, layer: .normal))

        let wrongLayer = syntheticReply(layer: .meta, bindings: [:])
        XCTAssertNil(Mappings.parseReadReply(wrongLayer, layer: .normal))

        let truncated = Array(syntheticReply(layer: .normal, bindings: [:]).prefix(20))
        XCTAssertNil(Mappings.parseReadReply(truncated, layer: .normal))

        XCTAssertNil(Mappings.parseReadReply([], layer: .normal))

        var errorByte = syntheticReply(layer: .normal, bindings: [:])
        errorByte[1] = 1
        XCTAssertNil(Mappings.parseReadReply(errorByte, layer: .normal), "a non-zero error byte is not data")
    }

    /// The device sometimes answers with fewer blocks than asked for. Accepting
    /// a short frame would read as "those keys are at default" when we simply
    /// were not told about them.
    func testParseRejectsShortFrameWhenCountIsKnown() {
        var short = syntheticReply(layer: .secondActuation, bindings: [:])
        short[3] = 10                                   // device reports 10 of 68
        XCTAssertNotNil(Mappings.parseReadReply(short, layer: .secondActuation))
        XCTAssertNil(Mappings.parseReadReply(short, layer: .secondActuation, expectedCount: 68))
    }

    /// The bytes we write and the bytes we parse must describe the same thing —
    /// this is the offline half of PRD-01 AC-4's round-trip.
    func testWriteThenParseRoundTrip() {
        let bindings: [UInt8: Mappings.Binding] = [
            0x39: .keyboard(usages: [HIDUsage.leftGUI, HIDUsage.leftShift, 0x21]),  // Cmd+Shift+4
            0xF0: .consumer(.mute),
            0x45: .mouse(.wheelDown),
            0x29: .disabled,
        ]
        let written = Mappings.writeChunks(layer: .normal, bindings: bindings)[0]
        // Convert the write frame into the reply shape: same blocks, one more
        // header byte for the error code.
        let reply: [UInt8] = [0xB6, 0x00, written[1], written[2]] + Array(written.dropFirst(3))
        let parsed = Mappings.parseReadReply(reply, layer: .normal)
        for (hid, binding) in bindings {
            XCTAssertEqual(parsed?[hid], binding, "round-trip mismatch for HID \(hid)")
        }
    }

    // MARK: - Binding semantics

    func testUnboundIsFactoryDefaultNotDisabled() {
        // `function 0` means "no override", so it cannot also mean "dead key".
        XCTAssertTrue(Mappings.Binding.unbound.isDefault)
        XCTAssertFalse(Mappings.Binding.unbound.isDisabled)
        XCTAssertEqual(Mappings.Binding.unbound.function, 0x00)
        XCTAssertEqual(Mappings.Binding.unbound.summary, "Default")
    }

    func testDisabledIsKeyboardWithNoUsages() {
        // A dead key is KEYBOARD with no usages, not `function 0`.
        XCTAssertEqual(Mappings.Binding.disabled.function, 0x51)
        XCTAssertEqual(Mappings.Binding.disabled.keyCodes, [0, 0, 0, 0])
        XCTAssertTrue(Mappings.Binding.disabled.isDisabled)
        XCTAssertFalse(Mappings.Binding.disabled.isDefault)
    }

    func testKeyboardPutsModifiersFirstAndCapsAtFour() {
        // Modifiers lead, in Mac reading order ⌃⌥⇧⌘, and the base key ends the
        // list. The order is fixed rather than as-supplied so that the same
        // chord always writes the same four bytes: the read-back comparison and
        // profile equality both depend on it.
        let b = Mappings.Binding.keyboard(usages: [0x21, HIDUsage.leftGUI, HIDUsage.leftShift])
        XCTAssertEqual(b.keyCodes[0], HIDUsage.leftShift)
        XCTAssertEqual(b.keyCodes[1], HIDUsage.leftGUI)
        XCTAssertEqual(b.keyCodes[2], 0x21)
        XCTAssertEqual(b.keyCodes[3], 0)

        // The same chord, given in a different order, writes the same bytes.
        let same = Mappings.Binding.keyboard(usages: [HIDUsage.leftShift, 0x21, HIDUsage.leftGUI])
        XCTAssertEqual(same, b)

        let overflow = Mappings.Binding.keyboard(usages: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(overflow.keyCodes.count, 4)
    }

    func testKeyboardDeduplicatesRepeatedUsages() {
        // The resting state of a modifier key is a mapping to itself, so the
        // editor could easily hand the same usage in twice. Writing
        // `E1 E1 00 00` would be a nonsense the firmware has no reason to honour.
        let b = Mappings.Binding.keyboard(usages: [HIDUsage.leftShift, HIDUsage.leftShift])
        XCTAssertEqual(b.keyCodes, [HIDUsage.leftShift, 0, 0, 0])
    }

    func testConsumerIsLittleEndianUInt16() {
        // Verified codes: the factory bindings of the keyboard's own media buttons.
        XCTAssertEqual(Mappings.Binding.consumer(.playPause).keyCodes, [205, 0, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(.nextTrack).keyCodes, [181, 0, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(.previousTrack).keyCodes, [182, 0, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(.mute).keyCodes, [226, 0, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(.volumeUp).keyCodes, [233, 0, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(.volumeDown).keyCodes, [234, 0, 0, 0])
        // Two-byte usage stays little-endian.
        XCTAssertEqual(Mappings.Binding.consumer(0x0223).keyCodes, [0x23, 0x02, 0, 0])
        XCTAssertEqual(Mappings.Binding.consumer(0x0223).consumerUsage, 0x0223)
    }

    func testMouseFunctionsMatchDescriptorValues() {
        XCTAssertEqual(Mappings.Binding.mouse(.button1).function, 0x01)
        XCTAssertEqual(Mappings.Binding.mouse(.button8).function, 0x08)
        XCTAssertEqual(Mappings.Binding.mouse(.wheelUp).function, 0x31)
        XCTAssertEqual(Mappings.Binding.mouse(.wheelDown).function, 0x32)
        XCTAssertEqual(Mappings.Binding.mouse(.panLeft).function, 0x33)
        XCTAssertEqual(Mappings.Binding.mouse(.panRight).function, 0x34)
        XCTAssertEqual(Mappings.Binding.mouse(button: 99).function, 0x08, "clamped to the 1…8 range")
        XCTAssertEqual(Mappings.Binding.mouse(button: 0).function, 0x01)
    }

    func testUnknownFunctionSurvivesRoundTrip() {
        // A value the firmware documents but we don't model must not be lost.
        let raw = Mappings.Binding(function: 0x71, keyCodes: [3])
        XCTAssertEqual(raw.knownFunction, .macro)
        let mystery = Mappings.Binding(function: 0x99, keyCodes: [1, 2, 3, 4])
        XCTAssertNil(mystery.knownFunction)
        XCTAssertEqual(mystery.summary, "Function 0x99")
    }

    /// `0x62` is not "make this the Fn key" — a stock keyboard reports nine of
    /// them on the Fn layer with distinct payloads (the SteelSeries-key
    /// brightness / media / OLED shortcuts). We must round-trip them untouched.
    func testFirmwareFunctionRoundTripsWithItsPayload() {
        let observed: [(UInt8, [UInt8])] = [
            (0x42, [0x01, 0x00]),      // F9
            (0x43, [0x02, 0x01]),      // F10
            (0x44, [0x03, 0x01]),      // F11
            (0x45, [0x04, 0x01]),      // F12
            (0xE3, [0x05, 0x00]),      // Left Cmd
            (0x12, [0x06, 0x00]),      // O
            (0x0C, [0x07, 0x00]),      // I
            (0x17, [0x08, 0x00]),      // T
            (0x14, [0x0A, 0x00]),      // Q
        ]
        var bindings: [UInt8: Mappings.Binding] = [:]
        for (hid, payload) in observed {
            bindings[hid] = Mappings.Binding(function: Mappings.Function.meta.rawValue, keyCodes: payload)
        }
        let written = Mappings.writeChunks(layer: .meta, bindings: bindings)[0]
        for (hid, payload) in observed {
            let index = Mappings.Layer.meta.hidOrder.firstIndex(of: hid)!
            let off = 3 + index * 6
            XCTAssertEqual(written[off], hid)
            XCTAssertEqual(written[off + 1], 0x62)
            XCTAssertEqual(written[off + 2], payload[0])
            XCTAssertEqual(written[off + 3], payload[1])
        }
        XCTAssertEqual(Mappings.Binding.firmwareFunction(id: 2, page: 1).summary, "Firmware function 1.2")
        XCTAssertEqual(Mappings.Binding.firmwareFunction(id: 5).summary, "Firmware function 5")
    }

    // MARK: - Meta (Fn) layer

    func testMetaToggleFraming() {
        XCTAssertEqual(Mappings.metaToggle(hid: 0xF0), [0x35, 0xF0])
    }

    func testMetaHighlightMaskBitPositions() {
        // The highlight mask is a bitmap over HID usages: byte = hid/8, bit = hid & 7.
        let mask = Mappings.metaHighlightMask(metaBindings: [
            0x04: .keyboard(usage: 0x3A),     // byte 0, bit 4
            0xF0: .consumer(.mute),           // byte 30, bit 0
        ])
        XCTAssertEqual(mask.count, 32)
        XCTAssertEqual(mask[0], 1 << 4)
        XCTAssertEqual(mask[30], 1 << 0)
        XCTAssertEqual(mask.reduce(0) { $0 + Int($1.nonzeroBitCount) }, 2)
    }

    func testMetaHighlightIgnoresUnboundAndSoftUnbound() {
        let mask = Mappings.metaHighlightMask(metaBindings: [
            0x04: .unbound,
            0x05: .disabled,      // KEYBOARD with zero key codes — the "soft unbound"
        ])
        XCTAssertTrue(mask.allSatisfy { $0 == 0 })
    }

    func testMetaHighlightOutputFraming() {
        let packet = Mappings.metaHighlight(metaBindings: [0x04: .keyboard(usage: 0x3A)])
        XCTAssertEqual(packet.count, 33)
        XCTAssertEqual(packet[0], 0x3C)
        XCTAssertLessThanOrEqual(packet.count, Mappings.outputPayloadSize)
    }
}
