import XCTest
@testable import ApexKit

/// The key tables are derived from the firmware's key-slot table and the
/// lighting zone lists. These tests pin the derivations to the counts and
/// membership rules recorded in docs/PROTOCOL.md, so a future edit cannot
/// silently change which keys we address.
final class KeyTableTests: XCTestCase {

    func testDeviceKeyIndexTableShape() {
        XCTAssertEqual(ApexProTKLGen3.deviceKeyIndexToHID.count, 100)
        XCTAssertEqual(ApexProTKLGen3.numFirmwareAnalogKeys, 70)
        XCTAssertEqual(ApexProTKLGen3.numFirmwareMechanicalKeys, 24)
    }

    func testMappableKeyCountIs91() {
        // Every populated, non-ignored slot.
        XCTAssertEqual(ApexProTKLGen3.mappingBlockCount, 91)
        XCTAssertEqual(ApexProTKLGen3.mappableHIDOrder, ApexProTKLGen3.mappableHIDOrder.sorted())
        XCTAssertFalse(ApexProTKLGen3.mappableHIDOrder.contains(0))
    }

    func testAnalogKeyCountIsNumAnalogKeys68() {
        XCTAssertEqual(ApexProTKLGen3.actuationBlockCount, 68)
        XCTAssertEqual(ApexProTKLGen3.analogHIDOrder, ApexProTKLGen3.analogHIDOrder.sorted())
        // The 68 adjustable keys, in the order the actuation commands emit them.
        XCTAssertEqual(ApexProTKLGen3.analogHIDOrder, [
            4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
            20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
            36, 37, 38, 39, 40, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52,
            53, 54, 55, 56, 57, 100, 135, 136, 137, 138, 139,
            224, 225, 226, 227, 228, 229, 230, 231, 240,
        ])
    }

    func testAnalogKeysAreASubsetOfMappableKeys() {
        XCTAssertTrue(ApexProTKLGen3.analogHIDCodes.isSubset(of: ApexProTKLGen3.mappableHIDCodeSet))
    }

    func testMediaButtonsAreNeitherMappableNorLit() {
        // The OLED/media navigation buttons the firmware refuses to rebind.
        for hid in ApexProTKLGen3.ignoredHIDCodes {
            XCTAssertFalse(ApexProTKLGen3.mappableHIDCodeSet.contains(hid),
                           String(format: "0x%02X must not be rebindable", hid))
            XCTAssertFalse(ApexProTKLGen3.ledHIDCodeSet.contains(hid),
                           String(format: "0x%02X has no LED", hid))
        }
    }

    func testLEDSetMatchesThisModel() {
        // `all` zone (0x04…0x45, 0x49…0x52, 0xE0…0xE7, 0xF0) plus 0xFB, which
        // this model adds for the play/pause button by the OLED.
        XCTAssertEqual(ApexProTKLGen3.ledHIDOrder.count, 86)
        XCTAssertTrue(ApexProTKLGen3.ledHIDCodeSet.contains(0xFB))
        XCTAssertTrue(ApexProTKLGen3.ledHIDCodeSet.contains(0xF0))
        XCTAssertTrue(ApexProTKLGen3.ledHIDCodeSet.contains(0x32), "the ISO #~ LED exists in the matrix")
        // The Gen 3 TKL has no Print Screen / Scroll Lock / Pause.
        for hid: UInt8 in [0x46, 0x47, 0x48] {
            XCTAssertFalse(ApexProTKLGen3.ledHIDCodeSet.contains(hid))
        }
    }

    func testPlayPauseKeyLightsButCannotBeRebound() {
        let key = ApexProTKLGen3.key(forHID: 0xFB)
        XCTAssertNotNil(key)
        XCTAssertTrue(key!.hasLED)
        XCTAssertFalse(key!.isMappable)
        XCTAssertFalse(key!.isAnalog)
    }

    func testEveryRenderedKeyIsEitherLitOrKnownDark() {
        for key in ApexProTKLGen3.keys {
            XCTAssertTrue(key.hasLED, "\(key.label) is drawn but has no LED — the frame would skip it")
        }
    }

    func testLayoutVariants() {
        let ansi = ApexProTKLGen3.keys(for: .ansi)
        let iso = ApexProTKLGen3.keys(for: .iso)
        XCTAssertEqual(iso.count, ansi.count + 1)
        XCTAssertFalse(ansi.contains { $0.hid == 0x32 })
        XCTAssertTrue(iso.contains { $0.hid == 0x32 })
    }

    func testNoDuplicateKeysInLayout() {
        let hids = ApexProTKLGen3.keys.map(\.hid)
        XCTAssertEqual(Set(hids).count, hids.count)
    }

    func testDirectWriteFrameCoversEveryLED() {
        let data = DirectLighting.solid(.red)
        XCTAssertEqual(data[0], 0x40)
        XCTAssertEqual(Int(data[1]), ApexProTKLGen3.ledHIDOrder.count)
        XCTAssertLessThanOrEqual(2 + Int(data[1]) * 4, 644, "the frame must fit one feature report")
        for (i, hid) in ApexProTKLGen3.ledHIDOrder.enumerated() {
            XCTAssertEqual(data[2 + i * 4], hid)
            XCTAssertEqual(Array(data[(2 + i * 4 + 1)...(2 + i * 4 + 3)]), [255, 0, 0])
        }
    }

    func testHIDUsageNames() {
        XCTAssertEqual(HIDUsage.name(0x04), "A")
        XCTAssertEqual(HIDUsage.name(0x1D), "Z")
        XCTAssertEqual(HIDUsage.name(0x1E), "1")
        XCTAssertEqual(HIDUsage.name(0x27), "0")
        XCTAssertEqual(HIDUsage.name(0x3A), "F1")
        XCTAssertEqual(HIDUsage.name(0x45), "F12")
        XCTAssertEqual(HIDUsage.name(0x68), "F13")
        XCTAssertEqual(HIDUsage.name(0xE3), "Left Cmd")
        XCTAssertTrue(HIDUsage.isModifier(0xE0))
        XCTAssertTrue(HIDUsage.isModifier(0xE7))
        XCTAssertFalse(HIDUsage.isModifier(0xDF))
        XCTAssertEqual(HIDUsage.modifiers.count, 8)
    }
}
