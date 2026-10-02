import XCTest
@testable import ApexKit

/// The rules that decide whether a keyboard tap that *exists* is actually
/// being *fed* — the difference between "listening" and the modifiers-only
/// half-life macOS gives a tap whose permission it does not honour.
///
/// The real condition needs a stale or missing TCC grant to reproduce, which
/// no test host can arrange, so every rule lives in pure logic and is pinned
/// down here instead.
final class TapHealthTests: XCTestCase {

    private func fresh(startedAt: TimeInterval = 100) -> TapHealth {
        TapHealth(startedAt: startedAt)
    }

    // MARK: - The permission signal

    func testNoGrantIsFilteredBeforeAnyEvidence() {
        // Without an honoured grant the window server *will* starve the tap;
        // there is no need to wait for proof.
        var h = fresh()
        XCTAssertEqual(h.evaluate(expectedToHear: false, secureInput: false,
                                  systemSecondsSinceKeyDown: 1_000, at: 101),
                       .filtered)
    }

    func testGrantAndSilenceIsHearing() {
        // Trusted and nobody typing anywhere: no evidence can accumulate and
        // the verdict must stay clean indefinitely.
        var h = fresh(startedAt: 100)
        for t in stride(from: 101.0, through: 110.0, by: 0.25) {
            XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                      systemSecondsSinceKeyDown: t - 50, at: t),
                           .hearingEverything, "at \(t)")
        }
    }

    func testGrantVanishingFlipsTheVerdictWithoutEvidence() {
        var h = fresh(startedAt: 100)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 1_000, at: 101),
                       .hearingEverything)
        XCTAssertEqual(h.evaluate(expectedToHear: false, secureInput: false,
                                  systemSecondsSinceKeyDown: 1_000, at: 102),
                       .filtered)
    }

    // MARK: - The deafness signal

    func testTypingTheTapCannotHearConvictsIt() {
        // The bug as reported: a grant is on record, someone is typing in
        // another app, and nothing arrives. Two distinct missed presses is
        // conviction, whatever the permission APIs say.
        var h = fresh(startedAt: 100)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 101.1),
                       .hearingEverything,
                       "one missed press must never convict — it can be in flight")
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 102.1),
                       .filtered)
    }

    func testOnePressIsOnlyOneStrikeHoweverOftenItIsSeen() {
        // A single missed press stays "recent" for many watchdog ticks. It
        // must count once, not once per tick — otherwise one unlucky race
        // convicts a healthy tap.
        var h = fresh(startedAt: 100)
        let pressAt = 101.0
        for t in stride(from: 101.1, through: 102.6, by: 0.25) {
            XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                      systemSecondsSinceKeyDown: t - pressAt, at: t),
                           .hearingEverything, "at \(t)")
        }
    }

    func testPressesFromBeforeTheTapExistedAreNotEvidence() {
        // The tap comes up mid-keystroke: the system clock shows a fresh
        // key-down that the tap could never have heard.
        var h = fresh(startedAt: 100)
        let pressAt = 99.9
        for t in stride(from: 100.05, through: 103.0, by: 0.25) {
            XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                      systemSecondsSinceKeyDown: t - pressAt, at: t),
                           .hearingEverything, "at \(t)")
        }
    }

    func testHeardPressesAreNotStrikes() {
        var h = fresh(startedAt: 100)
        h.heardKeyDown(foreign: false, at: 101.0)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.05, at: 101.05),
                       .hearingEverything)
    }

    func testHearingResetsTheStrikeCount() {
        // Strikes must be *consecutive* misses: hearing anything in between
        // starts the count over.
        var h = fresh(startedAt: 100)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 101.1),
                       .hearingEverything)              // miss #1
        h.heardKeyDown(foreign: false, at: 102)          // heard — count resets
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 105.1),
                       .hearingEverything)              // miss #1 again, not #2
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 106.1),
                       .filtered)                        // miss #2 convicts
    }

    // MARK: - The proof signal

    func testOwnKeysAreNoProof() {
        // A filtered tap still hears the app's own key presses, so they must
        // not overturn an unhonoured grant — that is exactly the "works only
        // while the app is frontmost" trap.
        var h = fresh(startedAt: 100)
        h.heardKeyDown(foreign: false, at: 101)
        XCTAssertEqual(h.evaluate(expectedToHear: false, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.05, at: 101.05),
                       .filtered)
    }

    func testForeignKeyIsProofThatOverridesThePermissionCheck() {
        // A key press aimed at another process can only arrive when delivery
        // is genuinely on, whatever the record checks claim.
        var h = fresh(startedAt: 100)
        h.heardKeyDown(foreign: true, at: 101)
        XCTAssertEqual(h.evaluate(expectedToHear: false, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.05, at: 101.05),
                       .hearingEverything)
    }

    func testForeignKeyLiftsAConviction() {
        // Granting Accessibility mid-session makes an existing tap start
        // hearing; the first foreign press must clear the deafness verdict.
        var h = fresh(startedAt: 100)
        _ = h.evaluate(expectedToHear: true, secureInput: false,
                       systemSecondsSinceKeyDown: 0.1, at: 101.1)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 102.1),
                       .filtered)
        h.heardKeyDown(foreign: true, at: 110)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.05, at: 110.05),
                       .hearingEverything)
    }

    func testConvictionOutranksStaleProof() {
        // Delivery that was once proven and then stops is what a mid-session
        // revocation looks like; the old proof must not paper over it.
        var h = fresh(startedAt: 100)
        h.heardKeyDown(foreign: true, at: 101)
        _ = h.evaluate(expectedToHear: true, secureInput: false,
                       systemSecondsSinceKeyDown: 0.1, at: 105.1)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 106.1),
                       .filtered)
    }

    // MARK: - Secure input

    func testSecureInputSuspendsJudgement() {
        // A password field hides key presses from every tap on the system:
        // misses during it prove nothing and must not count — then or later.
        var h = fresh(startedAt: 100)
        for t in [101.1, 102.1, 103.1] {
            XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: true,
                                      systemSecondsSinceKeyDown: 0.1, at: t),
                           .hearingEverything, "at \(t)")
        }
        // The slate is clean afterwards: it still takes two fresh misses.
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 104.1),
                       .hearingEverything)
        XCTAssertEqual(h.evaluate(expectedToHear: true, secureInput: false,
                                  systemSecondsSinceKeyDown: 0.1, at: 105.1),
                       .filtered)
    }
}
