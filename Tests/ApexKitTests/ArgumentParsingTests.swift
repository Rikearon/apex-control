import XCTest
@testable import ApexKit

/// `apexctl` sends whatever it parses to a real keyboard, so its argument rules are
/// tested here: a token that is dropped or reinterpreted would send a different
/// command from the one that was typed.
final class ArgumentParsingTests: XCTestCase {

    // MARK: - Hex bytes

    func testHexBytesAcceptOneOrTwoDigitsWithOrWithoutPrefix() {
        XCTAssertEqual(ArgumentParsing.hexByte("0"), 0x00)
        XCTAssertEqual(ArgumentParsing.hexByte("4"), 0x04)
        XCTAssertEqual(ArgumentParsing.hexByte("B6"), 0xB6)
        XCTAssertEqual(ArgumentParsing.hexByte("b6"), 0xB6)
        XCTAssertEqual(ArgumentParsing.hexByte("0x5B"), 0x5B)
        XCTAssertEqual(ArgumentParsing.hexByte("0X5b"), 0x5B)
        XCTAssertEqual(ArgumentParsing.hexByte("FF"), 0xFF)
    }

    func testHexBytesRejectAnythingElse() {
        for bad in ["", "0x", "G0", "4G", "zz", " 4", "4 ", "+1", "-1", "-0", "004", "100", "0x100", "0xx4",
                    "1.5", "٤", "Ａ", "0x0x4"] {
            XCTAssertNil(ArgumentParsing.hexByte(bad), "\(bad.debugDescription) must not parse")
        }
    }

    // MARK: - Slots

    func testSlotsAreOneDecimalDigitFromZeroToFour() {
        for slot in 0...4 {
            XCTAssertEqual(ArgumentParsing.slot(String(slot)), UInt8(slot))
        }
        XCTAssertEqual(ArgumentParsing.slot("04"), 4, "leading zeros are still the number four")
    }

    func testSlotsRejectTyposInsteadOfFallingBackToSlotZero() {
        for bad in ["", "5", "9", "-1", "+3", "a", "1.0", " 1", "3 ", "255", "256", "٣"] {
            XCTAssertNil(ArgumentParsing.slot(bad), "\(bad.debugDescription) must not select a slot")
        }
    }

    // MARK: - Whole numbers

    func testWholeNumbersAreDigitsWithinTheRange() {
        XCTAssertEqual(ArgumentParsing.wholeNumber("0", in: 0...10), 0)
        XCTAssertEqual(ArgumentParsing.wholeNumber("10", in: 0...10), 10)
        XCTAssertEqual(ArgumentParsing.wholeNumber("007", in: 0...10), 7)
        XCTAssertEqual(ArgumentParsing.wholeNumber("644", in: 1...644), 644)
    }

    func testWholeNumbersRejectSignsTyposAndOutOfRangeValues() {
        for bad in ["", "-1", "+1", "1.5", "abc", "1e3", " 1", "1 ", "11", "999999999999", "٣"] {
            XCTAssertNil(ArgumentParsing.wholeNumber(bad, in: 0...10), "\(bad.debugDescription) must not parse")
        }
        XCTAssertNil(ArgumentParsing.wholeNumber("0", in: 1...644), "zero is below the range")
    }

    // MARK: - Numbers

    func testFiniteNumbersFallBackWhenMissingOrNotFinite() {
        XCTAssertEqual(ArgumentParsing.finiteNumber(nil, or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("", or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("abc", or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("nan", or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("inf", or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("-inf", or: 5), 5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("2.5", or: 5), 2.5)
        XCTAssertEqual(ArgumentParsing.finiteNumber("-3", or: 5), -3)
        XCTAssertEqual(ArgumentParsing.finiteNumber("8", or: 5), 8)
    }

    func testFrameRatesNeverExceedTheLightingCeiling() {
        let limit = ArgumentParsing.frameRates
        XCTAssertEqual(limit.upperBound, 30, "30 fps is the lighting ceiling (docs/PROTOCOL.md)")
        XCTAssertEqual(ArgumentParsing.clamped(60, to: limit), 30)
        XCTAssertEqual(ArgumentParsing.clamped(30, to: limit), 30)
        XCTAssertEqual(ArgumentParsing.clamped(12.5, to: limit), 12.5)
        XCTAssertEqual(ArgumentParsing.clamped(0, to: limit), 1)
        XCTAssertEqual(ArgumentParsing.clamped(-5, to: limit), 1)
    }

    func testDurationsAreNeverNegativeAndAreBounded() {
        let limit = ArgumentParsing.durations
        XCTAssertEqual(ArgumentParsing.clamped(-3, to: limit), 0)
        XCTAssertEqual(ArgumentParsing.clamped(8, to: limit), 8)
        XCTAssertEqual(ArgumentParsing.clamped(1e300, to: limit), 3600)
        // The frame count that follows must be representable.
        XCTAssertLessThanOrEqual(limit.upperBound * ArgumentParsing.frameRates.upperBound, Double(Int32.max))
    }
}
