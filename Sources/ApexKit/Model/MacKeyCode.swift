import Foundation

/// macOS virtual key codes ↔ USB HID Keyboard/Keypad usages (page 0x07).
///
/// A macOS virtual key code identifies a **physical position** on the keyboard,
/// not the character it produces: `kVK_ANSI_Z` is 0x06 whether the active input
/// source is QWERTY, AZERTY or Dvorak. That is exactly the right currency for
/// this app, because a remap written into the keyboard is a HID usage — also a
/// physical position — and the host applies its own layout afterwards. Reading
/// `NSEvent.characters` instead would bake the user's current input source into
/// the binding, so that recording Z on an AZERTY Mac would remap the key to W.
///
/// The values pair Apple's `HIToolbox/Events.h` `kVK_*` constants with the HID Usage
/// Tables §10 keyboard page. Every pair agrees with the mac and USB columns of
/// Chromium's `ui/events/keycodes/dom/dom_code_data.inc` (BSD-3-Clause, © The Chromium
/// Authors); `THIRD-PARTY-NOTICES.md` reproduces that licence.
public enum MacKeyCode {

    /// Virtual key code → HID usage. Physical keys only; keys that carry no HID
    /// keyboard usage (the `fn` key, the brightness/volume strip on a Mac
    /// laptop) are deliberately absent — see `nonKeyboardVirtualCodes`.
    public static let toHID: [UInt16: UInt8] = {
        var m: [UInt16: UInt8] = [:]

        // Letters
        let letters: [(UInt16, UInt8)] = [
            (0x00, 0x04), (0x0B, 0x05), (0x08, 0x06), (0x02, 0x07), (0x0E, 0x08),
            (0x03, 0x09), (0x05, 0x0A), (0x04, 0x0B), (0x22, 0x0C), (0x26, 0x0D),
            (0x28, 0x0E), (0x25, 0x0F), (0x2E, 0x10), (0x2D, 0x11), (0x1F, 0x12),
            (0x23, 0x13), (0x0C, 0x14), (0x0F, 0x15), (0x01, 0x16), (0x11, 0x17),
            (0x20, 0x18), (0x09, 0x19), (0x0D, 0x1A), (0x07, 0x1B), (0x10, 0x1C),
            (0x06, 0x1D),
        ]
        for (vk, hid) in letters { m[vk] = hid }

        // Digit row, in 1…9,0 order to match the HID page
        let digits: [(UInt16, UInt8)] = [
            (0x12, 0x1E), (0x13, 0x1F), (0x14, 0x20), (0x15, 0x21), (0x17, 0x22),
            (0x16, 0x23), (0x1A, 0x24), (0x1C, 0x25), (0x19, 0x26), (0x1D, 0x27),
        ]
        for (vk, hid) in digits { m[vk] = hid }

        // Editing, punctuation and the main-block specials
        let main: [(UInt16, UInt8)] = [
            (0x24, 0x28),   // Return
            (0x35, 0x29),   // Escape
            (0x33, 0x2A),   // Delete (Backspace)
            (0x30, 0x2B),   // Tab
            (0x31, 0x2C),   // Space
            (0x1B, 0x2D),   // -
            (0x18, 0x2E),   // =
            (0x21, 0x2F),   // [
            (0x1E, 0x30),   // ]
            (0x2A, 0x31),   // \
            (0x29, 0x33),   // ;
            (0x27, 0x34),   // '
            (0x32, 0x35),   // `
            (0x2B, 0x36),   // ,
            (0x2F, 0x37),   // .
            (0x2C, 0x38),   // /
            (0x39, 0x39),   // Caps Lock
            (0x0A, 0x64),   // kVK_ISO_Section — the extra key left of Z on ISO boards
            (0x6E, 0x65),   // kVK_ContextMenu → Application
        ]
        for (vk, hid) in main { m[vk] = hid }

        // Function row. Apple's numbering is famously unordered.
        let functions: [(UInt16, UInt8)] = [
            (0x7A, 0x3A), (0x78, 0x3B), (0x63, 0x3C), (0x76, 0x3D), (0x60, 0x3E),
            (0x61, 0x3F), (0x62, 0x40), (0x64, 0x41), (0x65, 0x42), (0x6D, 0x43),
            (0x67, 0x44), (0x6F, 0x45),
            // F13…F20
            (0x69, 0x68), (0x6B, 0x69), (0x71, 0x6A), (0x6A, 0x6B), (0x40, 0x6C),
            (0x4F, 0x6D), (0x50, 0x6E), (0x5A, 0x6F),
        ]
        for (vk, hid) in functions { m[vk] = hid }

        // Navigation cluster. macOS labels 0x72 "Help"; on a PC keyboard that
        // physical position is Insert, and Insert is what the firmware sends.
        let navigation: [(UInt16, UInt8)] = [
            (0x72, 0x49), (0x73, 0x4A), (0x74, 0x4B), (0x75, 0x4C),
            (0x77, 0x4D), (0x79, 0x4E),
            (0x7C, 0x4F), (0x7B, 0x50), (0x7D, 0x51), (0x7E, 0x52),
        ]
        for (vk, hid) in navigation { m[vk] = hid }

        // Keypad. kVK_ANSI_KeypadClear sits where Num Lock does on a PC board.
        let keypad: [(UInt16, UInt8)] = [
            (0x47, 0x53), (0x4B, 0x54), (0x43, 0x55), (0x4E, 0x56), (0x45, 0x57),
            (0x4C, 0x58),
            (0x53, 0x59), (0x54, 0x5A), (0x55, 0x5B), (0x56, 0x5C), (0x57, 0x5D),
            (0x58, 0x5E), (0x59, 0x5F), (0x5B, 0x60), (0x5C, 0x61), (0x52, 0x62),
            (0x41, 0x63), (0x51, 0x67),
            (0x5F, 0x85),   // kVK_JIS_KeypadComma
        ]
        for (vk, hid) in keypad { m[vk] = hid }

        // Japanese keyboards
        let jis: [(UInt16, UInt8)] = [
            (0x5E, 0x87),   // kVK_JIS_Underscore → International 1 (ろ)
            (0x5D, 0x89),   // kVK_JIS_Yen        → International 3 (¥)
            (0x68, 0x90),   // kVK_JIS_Kana       → Lang 1
            (0x66, 0x91),   // kVK_JIS_Eisu       → Lang 2
        ]
        for (vk, hid) in jis { m[vk] = hid }

        // Modifiers. These arrive as `.flagsChanged`, never `.keyDown`.
        let modifiers: [(UInt16, UInt8)] = [
            (0x3B, HIDUsage.leftControl), (0x38, HIDUsage.leftShift),
            (0x3A, HIDUsage.leftAlt), (0x37, HIDUsage.leftGUI),
            (0x3E, HIDUsage.rightControl), (0x3C, HIDUsage.rightShift),
            (0x3D, HIDUsage.rightAlt), (0x36, HIDUsage.rightGUI),
        ]
        for (vk, hid) in modifiers { m[vk] = hid }

        return m
    }()

    /// Virtual codes that are real keys but carry no HID keyboard usage, so a
    /// recorder should ignore them silently rather than complain.
    ///
    /// `fn` has no usage on the keyboard page at all; the volume and mute keys
    /// on an Apple keyboard are consumer-page usages, which a *keyboard*
    /// mapping cannot express (the Media category exists for those).
    public static let nonKeyboardVirtualCodes: Set<UInt16> = [
        0x3F,           // kVK_Function
        0x48, 0x49, 0x4A,   // kVK_VolumeUp / VolumeDown / Mute
    ]

    public static func hid(for virtualKeyCode: UInt16) -> UInt8? { toHID[virtualKeyCode] }

    /// HID usage → virtual key code. Only meaningful for usages a Mac keyboard
    /// can actually produce; used to show "you can press this" affordances.
    public static let fromHID: [UInt8: UInt16] = {
        var m: [UInt8: UInt16] = [:]
        for (vk, hid) in toHID where m[hid] == nil || vk < m[hid]! { m[hid] = vk }
        return m
    }()

    /// Which of the eight modifier usages a `flagsChanged` event turned on, when
    /// the event's own key code identifies a modifier.
    public static func modifierUsage(forVirtualKeyCode code: UInt16) -> UInt8? {
        guard let usage = toHID[code], HIDUsage.isModifier(usage) else { return nil }
        return usage
    }

    /// `kVK_CapsLock`. Caps Lock arrives as `flagsChanged` like a modifier but
    /// carries no modifier usage, so it needs handling of its own.
    public static let capsLockVirtualCode: UInt16 = 0x39

    /// The per-side modifier bits macOS puts in an event's flags — the
    /// `NX_DEVICE*` masks from IOKit's `IOLLEvent.h`.
    ///
    /// The public `CGEventFlags` masks cannot answer "which key was just
    /// pressed": `.maskShift` is set while *either* shift is held, so tapping
    /// right shift with left shift already down leaves the flag unchanged and
    /// the press invisible. The device bits name the physical side, which is
    /// exactly the currency a per-key effect needs.
    public static func deviceFlagMask(forModifierUsage usage: UInt8) -> UInt64? {
        switch usage {
        case HIDUsage.leftControl:  return 0x0000_0001
        case HIDUsage.leftShift:    return 0x0000_0002
        case HIDUsage.rightShift:   return 0x0000_0004
        case HIDUsage.leftGUI:      return 0x0000_0008
        case HIDUsage.rightGUI:     return 0x0000_0010
        case HIDUsage.leftAlt:      return 0x0000_0020
        case HIDUsage.rightAlt:     return 0x0000_0040
        case HIDUsage.rightControl: return 0x0000_2000
        default: return nil
        }
    }

    /// The key a `flagsChanged` event reports as *pressed*, or nil if the event
    /// is a release (or is not a key this keyboard has).
    ///
    /// Modifiers never produce `keyDown`, so without this a reactive effect
    /// stays dark for a fifth of the board — every shift, control, option and
    /// command press.
    ///
    /// - Parameter flags: `CGEvent.flags.rawValue`, which carries the device
    ///   bits above alongside the public masks.
    public static func pressedUsage(forFlagsChanged virtualKeyCode: UInt16, flags: UInt64) -> UInt8? {
        // Caps Lock is a toggle, so both switching it on and switching it off
        // are presses of the key. There is no "released" edge to skip.
        if virtualKeyCode == capsLockVirtualCode { return toHID[capsLockVirtualCode] }
        guard let usage = modifierUsage(forVirtualKeyCode: virtualKeyCode),
              let mask = deviceFlagMask(forModifierUsage: usage) else { return nil }
        return (flags & mask) != 0 ? usage : nil
    }
}
