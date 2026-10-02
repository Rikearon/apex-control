import XCTest
@testable import ApexKit

final class ApexKitTests: XCTestCase {

    func testDirectWriteFraming() {
        let data = DirectLighting.directWrite(colors: [(hid: 0x04, color: LEDColor(r: 10, g: 20, b: 30))])
        XCTAssertEqual(data.count, 644)
        XCTAssertEqual(data[0], 0x40)          // command
        XCTAssertEqual(data[1], 1)             // count
        XCTAssertEqual(Array(data[2...5]), [0x04, 10, 20, 30])
    }

    func testClearIsOutput41() {
        XCTAssertEqual(DirectLighting.clearDirect(), [0x41])
    }

    func testHallThresholdFraming() {
        let data = Actuation.hallThresholds(perKeyLevel: [:], defaultLevel: 10)
        XCTAssertEqual(data.count, 644)
        XCTAssertEqual(data[0], 0x38)
        XCTAssertEqual(data[1], 0x61)
        XCTAssertEqual(data[2], 68)            // one block per analog key
        XCTAssertEqual(data[3], 0x00)          // layer
        // First analog key is HID 0x04; level 10 → (l:15, h:17), struct order h,l.
        XCTAssertEqual(data[4], 0x04)
        XCTAssertEqual(data[5], 17)            // h
        XCTAssertEqual(data[6], 15)            // l
    }

    func testActuationLevelClamp() {
        XCTAssertEqual(Actuation.hl(forLevel: 0).h, Actuation.hl(forLevel: 1).h)
        XCTAssertEqual(Actuation.hl(forLevel: 999).h, Actuation.hl(forLevel: 40).h)
        XCTAssertEqual(Actuation.level(forMillimetres: 2.0), 20)
    }

    func testReleaseModeFraming() {
        let data = Actuation.releaseMode(perKeyMode: [0x04: .rapidTrigger], defaultMode: .off)
        XCTAssertEqual(data[0], 0x38)
        XCTAssertEqual(data[1], 0x62)
        XCTAssertEqual(data[2], 68)
        XCTAssertEqual(data[3], 0x04)          // first analog key
        XCTAssertEqual(data[4], 2)             // its mode
        XCTAssertEqual(data[5], ApexProTKLGen3.analogHIDOrder[1])
        XCTAssertEqual(data[6], 0)             // everything else off
    }

    func testReleaseModeValuesAreTheOnesTheFirmwareAccepts() {
        // 0x00, 0x02, 0x03 and 0x04.
        XCTAssertEqual(Actuation.ReleaseMode.allCases.map(\.rawValue), [0x00, 0x02, 0x03, 0x04])
        XCTAssertTrue(Actuation.ReleaseMode.alternate3.isUnverified)
        XCTAssertTrue(Actuation.ReleaseMode.alternate4.isUnverified)
        XCTAssertFalse(Actuation.ReleaseMode.rapidTrigger.isUnverified)
    }

    func testSecondActuationDisabledSentinel() {
        // Keys with no second point must be sent as 255/255, not 0/0 — 0 would
        // mean "actuates immediately".
        let data = Actuation.secondActuation(perKeyLevel: [0x04: 30])
        XCTAssertEqual(data[0], 0x38)
        XCTAssertEqual(data[1], 0x61)
        XCTAssertEqual(data[2], 68)
        XCTAssertEqual(data[3], 0x02)          // layer
        XCTAssertEqual(data[4], 0x04)
        XCTAssertEqual(data[5], Actuation.hl(forLevel: 30).h)
        XCTAssertEqual(data[6], Actuation.hl(forLevel: 30).l)
        XCTAssertEqual(data[7], ApexProTKLGen3.analogHIDOrder[1])
        XCTAssertEqual(data[8], 255)
        XCTAssertEqual(data[9], 255)
    }

    func testActuationCurveMatchesGen3Table() {
        // This model's curve differs from the earlier models'; these are its endpoints.
        XCTAssertEqual(Actuation.levelToLH.count, 40)
        XCTAssertEqual(Actuation.levelToLH[0].l, 4)
        XCTAssertEqual(Actuation.levelToLH[0].h, 4)
        XCTAssertEqual(Actuation.levelToLH[39].l, 213)
        XCTAssertEqual(Actuation.levelToLH[39].h, 219)
        // l ≤ h everywhere gives the hysteresis the firmware expects.
        for (i, e) in Actuation.levelToLH.enumerated() {
            XCTAssertLessThanOrEqual(e.l, e.h, "level \(i + 1) has l > h")
        }
    }

    func testRapidTapPairs() {
        let data = Actuation.rapidTapPairs([Actuation.RapidTapPair(hid1: 0x04, hid2: 0x07, mode: 1, reportBoth: true)])
        XCTAssertEqual(Array(data[0...3]), [0x38, 0x67, 1, 0])   // cmd, subcmd, count, index
        XCTAssertEqual(data[4], 0x04)
        XCTAssertEqual(data[5], 0x07)
        XCTAssertEqual(data[6], 1 | 0x80)      // mode + report-both flag
    }

    func testOLEDColumnPacking() {
        var bmp = MonoBitmap()
        bmp.set(0, 0, true)     // top-left → page 0, bit 0
        bmp.set(0, 8, true)     // page 1, bit 0
        let packed = bmp.columnPacked()
        XCTAssertEqual(packed.count, 640)
        XCTAssertEqual(packed[0], 0x01)         // page 0 col 0, bit 0
        XCTAssertEqual(packed[128], 0x01)       // page 1 col 0, bit 0
    }

    func testLayoutHasExpectedKeys() {
        XCTAssertNotNil(ApexProTKLGen3.key(forHID: 0x04))       // A
        XCTAssertEqual(ApexProTKLGen3.analogHIDOrder.count, 68)
        // Space (0x2C) should be analog on the Pro.
        XCTAssertTrue(ApexProTKLGen3.analogHIDCodes.contains(0x2C))
    }
}
