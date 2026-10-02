import XCTest
@testable import ApexKit

/// The tables and rules behind "press the key you want".
///
/// These exist because the feature they support failed silently in the field:
/// a recorder that only watched `keyDown` could never see a modifier being
/// pressed on its own, and a keycode table with holes in it swallowed the press
/// and went on waiting. Both failures look identical from the outside — the
/// button just never stops — so both are pinned down here.
final class MacKeyCodeTests: XCTestCase {

    // MARK: Coverage

    func testEveryKeyOnTheApexHasAVirtualKeyCode() {
        // If a key on this board cannot be produced by pressing the equivalent
        // key on a Mac keyboard, recording it is impossible and the picker is
        // the only way to reach it. That is true of nothing on an ANSI board.
        let unreachable = ApexProTKLGen3.keys(for: .ansi)
            .filter { HIDUsage.isKeyboardUsage($0.hid) }
            .filter { MacKeyCode.fromHID[$0.hid] == nil }
            .map(\.label)
        XCTAssertEqual(unreachable, [], "no Mac key produces: \(unreachable)")
    }

    func testTableIsInjective() {
        // Two physical keys mapping to one usage would make a recording
        // ambiguous and a reverse lookup a coin toss.
        var seen: [UInt8: UInt16] = [:]
        for (vk, hid) in MacKeyCode.toHID {
            if let other = seen[hid] {
                XCTFail(String(format: "usage 0x%02X claimed by key codes %d and %d", hid, other, vk))
            }
            seen[hid] = vk
        }
    }

    func testAllMappedUsagesAreRealKeyboardUsages() {
        for (vk, hid) in MacKeyCode.toHID {
            XCTAssertTrue(HIDUsage.isKeyboardUsage(hid),
                          String(format: "key code %d maps to 0x%02X, not a keyboard usage", vk, hid))
        }
    }

    // MARK: Spot checks against Apple's kVK_* constants

    func testLetterAndDigitRowsMatchCarbonConstants() {
        XCTAssertEqual(MacKeyCode.hid(for: 0x00), 0x04)   // kVK_ANSI_A
        XCTAssertEqual(MacKeyCode.hid(for: 0x06), 0x1D)   // kVK_ANSI_Z
        XCTAssertEqual(MacKeyCode.hid(for: 0x12), 0x1E)   // kVK_ANSI_1
        XCTAssertEqual(MacKeyCode.hid(for: 0x1D), 0x27)   // kVK_ANSI_0 → HID "0" is last
        XCTAssertEqual(MacKeyCode.hid(for: 0x16), 0x23)   // kVK_ANSI_6, out of order in Apple's table
        XCTAssertEqual(MacKeyCode.hid(for: 0x17), 0x22)   // kVK_ANSI_5
    }

    func testFunctionRowMatchesCarbonConstants() {
        XCTAssertEqual(MacKeyCode.hid(for: 0x7A), 0x3A)   // kVK_F1
        XCTAssertEqual(MacKeyCode.hid(for: 0x6F), 0x45)   // kVK_F12
        XCTAssertEqual(MacKeyCode.hid(for: 0x69), 0x68)   // kVK_F13
        XCTAssertEqual(MacKeyCode.hid(for: 0x5A), 0x6F)   // kVK_F20
    }

    func testKeysTheOldTableMissedAreCovered() {
        // Every one of these used to make the recorder beep and keep waiting.
        XCTAssertEqual(MacKeyCode.hid(for: 0x0A), 0x64)   // kVK_ISO_Section
        XCTAssertEqual(MacKeyCode.hid(for: 0x52), 0x62)   // kVK_ANSI_Keypad0
        XCTAssertEqual(MacKeyCode.hid(for: 0x4C), 0x58)   // kVK_ANSI_KeypadEnter
        XCTAssertEqual(MacKeyCode.hid(for: 0x47), 0x53)   // kVK_ANSI_KeypadClear → Num Lock
        XCTAssertEqual(MacKeyCode.hid(for: 0x6E), 0x65)   // kVK_ContextMenu → Application
        XCTAssertEqual(MacKeyCode.hid(for: 0x5D), 0x89)   // kVK_JIS_Yen
        XCTAssertEqual(MacKeyCode.hid(for: 0x68), 0x90)   // kVK_JIS_Kana → Lang 1
    }

    func testModifiersKeepTheirSide() {
        XCTAssertEqual(MacKeyCode.hid(for: 0x38), HIDUsage.leftShift)
        XCTAssertEqual(MacKeyCode.hid(for: 0x3C), HIDUsage.rightShift)
        XCTAssertEqual(MacKeyCode.hid(for: 0x37), HIDUsage.leftGUI)
        XCTAssertEqual(MacKeyCode.hid(for: 0x36), HIDUsage.rightGUI)
        XCTAssertEqual(MacKeyCode.modifierUsage(forVirtualKeyCode: 0x3E), HIDUsage.rightControl)
        XCTAssertNil(MacKeyCode.modifierUsage(forVirtualKeyCode: 0x00))
    }

    func testKeysWithNoKeyboardSignalAreCalledOutRatherThanMapped() {
        // The recorder tells the user why these do nothing instead of appearing
        // to hang, which is only possible if they are listed rather than absent.
        for code in MacKeyCode.nonKeyboardVirtualCodes {
            XCTAssertNil(MacKeyCode.hid(for: code))
        }
        XCTAssertTrue(MacKeyCode.nonKeyboardVirtualCodes.contains(0x3F))   // kVK_Function
    }
}

// MARK: - Combinations

final class HIDUsageCombinationTests: XCTestCase {

    func testCanonicalOrdersModifiersInMacReadingOrder() {
        let chord = HIDUsage.canonical([0x06, HIDUsage.leftGUI, HIDUsage.leftShift, HIDUsage.leftControl])
        XCTAssertEqual(chord, [HIDUsage.leftControl, HIDUsage.leftShift, HIDUsage.leftGUI, 0x06])
    }

    func testCanonicalIsIdempotentAndOrderIndependent() {
        let a = HIDUsage.canonical([HIDUsage.leftShift, 0x04, HIDUsage.leftAlt])
        let b = HIDUsage.canonical([0x04, HIDUsage.leftAlt, HIDUsage.leftShift])
        XCTAssertEqual(a, b)
        XCTAssertEqual(HIDUsage.canonical(a), a)
    }

    func testCanonicalDropsDuplicatesAndZeroes() {
        XCTAssertEqual(HIDUsage.canonical([0x04, 0x00, 0x04]), [0x04])
    }

    func testCanonicalKeepsRightHandModifiersDistinct() {
        let chord = HIDUsage.canonical([HIDUsage.rightAlt, HIDUsage.leftAlt, 0x04])
        XCTAssertEqual(chord, [HIDUsage.leftAlt, HIDUsage.rightAlt, 0x04])
    }

    func testKeyboardUsagesExcludeTheBoardsOwnControlCodes() {
        // 0xF0 addresses the SteelSeries key and 0xFB the play/pause button.
        // Both are real addresses on this keyboard and meaningless to a host,
        // so neither may ever become the thing a key sends.
        XCTAssertFalse(HIDUsage.isKeyboardUsage(0xF0))
        XCTAssertFalse(HIDUsage.isKeyboardUsage(0xFB))
        XCTAssertTrue(HIDUsage.isKeyboardUsage(0x04))
        XCTAssertTrue(HIDUsage.isKeyboardUsage(HIDUsage.rightGUI))
    }
}

// MARK: - Search

final class HIDUsageSearchTests: XCTestCase {

    func testEmptyQueryBrowsesEverything() {
        XCTAssertEqual(HIDUsage.search("").count, HIDUsage.catalogue.count)
        XCTAssertFalse(HIDUsage.catalogue.isEmpty)
    }

    func testExactNameOutranksEverythingElse() {
        // Typing "a" must find the A key, not bury it under "Caps Lock".
        XCTAssertEqual(HIDUsage.search("a").first?.usage, 0x04)
    }

    func testFindsKeysByTheWordPeopleActuallyUse() {
        XCTAssertEqual(HIDUsage.search("command").first?.usage, HIDUsage.leftGUI)
        XCTAssertEqual(HIDUsage.search("option").first?.usage, HIDUsage.leftAlt)
        XCTAssertEqual(HIDUsage.search("esc").first?.usage, 0x29)
        XCTAssertEqual(HIDUsage.search("backspace").first?.usage, 0x2A)
        XCTAssertEqual(HIDUsage.search("page up").first?.usage, 0x4B)
    }

    func testFindsAUsageByItsCode() {
        XCTAssertEqual(HIDUsage.search("0x1A").first?.usage, 0x1A)
        XCTAssertEqual(HIDUsage.search("1a").first?.usage, 0x1A)
    }

    func testUnknownQueryReturnsNothingRatherThanEverything() {
        XCTAssertTrue(HIDUsage.search("zzzzz").isEmpty)
    }

    func testCatalogueHasNoDuplicateUsages() {
        let usages = HIDUsage.catalogue.map(\.usage)
        XCTAssertEqual(Set(usages).count, usages.count)
    }

    func testEveryCatalogueEntryHasARealName() {
        for entry in HIDUsage.catalogue {
            XCTAssertFalse(entry.name.hasPrefix("HID 0x"),
                           String(format: "usage 0x%02X is offered in the picker with no name",
                                  entry.usage))
        }
    }
}

// MARK: - Reading a binding back into an editor

/// The rule that decides what the bindings editor shows for a key.
///
/// The bug these pin down was visible on every one of the eight modifier keys:
/// the editor reported that Left Shift sent "⇧ A", because the resting state of
/// a key is a mapping to *itself* and the old split treated "no non-modifier
/// usage" as "no key at all", then filled the gap with whichever letter it had
/// last shown. Choosing that key and touching anything wrote the lie back.
final class KeyboardCombinationTests: XCTestCase {

    func testAnOrdinaryKeyIsItsOwnBaseWithNoModifiers() {
        let split = Mappings.Layer.normal.blankBinding(forHID: 0x1A).keyboardCombination
        XCTAssertEqual(split.base, 0x1A)
        XCTAssertEqual(split.modifiers, [])
    }

    func testAModifierKeyAtRestSendsThatModifierAndHoldsNothing() {
        for modifier in HIDUsage.modifiers {
            let split = Mappings.Layer.normal.blankBinding(forHID: modifier).keyboardCombination
            XCTAssertEqual(split.base, modifier,
                           "\(HIDUsage.name(modifier)) should send itself")
            XCTAssertEqual(split.modifiers, [],
                           "\(HIDUsage.name(modifier)) should not be shown as held with something")
        }
    }

    func testACombinationSplitsIntoModifiersAndAKey() {
        let split = Mappings.Binding.keyboard(usages: [HIDUsage.leftGUI, HIDUsage.leftShift, 0x21])
            .keyboardCombination
        XCTAssertEqual(split.base, 0x21)
        XCTAssertEqual(split.modifiers, [HIDUsage.leftShift, HIDUsage.leftGUI])
    }

    func testAChordOfModifiersKeepsTheLastAsTheKey() {
        // ⌃ held with Shift: two modifiers, but one of them is what the key
        // sends. Anything else would leave the combination unrepresentable.
        let split = Mappings.Binding.keyboard(usages: [HIDUsage.leftControl, HIDUsage.leftShift])
            .keyboardCombination
        XCTAssertEqual(split.base, HIDUsage.leftShift)
        XCTAssertEqual(split.modifiers, [HIDUsage.leftControl])
    }

    func testADisabledKeyHasNoCombinationAtAll() {
        let split = Mappings.Binding.disabled.keyboardCombination
        XCTAssertNil(split.base)
        XCTAssertEqual(split.modifiers, [])
    }

    func testANonKeyboardBindingHasNoCombination() {
        XCTAssertNil(Mappings.Binding.consumer(.playPause).keyboardCombination.base)
        XCTAssertNil(Mappings.Binding.mouse(.button1).keyboardCombination.base)
        XCTAssertNil(Mappings.Binding.unbound.keyboardCombination.base)
    }

    func testRoundTripThroughTheEditorChangesNothing() {
        // Opening the editor on a key and writing back what it shows must be a
        // no-op for every key on the board: that is what makes it safe for
        // choosing a category not to be a change.
        for key in ApexProTKLGen3.keys where key.isMappable {
            let resting = Mappings.Layer.normal.blankBinding(forHID: key.hid)
            let split = resting.keyboardCombination
            guard let base = split.base else { continue }
            let rewritten = Mappings.Binding.keyboard(usages: split.modifiers + [base])
            XCTAssertEqual(rewritten, resting, "editing \(key.label) round-trips to something else")
        }
    }

    func testReadBackComparisonIgnoresTheOrderOfAChord() {
        // Whatever wrote the keyboard last was under no obligation to order the
        // four bytes the way this app does.
        let mine = Mappings.Binding.keyboard(usages: [HIDUsage.leftGUI, 0x06])
        let theirs = Mappings.Binding(function: 0x51, keyCodes: [0x06, HIDUsage.leftGUI, 0, 0])
        XCTAssertNotEqual(mine, theirs)
        XCTAssertTrue(Mappings.equivalent(mine, theirs))
        XCTAssertFalse(Mappings.equivalent(mine, Mappings.Binding.keyboard(usages: [0x06])))
    }
}

// MARK: - What a write is allowed to destroy

/// The rules that stop a complete-frame write from erasing something no one can
/// put back. Every one of these was, at some point, wrong in a way that cost
/// the user hardware state rather than an error message.
final class MappingWriteSafetyTests: XCTestCase {

    func testTheFnLayerIsNeverWrittenBeforeItHasBeenRead() {
        // The nine factory 0x62 shortcuts live only on the keyboard. A frame
        // built without them is a frame that deletes them.
        XCTAssertFalse(Mappings.Layer.meta.isSafeToWriteUnread)
    }

    func testTheOtherLayersAreSafeToWriteUnread() {
        // Their blanks are the factory resting state, so an unmentioned key is
        // restored rather than lost.
        XCTAssertTrue(Mappings.Layer.normal.isSafeToWriteUnread)
        XCTAssertTrue(Mappings.Layer.secondActuation.isSafeToWriteUnread)
        XCTAssertEqual(Mappings.Layer.normal.blankBinding(forHID: 0x1A),
                       Mappings.Binding.keyboard(usage: 0x1A))
        XCTAssertEqual(Mappings.Layer.secondActuation.blankBinding(forHID: 0x1A), .unbound)
    }

    func testAnUnreadFnLayerWouldHaveErasedEveryFactoryShortcut() {
        // What the old guard permitted, stated as the consequence rather than
        // the condition: one binding, no read, ninety keys blanked.
        let mine: [UInt8: Mappings.Binding] = [0x04: .keyboard(usage: 0x05)]
        let chunk = Mappings.writeChunks(layer: .meta, bindings: mine)[0]
        let count = Int(chunk[2])
        var blanked = 0
        for i in 0..<count where chunk[3 + i * 6] != 0x04 {
            if chunk[3 + i * 6 + 1] == Mappings.Function.unbound.rawValue { blanked += 1 }
        }
        XCTAssertEqual(blanked, count - 1)
    }

    func testTooManyUsagesDropModifiersRatherThanTheKey() {
        // ⌃⌥⇧⌘K is five usages in four bytes. Dropping K leaves a chord that
        // presses nothing while the editor still shows K.
        let b = Mappings.Binding.keyboard(usages: [
            HIDUsage.leftControl, HIDUsage.leftAlt, HIDUsage.leftShift, HIDUsage.leftGUI, 0x0E,
        ])
        XCTAssertEqual(b.keyCodes.count, 4)
        XCTAssertTrue(b.keyCodes.contains(0x0E), "the key itself must survive the four-byte limit")
        XCTAssertEqual(b.keyboardCombination.base, 0x0E)
        XCTAssertEqual(b.keyboardCombination.modifiers.count, 3)
    }

    func testFourUsagesExactlyAreAllKept() {
        let b = Mappings.Binding.keyboard(usages: [
            HIDUsage.leftControl, HIDUsage.leftShift, HIDUsage.leftGUI, 0x0E,
        ])
        XCTAssertEqual(b.keyCodes, [HIDUsage.leftControl, HIDUsage.leftShift, HIDUsage.leftGUI, 0x0E])
    }

    func testTheDeeperLayerOnlyAddressesTheAdjustableKeys() {
        // A mechanical key accepted onto this layer would sit in the
        // configuration forever and never reach the keyboard.
        XCTAssertEqual(Mappings.Layer.secondActuation.hidOrder, ApexProTKLGen3.analogHIDOrder)
        XCTAssertEqual(Mappings.Layer.secondActuation.hidOrder.count, 68)
        XCTAssertFalse(Mappings.Layer.secondActuation.hidOrder.contains(0x29))   // Esc, mechanical
    }
}
