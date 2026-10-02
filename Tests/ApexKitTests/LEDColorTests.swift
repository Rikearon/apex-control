import XCTest
@testable import ApexKit

final class LEDColorTests: XCTestCase {

    func testHexParsingAcceptsAnOptionalHashAndAnyCase() {
        XCTAssertEqual(LEDColor(hex: "#FF4A00"), LEDColor.steelOrange)
        XCTAssertEqual(LEDColor(hex: "ff4a00"), LEDColor.steelOrange)
        XCTAssertEqual(LEDColor(hex: "  #00ff00 "), LEDColor.green)     // surrounding spaces are trimmed
    }

    func testHexParsingRejectsMalformedInput() {
        XCTAssertNil(LEDColor(hex: ""))
        XCTAssertNil(LEDColor(hex: "#FFF"))          // shorthand is not supported
        XCTAssertNil(LEDColor(hex: "#FF4A0000"))     // no alpha channel
        XCTAssertNil(LEDColor(hex: "#GG0000"))       // not hexadecimal
    }

    func testHexParsingRejectsASignCharacter() {
        // `UInt32("+FF4A0", radix: 16)` is valid Swift, so a length check alone lets this through.
        XCTAssertNil(LEDColor(hex: "+FF4A0"))
        XCTAssertNil(LEDColor(hex: "#-00000"))
    }

    func testHexStringRoundTrips() {
        XCTAssertEqual(LEDColor.steelOrange.hexString, "#FF4A00")
        let c = LEDColor(r: 1, g: 2, b: 3)
        XCTAssertEqual(LEDColor(hex: c.hexString), c)
    }
}
