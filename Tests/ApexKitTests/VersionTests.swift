import XCTest
@testable import ApexKit

/// The version string is parsed by shell scripts and compared with git tags, so
/// its shape is a contract rather than a label.
final class VersionTests: XCTestCase {

    /// `MAJOR.MINOR.PATCH` with an optional `-prerelease`. Build metadata
    /// (`+abc`) is deliberately not accepted: the release workflow turns the
    /// version into the tag `v<version>`, and `+` has no place in a tag.
    private static let pattern =
        #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"#
        + #"(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$"#

    private func isValid(_ version: String) -> Bool {
        version.range(of: Self.pattern, options: .regularExpression) != nil
    }

    func testTheShippedVersionIsSemanticVersioning() {
        XCTAssertTrue(isValid(ApexVersion.current),
                      "\(ApexVersion.current) is not MAJOR.MINOR.PATCH[-prerelease]")
    }

    /// `Scripts/version.sh` parses `Version.swift` with `sed`, so the declaration's
    /// layout is part of the contract. Reformatting it (a type annotation, a
    /// trailing comment, a second `current`) must fail here, not at release time.
    func testTheBuildScriptReadsTheVersionTheLibraryReports() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("Scripts/version.sh").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(printed, ApexVersion.current)
    }

    func testThePatternAcceptsWhatItShouldAndNothingElse() {
        for good in ["0.1.0", "1.0.0", "10.20.30", "1.2.3-rc.1", "2.0.0-beta", "0.2.0-dev", "1.2.3-0", "1.2.3-1a"] {
            XCTAssertTrue(isValid(good), good)
        }
        for bad in ["", "1", "1.2", "1.2.3.4", "v1.2.3", "01.2.3", "1.2.3+build", "1.2.3-", "1.2.3-rc..1", "1.2.3-01", "1.2.3-rc.01"] {
            XCTAssertFalse(isValid(bad), bad)
        }
    }
}
