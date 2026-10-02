import XCTest
@testable import ApexKit

/// Profile serialisation has to survive being written by one build and read by
/// another, and being hand-edited — PRD-06 FR-1/FR-9 and §9.
final class ConfigurationTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    // MARK: - HIDMap

    func testHIDMapEncodesReadableHexKeys() throws {
        let map: HIDMap<Int> = [0x2C: 12, 0x04: 40]
        let json = String(data: try encoder().encode(map), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"0x2C\""), json)
        XCTAssertTrue(json.contains("\"0x04\""), json)
    }

    func testHIDMapRoundTrip() throws {
        let map: HIDMap<LEDColor> = [0x04: .red, 0xF0: .steelOrange]
        let back = try decoder().decode(HIDMap<LEDColor>.self, from: try encoder().encode(map))
        XCTAssertEqual(back, map)
    }

    func testHIDMapAcceptsHandEditedKeyForms() throws {
        let json = #"{"0x2C": 1, "2C": 2, "44": 3}"#.data(using: .utf8)!
        let map = try decoder().decode(HIDMap<Int>.self, from: json)
        // All three spellings resolve to 0x2C = 44; the last one wins is not
        // guaranteed, but exactly one entry must exist and it must be keyed 0x2C.
        XCTAssertEqual(map.count, 1)
        XCTAssertNotNil(map[0x2C])
    }

    func testHIDMapSkipsJunkKeysInsteadOfThrowing() throws {
        let json = #"{"0x04": 7, "not-a-key": 9}"#.data(using: .utf8)!
        let map = try decoder().decode(HIDMap<Int>.self, from: json)
        XCTAssertEqual(map[0x04], 7)
        XCTAssertEqual(map.count, 1)
    }

    // MARK: - Tolerant decoding

    func testProfileDecodesFromMinimalJSON() throws {
        // A file from a future build that dropped fields, or an older one that
        // never had them, must still load with sane defaults.
        let json = #"{"name": "Minimal"}"#.data(using: .utf8)!
        let p = try decoder().decode(SoftwareProfile.self, from: json)
        XCTAssertEqual(p.name, "Minimal")
        XCTAssertEqual(p.actuation.globalLevel, 15)
        XCTAssertEqual(p.lighting.kind, .rainbowWave)
        XCTAssertFalse(p.rapidTap.enabled)
        XCTAssertTrue(p.bindings.isEmpty)
    }

    func testProfileIgnoresUnknownFields() throws {
        let json = #"{"name": "Future", "somethingNew": {"a": 1}}"#.data(using: .utf8)!
        let p = try decoder().decode(SoftwareProfile.self, from: json)
        XCTAssertEqual(p.name, "Future")
    }

    func testProfileFullRoundTrip() throws {
        var p = SoftwareProfile()
        p.name = "CS2"
        p.lighting.kind = .perKey
        p.lighting.perKeyColors[0x1A] = .green
        p.actuation.globalLevel = 8
        p.actuation.rapidTrigger = true
        p.actuation.releaseMode = .rapidTrigger
        p.actuation.secondActuationEnabled = true
        p.actuation.perKeySecondActuation[0x2C] = 30
        p.rapidTap.enabled = true
        p.bindings.normal[0x39] = .keyboard(usage: HIDUsage.leftControl)
        p.bindings.meta[0x1E] = .consumer(.volumeUp)
        p.bindings.metaToggleHID = 0xF0
        p.oled.mode = .clock

        let back = try decoder().decode(SoftwareProfile.self, from: try encoder().encode(p))
        XCTAssertTrue(back.hasSameSettings(as: p))
        XCTAssertEqual(back.bindings.normal[0x39], .keyboard(usage: HIDUsage.leftControl))
        XCTAssertEqual(back.bindings.metaToggleHID, 0xF0)
        XCTAssertEqual(back.actuation.perKeySecondActuation[0x2C], 30)
        XCTAssertEqual(back.lighting.perKeyColors[0x1A], .green)
    }

    // MARK: - Config behaviour

    func testActuationPerKeyFallsBackToGlobal() {
        var c = ActuationConfig()
        c.globalLevel = 15
        c.perKey[0x04] = 5
        XCTAssertEqual(c.level(for: 0x04), 15, "per-key values are ignored until per-key mode is on")
        c.usePerKey = true
        XCTAssertEqual(c.level(for: 0x04), 5)
        XCTAssertEqual(c.level(for: 0x05), 15)
    }

    func testSecondActuationIsClampedBelowPrimary() {
        var c = ActuationConfig()
        c.globalLevel = 20
        c.secondActuationEnabled = true
        c.perKeySecondActuation[0x2C] = 5          // shallower than the primary
        XCTAssertEqual(c.secondActuationLevel(for: 0x2C), 21, "must sit deeper than the first point")
        c.perKeySecondActuation[0x2C] = 35
        XCTAssertEqual(c.secondActuationLevel(for: 0x2C), 35)
        c.secondActuationEnabled = false
        XCTAssertNil(c.secondActuationLevel(for: 0x2C))
        c.secondActuationEnabled = true
        XCTAssertNil(c.secondActuationLevel(for: 0x04), "keys with no explicit second point have none")
    }

    func testRapidTapValidationDropsUnusablePairs() {
        var c = RapidTapConfig()
        var same = RapidTapConfig.Pair(); same.key1 = 0x04; same.key2 = 0x04
        var dupe = RapidTapConfig.Pair(); dupe.key1 = 0x04; dupe.key2 = 0x16   // A already used
        var nonAnalog = RapidTapConfig.Pair(); nonAnalog.key1 = 0x3A; nonAnalog.key2 = 0x3B  // F1/F2
        var good = RapidTapConfig.Pair(); good.key1 = 0x1A; good.key2 = 0x16   // W / S

        c.pairs = [RapidTapConfig.Pair(), same, dupe, nonAnalog, good]         // first is A↔D
        let valid = c.validPairs
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(valid[0].key1, 0x04)
        XCTAssertEqual(valid[1].key1, 0x1A)
    }

    func testRapidTapCapsAtTenPairs() {
        var c = RapidTapConfig()
        // Twelve disjoint pairs drawn from the analog set.
        let keys = ApexProTKLGen3.analogHIDOrder
        c.pairs = (0..<12).map { i in
            var p = RapidTapConfig.Pair(); p.key1 = keys[i * 2]; p.key2 = keys[i * 2 + 1]; return p
        }
        XCTAssertEqual(c.validPairs.count, 10)
    }

    func testBindingsConfigCountsOnlyRealChanges() {
        var b = BindingsConfig()
        XCTAssertTrue(b.isEmpty)
        b.normal[0x04] = .unbound
        XCTAssertTrue(b.isEmpty, "an explicit default is not a change")
        b.normal[0x04] = .disabled
        XCTAssertEqual(b.changedCount, 1)
        b.meta[0x05] = .consumer(.mute)
        b.metaToggleHID = 0xF0
        XCTAssertEqual(b.changedCount, 3)
    }

    func testBindingsConfigLayerSubscript() {
        var b = BindingsConfig()
        b[.meta][0x04] = .disabled
        XCTAssertEqual(b.meta[0x04], .disabled)
        XCTAssertNil(b.normal[0x04])
        XCTAssertEqual(b[.meta][0x04], .disabled)
    }

    func testOLEDRendering() {
        var c = OLEDConfig()
        c.mode = .off
        XCTAssertNil(c.render())
        c.mode = .text
        c.line1 = "APEX"; c.line2 = ""
        let bmp = c.render()
        XCTAssertNotNil(bmp)
        XCTAssertTrue(bmp!.pixels.contains(true), "text should light some pixels")
        c.mode = .image
        c.imagePath = nil
        XCTAssertNil(c.render(), "an image mode with no file renders nothing rather than crashing")
        c.mode = .clock
        XCTAssertTrue(c.isLive)
    }

    func testProfileSummaryMentionsKeySettings() {
        var p = SoftwareProfile()
        p.actuation.globalLevel = 10
        p.actuation.rapidTrigger = true
        p.bindings.normal[0x39] = .disabled
        let s = p.summary
        XCTAssertTrue(s.contains("1.0 mm"), s)
        XCTAssertTrue(s.contains("RT"), s)
        XCTAssertTrue(s.contains("1 binds"), s)
    }
}
