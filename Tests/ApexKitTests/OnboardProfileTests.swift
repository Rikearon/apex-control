import XCTest
@testable import ApexKit

/// The onboard-profile flash codec (PROTOCOL.md §Onboard profiles).
///
/// The layout and CRC here were verified against a real slot-0 image read off
/// hardware (fw 1.19.7): the parse produced the factory profile ("Config 1",
/// Fn key `0xF0`, nine `0x62` meta entries, six consumer media buttons) and
/// `stm32CRC` reproduced its trailing CRC. These tests pin that knowledge.
final class OnboardProfileTests: XCTestCase {

    // MARK: - Fixtures

    /// A structurally valid image: correct size, schemas, sealed CRC.
    private func blankImage() -> OnboardProfile.Image {
        var image = OnboardProfile.Image(
            unchecked: [UInt8](repeating: 0, count: OnboardProfile.Layout.imageSize))
        image.setU32(OnboardProfile.expectedSchema, at: OnboardProfile.Layout.schema)
        image.setU32(OnboardProfile.expectedDeviceSchema, at: OnboardProfile.Layout.deviceSchema)
        image.sealCRC()
        return image
    }

    private func slotIndex(forHID hid: UInt8) -> Int {
        ApexProTKLGen3.deviceKeyIndexToHID.firstIndex(of: hid)!
    }

    // MARK: - Layout

    func testLayoutOffsetsChain() {
        typealias L = OnboardProfile.Layout
        XCTAssertEqual(L.name, L.schema + 4)
        XCTAssertEqual(L.lighting, L.name + 24)
        XCTAssertEqual(L.metaMask, L.lighting + 12)          // brightness+color+hids+brightness+color
        XCTAssertEqual(L.metaKey, L.lighting + 48)
        XCTAssertEqual(L.normalMappings, L.metaKey + 4)
        XCTAssertEqual(L.metaMappings, L.normalMappings + L.mappingSlotCount * 5)
        XCTAssertEqual(L.deviceSchema, L.metaMappings + L.mappingSlotCount * 5)
        XCTAssertEqual(L.sensitivityH, L.deviceSchema + 4)
        XCTAssertEqual(L.sensitivityL, L.sensitivityH + L.analogSlotCount)
        XCTAssertEqual(L.zoneLevels, L.sensitivityL + L.analogSlotCount)
        XCTAssertEqual(L.zoneSubscriptions, L.zoneLevels + 12)
        XCTAssertEqual(L.maSensitivityH, L.zoneSubscriptions + L.analogSlotCount)
        XCTAssertEqual(L.maSensitivityL, L.maSensitivityH + L.analogSlotCount)
        XCTAssertEqual(L.maReleaseMode, L.maSensitivityL + L.analogSlotCount)
        XCTAssertEqual(L.maAdaptive, L.maReleaseMode + L.analogSlotCount)
        XCTAssertEqual(L.protectionDuration, L.maAdaptive + L.analogSlotCount)
        XCTAssertEqual(L.protectionDistance, L.protectionDuration + 4)
        XCTAssertEqual(L.maMappings, L.protectionDistance + L.analogSlotCount)
        XCTAssertEqual(L.oled, L.maMappings + L.analogSlotCount * 5)
        XCTAssertEqual(L.rapidTap, L.oled + 640)
        XCTAssertEqual(L.macroEvents, L.rapidTap + 51 + 3)   // rapid tap + padding
        XCTAssertEqual(L.guid, L.macroEvents + 9600)
        XCTAssertEqual(L.crc, L.guid + 16)
        XCTAssertEqual(L.imageSize, L.crc + 4)
        XCTAssertEqual(L.mappingSlotCount, ApexProTKLGen3.deviceKeyIndexToHID.count)
        XCTAssertEqual(L.analogSlotCount, ApexProTKLGen3.numFirmwareAnalogKeys)
    }

    // MARK: - CRC

    /// Vectors computed with the reference implementation that reproduced a
    /// real image's stored CRC on hardware.
    func testSTM32CRCVectors() {
        XCTAssertEqual(OnboardProfile.stm32CRC([0, 0, 0, 0]), 0xC704_DD7B)
        XCTAssertEqual(OnboardProfile.stm32CRC([0x01, 0x02, 0x03, 0x04]), 0x1DAB_E74F)
        XCTAssertEqual(OnboardProfile.stm32CRC(Array("ABCDEFGH".utf8)), 0x8DCB_FB33)
        XCTAssertEqual(
            OnboardProfile.stm32CRC([UInt8](repeating: 0xFF, count: 12320)), 0x908E_DE87)
    }

    func testSealCRCMakesImageValidate() throws {
        let image = blankImage()
        XCTAssertNoThrow(try OnboardProfile.Image(validating: image.bytes))
    }

    func testValidatingRejectsBadImages() {
        // Wrong size.
        XCTAssertThrowsError(try OnboardProfile.Image(validating: [0, 1, 2]))
        // Bad CRC.
        var corrupt = blankImage()
        corrupt.bytes[100] ^= 0xFF
        XCTAssertThrowsError(try OnboardProfile.Image(validating: corrupt.bytes))
        // Wrong profile schema.
        var wrongSchema = blankImage()
        wrongSchema.setU32(2, at: OnboardProfile.Layout.schema)
        wrongSchema.sealCRC()
        XCTAssertThrowsError(try OnboardProfile.Image(validating: wrongSchema.bytes))
        // Wrong device schema (older firmware) must refuse rather than patch.
        var wrongDevice = blankImage()
        wrongDevice.setU32(6, at: OnboardProfile.Layout.deviceSchema)
        wrongDevice.sealCRC()
        XCTAssertThrowsError(try OnboardProfile.Image(validating: wrongDevice.bytes))
    }

    // MARK: - Bindings

    func testBindingRoundTripByHID() {
        var image = blankImage()
        let frame: [UInt8: Mappings.Binding] = Dictionary(
            uniqueKeysWithValues: ApexProTKLGen3.mappableHIDOrder.map {
                ($0, Mappings.Layer.normal.blankBinding(forHID: $0))
            }
        ).merging([0xE6: .keyboard(usage: 0x35)]) { _, new in new }

        image.setBindings(layer: .normal, frame: frame)
        let parsed = image.bindings(layer: .normal)

        XCTAssertEqual(parsed.count, ApexProTKLGen3.mappableHIDOrder.count)
        XCTAssertEqual(parsed[0xE6], .keyboard(usage: 0x35))
        XCTAssertEqual(parsed[0x04], .keyboard(usage: 0x04))     // self-mapping blank
    }

    func testBindingSlotPlacementMatchesFirmwareTable() {
        // Right Alt (0xE6) sits at firmware slot 63 — the very binding whose
        // loss across power cycles motivated this codec.
        var image = blankImage()
        image.setBindings(layer: .normal, frame: [0xE6: .keyboard(usage: 0x35)])
        let offset = OnboardProfile.Layout.normalMappings + slotIndex(forHID: 0xE6) * 5
        XCTAssertEqual(Array(image.bytes[offset..<(offset + 5)]), [0x51, 0x35, 0x00, 0x00, 0x00])
    }

    func testReservedSlotsAreNeverTouched() {
        var image = blankImage()
        // Paint the reserved slots with a sentinel: the six media buttons and
        // the empty (hid 0) slots.
        var sentinelOffsets: [Int] = []
        for (index, hid) in ApexProTKLGen3.deviceKeyIndexToHID.enumerated()
        where hid == 0 || ApexProTKLGen3.ignoredHIDCodes.contains(hid) {
            let offset = OnboardProfile.Layout.normalMappings + index * 5
            for i in 0..<5 { image.bytes[offset + i] = 0xAB }
            sentinelOffsets.append(offset)
        }

        image.setBindings(layer: .normal, frame: [:])   // complete blank frame

        for offset in sentinelOffsets {
            XCTAssertEqual(Array(image.bytes[offset..<(offset + 5)]),
                           [0xAB, 0xAB, 0xAB, 0xAB, 0xAB],
                           "reserved slot at \(offset) must ride along untouched")
        }
        // While every real key was written (self-mapped).
        XCTAssertEqual(image.bindings(layer: .normal)[0x04], .keyboard(usage: 0x04))
    }

    func testSecondActuationOnlyTouchesAnalogSlots() {
        var image = blankImage()
        // Esc (0x29) is a mechanical key: firmware slot 70, outside the
        // 70-slot analog table. A second-actuation frame must not reach it.
        image.setBindings(layer: .secondActuation, frame: [0x04: .keyboard(usage: 0x05)])
        let parsed = image.bindings(layer: .secondActuation)
        XCTAssertEqual(parsed[0x04], .keyboard(usage: 0x05))
        XCTAssertNil(parsed[0x29])
        // And nothing may spill past the analog table into the OLED field.
        let end = OnboardProfile.Layout.maMappings + OnboardProfile.Layout.analogSlotCount * 5
        XCTAssertEqual(end, OnboardProfile.Layout.oled)
    }

    func testMetaMaskMatchesHighlightCommand() {
        var image = blankImage()
        let meta: [UInt8: Mappings.Binding] = [
            0x0C: .firmwareFunction(id: 7),
            0x42: .firmwareFunction(id: 1),
        ]
        image.setMetaMask(metaBindings: meta)
        let expected = Mappings.metaHighlightMask(metaBindings: meta)
        let stored = Array(image.bytes[OnboardProfile.Layout.metaMask
            ..< (OnboardProfile.Layout.metaMask + 32)])
        XCTAssertEqual(stored, expected)
    }

    func testMetaToggleRoundTrip() {
        var image = blankImage()
        XCTAssertNil(image.metaToggleHID)
        image.setMetaToggleHID(0xF0)
        XCTAssertEqual(image.metaToggleHID, 0xF0)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.metaKey], 0xF0)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.metaKey + 1], 0)
        image.setMetaToggleHID(nil)
        XCTAssertNil(image.metaToggleHID)
    }

    // MARK: - Actuation, rapid trigger, rapid tap

    func testActuationArraysArePlacedBySlot() {
        var image = blankImage()
        // `\`` (hid 53) is firmware slot 0; A (hid 4) is slot 29.
        image.setActuation(perKeyHL: [53: (h: 40, l: 37), 4: (h: 10, l: 8)])
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.sensitivityH + 0], 40)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.sensitivityL + 0], 37)
        let aSlot = slotIndex(forHID: 4)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.sensitivityH + aSlot], 10)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.sensitivityL + aSlot], 8)
    }

    func testRapidTriggerArrays() {
        var image = blankImage()
        image.setReleaseModes(perKeyRawMode: [4: 2])
        image.setRapidTriggerSensitivity(perKey: [4: 5])
        let aSlot = slotIndex(forHID: 4)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.maReleaseMode + aSlot], 2)
        XCTAssertEqual(image.bytes[OnboardProfile.Layout.maAdaptive + aSlot], 5)
    }

    func testRapidTapLayout() {
        var image = blankImage()
        // Stale garbage in a later slot must be cleared by a shorter list.
        image.bytes[OnboardProfile.Layout.rapidTap + 5] = 0x77
        image.setRapidTap(
            pairs: [Actuation.RapidTapPair(hid1: 4, hid2: 7, mode: 1, reportBoth: true)],
            enabled: true)
        let base = OnboardProfile.Layout.rapidTap
        XCTAssertEqual(Array(image.bytes[base..<(base + 5)]), [4, 7, 0x81, 0, 0])
        XCTAssertEqual(image.bytes[base + 5], 0, "unused pair slots must be zeroed")
        XCTAssertEqual(image.bytes[base + 50], 1, "enable byte lives after the ten pairs")
        image.setRapidTap(pairs: [], enabled: true)
        XCTAssertEqual(image.bytes[base + 50], 0, "no pairs means the enable must drop")
    }

    // MARK: - Reading configuration back out of an image

    func testLevelForHLInvertsTheCurve() {
        for level in Actuation.minLevel...Actuation.maxLevel {
            let hl = Actuation.hl(forLevel: level)
            XCTAssertEqual(Actuation.level(forH: hl.h, l: hl.l), level)
        }
        // Sentinels are "no point here", never a level.
        XCTAssertNil(Actuation.level(forH: 255, l: 255))
        XCTAssertNil(Actuation.level(forH: 0, l: 0))
        // An unknown pair snaps to the nearest actuation threshold.
        XCTAssertEqual(Actuation.level(forH: 41, l: 38), 18)
        XCTAssertEqual(Actuation.level(forH: 50, l: 46), 20)
    }

    func testActuationSeedUniformLevels() {
        var image = blankImage()
        var hl: [UInt8: (h: UInt8, l: UInt8)] = [:]
        for hid in ApexProTKLGen3.analogHIDOrder { hl[hid] = Actuation.hl(forLevel: 18) }
        image.setActuation(perKeyHL: hl)
        let seed = image.actuationConfigSeed()
        XCTAssertEqual(seed.globalLevel, 18)
        XCTAssertFalse(seed.usePerKey)
        XCTAssertFalse(seed.rapidTrigger)
        XCTAssertFalse(seed.secondActuationEnabled)
    }

    func testActuationSeedPerKeyAndRapidTrigger() {
        var image = blankImage()
        var hl: [UInt8: (h: UInt8, l: UInt8)] = [:]
        var modes: [UInt8: UInt8] = [:]
        var senses: [UInt8: UInt8] = [:]
        for hid in ApexProTKLGen3.analogHIDOrder {
            hl[hid] = Actuation.hl(forLevel: 20)
            modes[hid] = 2
            senses[hid] = 5
        }
        hl[0x04] = Actuation.hl(forLevel: 4)       // one key deviates
        image.setActuation(perKeyHL: hl)
        image.setReleaseModes(perKeyRawMode: modes)
        image.setRapidTriggerSensitivity(perKey: senses)
        image.setSecondActuation(perKeyHL: [0x04: Actuation.hl(forLevel: 32)])

        let seed = image.actuationConfigSeed()
        XCTAssertTrue(seed.usePerKey)
        XCTAssertEqual(seed.perKey[0x04], 4)
        XCTAssertEqual(seed.perKey[0x05], 20)
        XCTAssertTrue(seed.rapidTrigger)
        XCTAssertEqual(seed.releaseMode, .rapidTrigger)
        XCTAssertEqual(seed.rapidTriggerSensitivity, 5)
        XCTAssertTrue(seed.secondActuationEnabled)
        XCTAssertEqual(seed.perKeySecondActuation[0x04], 32)
        XCTAssertNil(seed.perKeySecondActuation[0x05])
    }

    func testRapidTapSeedRoundTrip() {
        var image = blankImage()
        image.setRapidTap(
            pairs: [Actuation.RapidTapPair(hid1: 4, hid2: 7, mode: 1, reportBoth: true)],
            enabled: true)
        let seed = image.rapidTapConfigSeed()
        XCTAssertTrue(seed.enabled)
        XCTAssertEqual(seed.pairs.count, 1)
        XCTAssertEqual(seed.pairs[0].key1, 4)
        XCTAssertEqual(seed.pairs[0].key2, 7)
        XCTAssertEqual(seed.pairs[0].mode, 1)
        XCTAssertTrue(seed.pairs[0].reportBoth)

        // A factory image (all zeros) seeds the factory config: disabled.
        let factorySeed = blankImage().rapidTapConfigSeed()
        XCTAssertFalse(factorySeed.enabled)
    }

    // MARK: - Wire framing

    func testReadChunkRequestFraming() {
        let request = OnboardProfile.readChunkRequest(slot: 0, offset: 500)
        XCTAssertEqual(request.count, OnboardProfile.featurePayloadSize)
        XCTAssertEqual(Array(request[0..<9]),
                       [0x83, 0x01, 0x80, 0xF4, 0x01, 0xF4, 0x01, 0x00, 0x00])
    }

    func testWriteChunkReportsCoverImageWithFFPadding() {
        var image = blankImage()
        image.bytes[OnboardProfile.Layout.imageSize - 1] = 0x5A   // near-tail sentinel
        image.sealCRC()
        let reports = OnboardProfile.writeChunkReports(image: image, slot: 1)

        XCTAssertEqual(reports.count, 25)
        // First chunk: command, fs id 0x81, size 500, offset 0.
        XCTAssertEqual(Array(reports[0][0..<9]),
                       [0x03, 0x01, 0x81, 0xF4, 0x01, 0x00, 0x00, 0x00, 0x00])
        // Last chunk: offset 12000, remainder of the image then 0xFF padding.
        XCTAssertEqual(Array(reports[24][5..<9]), [0xE0, 0x2E, 0x00, 0x00])
        let reassembled = reports.flatMap { Array($0[9..<(9 + OnboardProfile.chunkSize)]) }
        XCTAssertEqual(Array(reassembled.prefix(OnboardProfile.Layout.imageSize)), image.bytes)
        XCTAssertTrue(reassembled.suffix(from: OnboardProfile.Layout.imageSize)
            .allSatisfy { $0 == 0xFF })
    }

    func testEraseAndValidateRequests() {
        XCTAssertEqual(OnboardProfile.eraseRequest(slot: 2), [0x02, 0x01, 0x82])
        XCTAssertEqual(OnboardProfile.validateRequest(slot: 2), [0xB1, 0x02])
    }
}
