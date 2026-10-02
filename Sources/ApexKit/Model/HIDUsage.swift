import Foundation

/// USB HID **Keyboard/Keypad** usage page (0x07) — the code space used both to
/// address keys on this keyboard and to describe what a remapped key should
/// send.
///
/// A remap target is not limited to the keys the Apex physically has: binding a
/// key to F13 or to a keypad usage is perfectly legal and the host will see it,
/// which is why this table is broader than `ApexProTKLGen3.keys`.
public enum HIDUsage {

    // MARK: - Modifiers

    /// The eight modifier usages, in HID bit order (Ctrl, Shift, Alt, GUI —
    /// left then right).
    public static let leftControl: UInt8 = 0xE0
    public static let leftShift: UInt8 = 0xE1
    public static let leftAlt: UInt8 = 0xE2
    public static let leftGUI: UInt8 = 0xE3
    public static let rightControl: UInt8 = 0xE4
    public static let rightShift: UInt8 = 0xE5
    public static let rightAlt: UInt8 = 0xE6
    public static let rightGUI: UInt8 = 0xE7

    public static let modifiers: [UInt8] = [
        leftControl, leftShift, leftAlt, leftGUI,
        rightControl, rightShift, rightAlt, rightGUI,
    ]

    public static func isModifier(_ usage: UInt8) -> Bool { (0xE0...0xE7).contains(usage) }

    /// True for codes the HID keyboard page actually defines as a key.
    ///
    /// The Apex addresses a few of its own controls with codes outside that
    /// range — `0xF0` for the SteelSeries key, `0xFB` for play/pause — which are
    /// valid *addresses* on this keyboard but meaningless as something to send
    /// to a host, so they can be remapped but never be a remap target.
    public static func isKeyboardUsage(_ usage: UInt8) -> Bool {
        (0x04...0xA4).contains(usage) || (0xE0...0xE7).contains(usage)
    }

    /// Mac convention orders modifiers ⌃⌥⇧⌘, left before right.
    public static func modifierRank(_ usage: UInt8) -> Int {
        switch usage {
        case leftControl: return 0
        case rightControl: return 1
        case leftAlt: return 2
        case rightAlt: return 3
        case leftShift: return 4
        case rightShift: return 5
        case leftGUI: return 6
        case rightGUI: return 7
        default: return 8
        }
    }

    /// De-duplicate a combination and put it in one predictable order:
    /// modifiers first in ⌃⌥⇧⌘ order, then the rest as given.
    ///
    /// Writes go to hardware, so "the same combination" must always produce the
    /// same four bytes — otherwise a read-back comparison reports a mismatch
    /// against a binding that is in fact identical, and profiles that should be
    /// equal compare unequal.
    public static func canonical(_ usages: [UInt8]) -> [UInt8] {
        var seen = Set<UInt8>()
        let unique = usages.filter { $0 != 0 && seen.insert($0).inserted }
        let mods = unique.filter(isModifier).sorted { modifierRank($0) < modifierRank($1) }
        return mods + unique.filter { !isModifier($0) }
    }

    // MARK: - Names

    private static let names: [UInt8: String] = {
        var m: [UInt8: String] = [
            0x00: "None",
            0x28: "Return", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
            0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x32: "# (ISO)",
            0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
            0x39: "Caps Lock",
            0x46: "Print Screen", 0x47: "Scroll Lock", 0x48: "Pause",
            0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete",
            0x4D: "End", 0x4E: "Page Down",
            0x4F: "Right Arrow", 0x50: "Left Arrow", 0x51: "Down Arrow", 0x52: "Up Arrow",
            0x53: "Num Lock",
            0x54: "Keypad /", 0x55: "Keypad *", 0x56: "Keypad -", 0x57: "Keypad +",
            0x58: "Keypad Enter", 0x63: "Keypad .", 0x85: "Keypad ,",
            0x64: "\\ (ISO)", 0x65: "Application", 0x66: "Power", 0x67: "Keypad =",
            0x75: "Help", 0x76: "Menu", 0x77: "Select", 0x78: "Stop", 0x79: "Again",
            0x7A: "Undo", 0x7B: "Cut", 0x7C: "Copy", 0x7D: "Paste", 0x7E: "Find",
            0x7F: "Mute", 0x80: "Volume Up", 0x81: "Volume Down",
            0x87: "International 1", 0x88: "International 2", 0x89: "International 3",
            0x8A: "International 4", 0x8B: "International 5",
            0x90: "Lang 1 (Hangul)", 0x91: "Lang 2 (Hanja)", 0x92: "Lang 3 (Katakana)",
            0x93: "Lang 4 (Hiragana)",
            0xE0: "Left Ctrl", 0xE1: "Left Shift", 0xE2: "Left Alt", 0xE3: "Left Cmd",
            0xE4: "Right Ctrl", 0xE5: "Right Shift", 0xE6: "Right Alt", 0xE7: "Right Cmd",
            0xF0: "SteelSeries Key",
        ]
        // Letters A–Z (0x04…0x1D)
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            m[UInt8(0x04 + i)] = String(ch)
        }
        // Digits 1–9 then 0 (0x1E…0x27)
        for (i, ch) in "1234567890".enumerated() {
            m[UInt8(0x1E + i)] = String(ch)
        }
        // F1–F12 (0x3A…0x45), F13–F24 (0x68…0x73)
        for i in 0..<12 { m[UInt8(0x3A + i)] = "F\(i + 1)" }
        for i in 0..<12 { m[UInt8(0x68 + i)] = "F\(i + 13)" }
        // Keypad 1–9 then 0 (0x59…0x62)
        for i in 0..<9 { m[UInt8(0x59 + i)] = "Keypad \(i + 1)" }
        m[0x62] = "Keypad 0"
        return m
    }()

    public static func name(_ usage: UInt8) -> String {
        names[usage] ?? String(format: "HID 0x%02X", usage)
    }

    /// Usages offered in the "remap to a key" picker, grouped for the UI.
    public struct Group: Identifiable, Sendable {
        public let name: String
        public let usages: [UInt8]
        public var id: String { name }
    }

    public static let pickerGroups: [Group] = [
        Group(name: "Letters", usages: Array(UInt8(0x04)...UInt8(0x1D))),
        Group(name: "Numbers", usages: Array(UInt8(0x1E)...UInt8(0x27))),
        Group(name: "Punctuation", usages: [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x64]),
        Group(name: "Editing", usages: [0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x39, 0x49, 0x4C, 0x4A, 0x4D, 0x4B, 0x4E]),
        Group(name: "Arrows", usages: [0x52, 0x50, 0x51, 0x4F]),
        Group(name: "Function", usages: Array(UInt8(0x3A)...UInt8(0x45)) + Array(UInt8(0x68)...UInt8(0x73))),
        Group(name: "Keypad", usages: [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x67] + Array(UInt8(0x59)...UInt8(0x63))),
        Group(name: "Modifiers", usages: modifiers),
        Group(name: "System", usages: [0x46, 0x47, 0x48, 0x65, 0x75, 0x76, 0x77, 0x7C, 0x7D, 0x7B, 0x7A]),
        Group(name: "International", usages: [0x85, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x90, 0x91, 0x92, 0x93]),
    ]

    // MARK: - Searchable catalogue

    /// One entry in the "what should this key send?" catalogue.
    ///
    /// `aliases` exist so the search field finds a usage by the word the user
    /// actually has in mind: a Mac user looking for `0xE3` types "command", a
    /// Windows user types "win", and neither is the canonical name.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let usage: UInt8
        public let name: String
        public let group: String
        public let aliases: [String]
        public var id: UInt8 { usage }
    }

    private static let aliases: [UInt8: [String]] = [
        0x28: ["enter"], 0x29: ["esc"], 0x2A: ["delete", "backspace", "back space"],
        0x2B: ["tabulator"], 0x2C: ["spacebar", "space bar"],
        0x2D: ["minus", "dash", "hyphen", "underscore"],
        0x2E: ["equals", "plus"], 0x2F: ["left bracket", "open bracket", "brace"],
        0x30: ["right bracket", "close bracket", "brace"],
        0x31: ["backslash", "pipe"], 0x32: ["hash", "number sign", "tilde"],
        0x33: ["semicolon", "colon"], 0x34: ["quote", "apostrophe", "double quote"],
        0x35: ["backtick", "grave", "tilde"], 0x36: ["comma", "less than"],
        0x37: ["period", "full stop", "dot", "greater than"],
        0x38: ["slash", "forward slash", "question mark"],
        0x39: ["caps", "capslock"],
        0x46: ["prtsc", "prt scr", "screenshot", "sysrq"],
        0x49: ["ins"], 0x4A: ["pos1"], 0x4B: ["pgup", "page up", "prior"],
        0x4C: ["forward delete", "del"], 0x4D: ["ende"], 0x4E: ["pgdn", "page down", "next"],
        0x4F: ["right", "→"], 0x50: ["left", "←"], 0x51: ["down", "↓"], 0x52: ["up", "↑"],
        0x53: ["numlock", "clear"],
        0x64: ["iso backslash", "non-us backslash", "section", "§"],
        0x65: ["menu key", "context menu", "right click key"],
        0x66: ["power"],
        0x7F: ["mute"], 0x80: ["vol up", "louder"], 0x81: ["vol down", "quieter"],
        0xE0: ["control", "ctrl", "lctrl", "^"],
        0xE1: ["shift", "lshift", "⇧"],
        0xE2: ["alt", "option", "opt", "lalt", "⌥"],
        0xE3: ["command", "cmd", "meta", "super", "windows", "win", "⌘"],
        0xE4: ["control", "ctrl", "rctrl", "^"],
        0xE5: ["shift", "rshift", "⇧"],
        0xE6: ["alt", "option", "opt", "ralt", "alt gr", "altgr", "⌥"],
        0xE7: ["command", "cmd", "meta", "super", "windows", "win", "⌘"],
        0xF0: ["steelseries", "ss key"],
    ]

    /// Every usage the picker offers, flattened and searchable.
    public static let catalogue: [Entry] = pickerGroups.flatMap { group in
        group.usages.map { Entry(usage: $0, name: name($0), group: group.name,
                                 aliases: aliases[$0] ?? []) }
    }

    /// Ranked search over the catalogue. Empty query returns everything, so a
    /// picker can use one code path for browsing and for searching.
    ///
    /// Ranking puts an exact name match first, then a name prefix, then an alias
    /// prefix, then anything containing the query — otherwise typing "a" would
    /// bury the A key under "Caps Lock" and "Page Up".
    public static func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalogue }

        func rank(_ e: Entry) -> Int? {
            let name = e.name.lowercased()
            if name == q { return 0 }
            if e.aliases.contains(q) { return 1 }
            if name.hasPrefix(q) { return 2 }
            if e.aliases.contains(where: { $0.hasPrefix(q) }) { return 3 }
            if name.contains(q) { return 4 }
            if e.aliases.contains(where: { $0.contains(q) }) { return 5 }
            // "0x1a" / "1a" / "26" address a usage by its code, which is how the
            // protocol docs and the read-back view name them.
            if let byCode = parseUsageCode(q), byCode == e.usage { return 0 }
            return nil
        }

        var ranked: [(entry: Entry, rank: Int)] = []
        for entry in catalogue {
            if let r = rank(entry) { ranked.append((entry, r)) }
        }
        ranked.sort { a, b in
            a.rank == b.rank ? a.entry.usage < b.entry.usage : a.rank < b.rank
        }
        return ranked.map(\.entry)
    }

    /// `"0x1A"`, `"1a"` or `"26"` → a usage code.
    static func parseUsageCode(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt8(t.dropFirst(2), radix: 16) }
        guard t.count == 2, t.allSatisfy(\.isHexDigit) else { return nil }
        return UInt8(t, radix: 16)
    }
}
