import XCTest
@testable import ApexKit

/// The rules behind "the key I just pressed lights up".
///
/// Reactive lighting failed in the field in a way that is invisible from the
/// outside — a keyboard nobody is typing on and a listener macOS refused look
/// identical — so the halves of it that can be checked without hardware or a
/// permission prompt are pinned down here: which events count as a press, and
/// what a frame looks like at each point in a key's fade.
final class ReactiveLightingTests: XCTestCase {

    // MARK: - What counts as a press

    func testModifiersAreRecognisedFromTheirOwnDeviceBit() {
        // Modifiers never arrive as keyDown, so this table is the only route by
        // which a shift or a command press can ever light up.
        let cases: [(name: String, virtualCode: UInt16, usage: UInt8)] = [
            ("left control", 0x3B, HIDUsage.leftControl),
            ("left shift", 0x38, HIDUsage.leftShift),
            ("right shift", 0x3C, HIDUsage.rightShift),
            ("left command", 0x37, HIDUsage.leftGUI),
            ("right command", 0x36, HIDUsage.rightGUI),
            ("left option", 0x3A, HIDUsage.leftAlt),
            ("right option", 0x3D, HIDUsage.rightAlt),
            ("right control", 0x3E, HIDUsage.rightControl),
        ]
        for c in cases {
            guard let mask = MacKeyCode.deviceFlagMask(forModifierUsage: c.usage) else {
                return XCTFail("\(c.name) has no device bit")
            }
            XCTAssertEqual(MacKeyCode.pressedUsage(forFlagsChanged: c.virtualCode, flags: mask),
                           c.usage, "\(c.name) down")
            XCTAssertNil(MacKeyCode.pressedUsage(forFlagsChanged: c.virtualCode, flags: 0),
                         "\(c.name) up should not count as a press")
        }
    }

    func testEachModifierHasItsOwnBit() {
        // The whole point of the device bits over CGEventFlags: tapping right
        // shift while left shift is held has to be visible. Sharing a bit would
        // silently swallow it.
        let usages = [HIDUsage.leftControl, HIDUsage.leftShift, HIDUsage.rightShift,
                      HIDUsage.leftGUI, HIDUsage.rightGUI, HIDUsage.leftAlt,
                      HIDUsage.rightAlt, HIDUsage.rightControl]
        let masks = usages.compactMap { MacKeyCode.deviceFlagMask(forModifierUsage: $0) }
        XCTAssertEqual(masks.count, usages.count)
        XCTAssertEqual(Set(masks).count, usages.count, "two modifiers share a bit")
    }

    func testRightShiftIsSeenWhileLeftShiftIsHeld() {
        let left = MacKeyCode.deviceFlagMask(forModifierUsage: HIDUsage.leftShift)!
        let right = MacKeyCode.deviceFlagMask(forModifierUsage: HIDUsage.rightShift)!
        XCTAssertEqual(MacKeyCode.pressedUsage(forFlagsChanged: 0x3C, flags: left | right),
                       HIDUsage.rightShift)
    }

    func testCapsLockCountsAsAPressInBothDirections() {
        // Caps Lock is a toggle: switching it off is still someone hitting the
        // key, and there is no device bit that says which way it went.
        let caps = MacKeyCode.toHID[MacKeyCode.capsLockVirtualCode]
        XCTAssertNotNil(caps)
        XCTAssertEqual(MacKeyCode.pressedUsage(forFlagsChanged: MacKeyCode.capsLockVirtualCode,
                                               flags: 0x0001_0000), caps)
        XCTAssertEqual(MacKeyCode.pressedUsage(forFlagsChanged: MacKeyCode.capsLockVirtualCode,
                                               flags: 0), caps)
    }

    func testNonModifierFlagsChangedIsIgnored() {
        // The `fn` key produces flagsChanged and has no HID usage at all.
        XCTAssertNil(MacKeyCode.pressedUsage(forFlagsChanged: 0x3F, flags: 0xFFFF_FFFF))
    }

    // MARK: - The frame

    private func reactiveConfig(fade: Double = 0.5, rest: Double = 0.1,
                                ripple: Double = 0) -> LightingConfig {
        var c = LightingConfig()
        c.kind = .reactive
        c.baseColor = LEDColor(r: 255, g: 0, b: 0)
        c.secondaryColor = LEDColor(r: 0, g: 0, b: 255)
        c.reactiveFade = fade
        c.reactiveRestLevel = rest
        c.reactiveRipple = ripple
        return c
    }

    func testUntouchedKeysShowTheRestingColour() {
        let config = reactiveConfig()
        let frame = LightingRender.render(config: config, time: 0, hits: [:], now: 100)
        XCTAssertEqual(frame[0x04], config.reactiveRestColor)
        // Every addressable LED is in the frame; a partial frame leaves whatever
        // was there before on the board.
        XCTAssertEqual(Set(frame.keys), ApexProTKLGen3.ledHIDCodeSet)
    }

    func testAStruckKeyIsTheBaseColourAtTheMomentOfThePress() {
        let config = reactiveConfig()
        let frame = LightingRender.render(config: config, time: 0, hits: [0x04: 100], now: 100)
        XCTAssertEqual(frame[0x04], config.baseColor)
    }

    func testAStruckKeyFadesBackToTheRestingColourRatherThanToBlack() {
        let config = reactiveConfig(fade: 0.5)
        let rest = config.reactiveRestColor
        // The frame before the press expires must already be near the resting
        // colour, so dropping out of the hit map is not a visible step. The
        // tolerance is 3% of full scale — one frame's worth of a linear fade,
        // and far below what an eye can catch on an LED.
        let tolerance = 0.03 * 255
        let nearlyDone = LightingRender.render(config: config, time: 0,
                                               hits: [0x04: 100], now: 100.49)
        XCTAssertEqual(Double(nearlyDone[0x04]!.r), Double(rest.r), accuracy: tolerance)
        XCTAssertEqual(Double(nearlyDone[0x04]!.b), Double(rest.b), accuracy: tolerance)

        let expired = LightingRender.render(config: config, time: 0, hits: [0x04: 100], now: 100.5)
        XCTAssertEqual(expired[0x04], rest)
    }

    func testTheFadeIsMonotonic() {
        let config = reactiveConfig(fade: 1.0)
        var previous = 256.0
        for step in 0...10 {
            let now = 100 + Double(step) / 10
            let colour = LightingRender.render(config: config, time: 0, hits: [0x04: 100], now: now)[0x04]!
            XCTAssertLessThanOrEqual(Double(colour.r), previous + 0.5, "brightness went back up")
            previous = Double(colour.r)
        }
    }

    func testOnlyTheStruckKeyLights() {
        let config = reactiveConfig()
        let frame = LightingRender.render(config: config, time: 0, hits: [0x04: 100], now: 100)
        XCTAssertEqual(frame[0x05], config.reactiveRestColor)
    }

    func testAZeroFadeCannotDivideByZero() {
        var config = reactiveConfig()
        config.reactiveFade = 0
        let frame = LightingRender.render(config: config, time: 0, hits: [0x04: 100], now: 100)
        XCTAssertNotNil(frame[0x04])
    }

    func testRestingGlowCanBeTurnedOffEntirely() {
        let config = reactiveConfig(rest: 0)
        let frame = LightingRender.render(config: config, time: 0, hits: [:], now: 100)
        XCTAssertEqual(frame[0x04], .black)
    }

    // MARK: - The whole path, press to frame

    /// The two halves of reactive lighting were each verified on their own and
    /// the join between them was not, which is exactly where a bug hides. This
    /// walks it end to end: register a press the way the key listener does, read
    /// it back the way the streamer does, render it the way the board sees it.
    func testRegisteringAPressLightsThatKeyInTheNextFrame() {
        let engine = LightingEngine(device: ApexDevice())
        let config = reactiveConfig(fade: 2.0)

        // A letter and a modifier: the listener reaches this call by two
        // different routes (keyDown and flagsChanged) and everything past it is
        // common, so both must land identically.
        for hid in [UInt8(0x04), HIDUsage.leftShift] {
            engine.clearReactiveHits()
            engine.registerKeyPress(hid: hid)

            let hits = engine.reactiveSnapshot()
            XCTAssertNotNil(hits[hid], "the press was not recorded")

            let frame = LightingRender.render(config: config, time: 0, hits: hits)
            XCTAssertNotEqual(frame[hid], config.reactiveRestColor,
                              "0x\(String(hid, radix: 16)) did not light")
            XCTAssertEqual(engine.lastReactivePress()?.hid, hid)
        }
    }

    func testClearingForgetsEverything() {
        let engine = LightingEngine(device: ApexDevice())
        engine.registerKeyPress(hid: 0x04)
        engine.clearReactiveHits()
        XCTAssertTrue(engine.reactiveSnapshot().isEmpty)
        XCTAssertNil(engine.lastReactivePress())
    }

    // MARK: - Ripple

    /// Distance from the pressed key, in key units, for a key on the same row.
    private func rippleFrame(at now: Double, ripple: Double = 1.0,
                             fade: Double = 0.5) -> [UInt8: LEDColor] {
        // G (0x0A) sits in the middle of the home row, so a ripple from it has
        // room to travel in every direction.
        LightingRender.render(config: reactiveConfig(fade: fade, ripple: ripple),
                              time: 0, hits: [0x0A: 100], now: now)
    }

    func testARippleReachesKeysTheUserNeverPressed() {
        let config = reactiveConfig(fade: 0.5, ripple: 1.0)
        let rest = config.reactiveRestColor
        // Somewhere in the middle of the wave's life, at least one key that was
        // not struck must be lit. Sampled across the fade because the crest is
        // only over any given key briefly.
        let lit = stride(from: 100.02, through: 100.48, by: 0.02).contains { now in
            let frame = rippleFrame(at: now)
            return frame.contains { $0.key != 0x0A && $0.value != rest }
        }
        XCTAssertTrue(lit, "the ripple never lit a neighbouring key")
    }

    func testTheRippleTravelsOutwards() {
        // The crest should reach a near key before a far one. A wave that lit
        // both at once would be a flash, not a ripple.
        func peakTime(for hid: UInt8) -> Double? {
            let rest = reactiveConfig(fade: 0.5, ripple: 1.0).reactiveRestColor
            var best: (time: Double, level: Int)?
            for step in 1...48 {
                let now = 100 + Double(step) * 0.01
                guard let c = rippleFrame(at: now)[hid], c != rest else { continue }
                let level = Int(c.r)
                if best == nil || level > best!.level { best = (now, level) }
            }
            return best?.time
        }
        // H is one key from G; the Escape key is right across the board.
        guard let near = peakTime(for: 0x0B), let far = peakTime(for: 0x29) else {
            return XCTFail("the ripple did not reach both keys")
        }
        XCTAssertLessThan(near, far, "the far key lit no later than the near one")
    }

    func testRippleOffLeavesOnlyTheStruckKeyLit() {
        let config = reactiveConfig(fade: 0.5, ripple: 0)
        let rest = config.reactiveRestColor
        for step in 0...48 {
            let frame = LightingRender.render(config: config, time: 0, hits: [0x0A: 100],
                                              now: 100 + Double(step) * 0.01)
            let strays = frame.filter { $0.key != 0x0A && $0.value != rest }
            XCTAssertTrue(strays.isEmpty, "ripple 0 lit \(strays.count) other keys")
        }
    }

    func testTheStruckKeyIsAlwaysAtLeastAsBrightAsItsOwnRipple() {
        // The origin must not be dimmed by the ring passing over it, or a press
        // would visibly flicker at the moment it lands.
        let config = reactiveConfig(fade: 0.5, ripple: 1.0)
        let frame = LightingRender.render(config: config, time: 0, hits: [0x0A: 100], now: 100)
        XCTAssertEqual(frame[0x0A], config.baseColor)
    }

    func testRipplesFromSeveralKeysCoexist() {
        let config = reactiveConfig(fade: 0.5, ripple: 1.0)
        let rest = config.reactiveRestColor
        let frame = LightingRender.render(config: config, time: 0,
                                          hits: [0x04: 100, 0x45: 100], now: 100)
        XCTAssertNotEqual(frame[0x04], rest)
        XCTAssertNotEqual(frame[0x45], rest)
    }

    func testEveryLEDIsStillAddressedWithARippleRunning() {
        // A partial frame leaves whatever was on the board before, so this holds
        // for every effect and every moment of the animation.
        let frame = rippleFrame(at: 100.2)
        XCTAssertEqual(Set(frame.keys), ApexProTKLGen3.ledHIDCodeSet)
    }

    func testAPressOnAKeyThisBoardDoesNotHaveIsHarmless() {
        // The listener reports whatever the Mac's own keyboard produces — F16,
        // a keypad, an ISO key on an ANSI board. None of those have a position
        // here, so they cannot be a ripple origin and must not corrupt the frame.
        XCTAssertNil(ApexProTKLGen3.key(forHID: 0x6B), "0x6B was expected to be absent")
        let config = reactiveConfig(fade: 0.5, ripple: 1.0)
        let rest = config.reactiveRestColor
        let frame = LightingRender.render(config: config, time: 0, hits: [0x6B: 100], now: 100.05)
        XCTAssertEqual(Set(frame.keys), ApexProTKLGen3.ledHIDCodeSet)
        XCTAssertTrue(frame.values.allSatisfy { $0 == rest }, "a key that is not on the board lit something")
    }

    // MARK: - Timing

    func testTheClockOnlyMovesForwards() {
        // Fades are aged against this. `Date` steps backwards when the system
        // clock is corrected, which freezes every fade until real time catches
        // up — a bug that would only ever appear on someone else's machine.
        let a = MonotonicClock.now
        let b = MonotonicClock.now
        XCTAssertGreaterThanOrEqual(b, a)
    }

    // MARK: - Colour blending

    func testMixEndpointsAreExact() {
        let a = LEDColor(r: 10, g: 20, b: 30)
        let b = LEDColor(r: 200, g: 100, b: 50)
        XCTAssertEqual(a.mixed(with: b, amount: 0), a)
        XCTAssertEqual(a.mixed(with: b, amount: 1), b)
        XCTAssertEqual(a.mixed(with: b, amount: 2), b, "out-of-range amounts clamp")
        XCTAssertEqual(a.mixed(with: b, amount: -1), a)
    }

    func testMixIsHalfwayAtAHalf() {
        let mid = LEDColor(r: 0, g: 0, b: 0).mixed(with: LEDColor(r: 255, g: 100, b: 10), amount: 0.5)
        XCTAssertEqual(mid, LEDColor(r: 128, g: 50, b: 5))
    }

    // MARK: - Config compatibility

    func testProfilesWrittenBeforeTheRestingGlowExistedStillLoad() {
        let json = #"{"kind":"Reactive","reactiveFade":0.4}"#.data(using: .utf8)!
        let config = try? JSONDecoder().decode(LightingConfig.self, from: json)
        XCTAssertEqual(config?.kind, .reactive)
        XCTAssertEqual(config?.reactiveFade, 0.4)
        XCTAssertEqual(config?.reactiveRestLevel, 0.06, "must keep the look it had before the control existed")
    }
}
