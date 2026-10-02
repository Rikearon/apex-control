import Foundation
import ApexKit

// A thin command-line front-end over ApexKit, for driving and verifying the
// keyboard without the GUI.

func usage() {
    print("""
    apexctl — control the SteelSeries Apex Pro TKL Gen 3

    USAGE:
      apexctl info
      apexctl --version
      apexctl solid <#RRGGBB>
      apexctl key <name-or-hid> <#RRGGBB> [<name> <#RRGGBB> ...]
      apexctl rainbow [seconds] [fps]
      apexctl wave [seconds]
      apexctl clear
      apexctl actuation <level 1-40> [--rapid-trigger [sensitivity]]
      apexctl rapidtrigger off

      apexctl bindings [normal|meta|second]        read bindings back off the keyboard
      apexctl bind <key> key <target> [+mods]      e.g. bind Caps key "Left Ctrl"
      apexctl bind <key> media <action>            e.g. bind SS media playPause
      apexctl bind <key> mouse <action>            e.g. bind Caps mouse button4
      apexctl bind <key> disable
      apexctl bind <key> raw <fn-hex> [kc-hex ...]
      apexctl bind --layer meta <key> ...          write to the Fn layer instead
      apexctl unbind <key> [--layer meta|second]
      apexctl reset-bindings                       normal + second layers back to stock (Fn layer kept)
      apexctl fn <key|none>                        pick the Fn (meta) trigger key
      apexctl verify                               write-then-read round-trip self-test

      apexctl profile <0-4>                        switch onboard profile slot
      apexctl profile read [slot] [--out file]     dump a slot's boot profile off the flash
      apexctl profile save [slot]                  persist current bindings into the boot
                                                   profile so they should survive unplugging
      apexctl profile restore <slot> <file>        write a dumped profile image back
      apexctl oled text "<line1>" ["<line2>"]
      apexctl oled image <path>
      apexctl oled clear
      apexctl oled persist text "<line1>" ["<line2>"]
      apexctl oled persist image <path>
      apexctl raw feature <hex bytes...>
      apexctl raw output  <hex bytes...>
      apexctl raw read [length]                    GET_REPORT with no preceding write
      apexctl raw query [--delay ms] [--gets n] [--poll n] <hex bytes...>

    Levels: 1 = 0.1 mm (very sensitive) … 40 = 4.0 mm (deep).
    Modifiers for `bind ... key`: +ctrl +shift +alt +cmd (add `r` for right, e.g. +rshift).
    """)
}

func connectOrExit() -> ApexDevice {
    let dev = ApexDevice()
    let sem = DispatchSemaphore(value: 0)
    dev.onConnectionChange = { connected in if connected { sem.signal() } }
    do { try dev.connect() } catch { fail("connect failed: \(error)") }
    if !dev.isConnected {
        if sem.wait(timeout: .now() + 2.0) == .timedOut {
            fail("No Apex Pro TKL Gen 3 (0x1038:0x1642) found. Is it plugged in?")
        }
    }
    return dev
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

func parseColor(_ s: String) -> LEDColor {
    guard let c = LEDColor(hex: s) else { fail("bad color '\(s)' (use #RRGGBB)") }
    return c
}

/// Resolve a key name (e.g. "W", "Space", "F1") or a hex/decimal HID code.
func resolveHID(_ s: String) -> UInt8 {
    if let k = ApexProTKLGen3.keys.first(where: { $0.label.lowercased() == s.lowercased() }) { return k.hid }
    // Fall back to the full HID usage table so targets the keyboard lacks
    // (F13-F24, keypad) still resolve.
    for group in HIDUsage.pickerGroups {
        if let u = group.usages.first(where: { HIDUsage.name($0).lowercased() == s.lowercased() }) { return u }
    }
    if s.lowercased().hasPrefix("0x"), let v = UInt8(s.dropFirst(2), radix: 16) { return v }
    if let v = UInt8(s) { return v }
    fail("unknown key '\(s)'")
}

func parseHexByte(_ s: String) -> UInt8? { ArgumentParsing.hexByte(s) }

/// Every token as a hex byte, or exit naming the first one that is not. Dropping a
/// token instead would send a different command from the one that was typed.
func parseHexBytes(_ tokens: [String]) -> [UInt8] {
    tokens.map { token in
        guard let byte = parseHexByte(token) else { fail("'\(token)' is not a hex byte (00 to FF)") }
        return byte
    }
}

/// A whole-number option value within `range`, or exit naming the option. Falling back
/// to a default on a typo would run a different command from the one that was typed.
func parseCount(_ text: String, option: String, in range: ClosedRange<Int>) -> Int {
    guard let n = ArgumentParsing.wholeNumber(text, in: range) else {
        fail("\(option) needs a whole number from \(range.lowerBound) to \(range.upperBound) (got '\(text)')")
    }
    return n
}

/// Exit if anything is left over once a command has taken its arguments. An extra token
/// that is silently ignored may be a mistyped option (`--layer` in the wrong place, a
/// modifier without its `+`), and the command would then run without it.
func requireNoExtraArguments(_ extra: ArraySlice<String>, hint: String) {
    if let first = extra.first { fail("unexpected argument '\(first)' (\(hint))") }
}

/// Exit unless `hid` can be bound on `layer`. Shared by `bind` and `unbind`, so that
/// neither pretends to write a key the keyboard does not take.
func requireRebindable(_ hid: UInt8, on layer: Mappings.Layer) {
    guard ApexProTKLGen3.mappableHIDCodeSet.contains(hid) else {
        fail(String(format: "key 0x%02X cannot be rebound (it is not a rebindable key on this keyboard; the media and screen buttons are fixed in firmware)", hid))
    }
    if layer == .secondActuation, !ApexProTKLGen3.analogHIDCodes.contains(hid) {
        fail("the second-actuation layer only covers the 68 adjustable (OmniPoint) keys")
    }
}

/// An onboard slot, 0-4, or exit. There is deliberately no fallback to slot 0:
/// `profile save` and `restore` write flash, and a typo must not pick a slot.
func parseSlot(_ s: String) -> UInt8 {
    guard let slot = ArgumentParsing.slot(s) else { fail("slot must be a number from 0 to 4 (got '\(s)')") }
    return slot
}

func resolveLayer(_ s: String) -> Mappings.Layer {
    switch s.lowercased() {
    case "normal", "0": return .normal
    case "meta", "fn", "1": return .meta
    case "second", "secondactuation", "dual", "2": return .secondActuation
    default: fail("unknown layer '\(s)' (normal|meta|second)")
    }
}

let modifierAliases: [String: UInt8] = [
    "ctrl": HIDUsage.leftControl, "control": HIDUsage.leftControl,
    "shift": HIDUsage.leftShift, "alt": HIDUsage.leftAlt, "opt": HIDUsage.leftAlt,
    "cmd": HIDUsage.leftGUI, "gui": HIDUsage.leftGUI, "win": HIDUsage.leftGUI,
    "rctrl": HIDUsage.rightControl, "rshift": HIDUsage.rightShift,
    "ralt": HIDUsage.rightAlt, "rcmd": HIDUsage.rightGUI,
]

/// Print one layer's bindings, skipping keys left at their factory behaviour.
func printBindings(_ map: [UInt8: Mappings.Binding], layer: Mappings.Layer) {
    let changed = layer.hidOrder.compactMap { hid -> (UInt8, Mappings.Binding)? in
        guard let b = map[hid], !b.isDefault, b != layer.blankBinding(forHID: hid) else { return nil }
        return (hid, b)
    }
    print("layer \(layer.displayName) — \(map.count) keys reported, \(changed.count) not at default")
    for (hid, b) in changed {
        let name = ApexProTKLGen3.name(forHID: hid)
        print(String(format: "  %-14@ 0x%02X  fn 0x%02X  kc %@  → %@",
                     name as NSString, hid, b.function,
                     b.keyCodes.map { String(format: "%02X", $0) }.joined(separator: " ") as NSString,
                     b.summary as NSString))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage(); exit(0) }

switch cmd {
case "info":
    let dev = connectOrExit()
    let fw = (try? dev.firmwareVersion()) ?? "unknown"
    let region = try? dev.region()
    let layout = try? dev.layout()
    print("Apex Pro TKL Gen 3 (0x1038:0x1642)")
    print("  connected:       \(dev.isConnected)")
    print("  firmware:        \(fw)")
    print("  region:          \(region.map { "\($0.name) (\($0.regionID))" } ?? "unknown")")
    print("  layout:          \((layout ?? nil)?.displayName ?? "unknown")")
    print("  LEDs:            \(ApexProTKLGen3.ledHIDOrder.count)")
    print("  adjustable keys: \(ApexProTKLGen3.analogHIDOrder.count)")
    print("  rebindable keys: \(ApexProTKLGen3.mappableHIDOrder.count)")

case "solid":
    guard args.count >= 2 else { fail("usage: apexctl solid <#RRGGBB>") }
    // Checked before connecting: a typo must not switch the lighting mode first.
    let color = parseColor(args[1])
    let dev = connectOrExit()
    try? dev.enableDirectMode()
    try? dev.setSolid(color)
    print("set solid \(args[1])")

case "key":
    // Pairs of <key> <colour>, checked before connecting: this writes a complete frame,
    // so an empty or lopsided list would black out the board or drop a key silently.
    guard args.count >= 3, (args.count - 1) % 2 == 0 else {
        fail("usage: apexctl key <key> <colour> [<key> <colour> ...]")
    }
    var map: [UInt8: LEDColor] = [:]
    for i in stride(from: 1, to: args.count, by: 2) {
        let hid = resolveHID(args[i])
        guard ApexProTKLGen3.ledHIDCodeSet.contains(hid) else {
            fail(String(format: "key 0x%02X has no LED on this keyboard, so it cannot be lit", hid))
        }
        map[hid] = parseColor(args[i + 1])
    }
    let dev = connectOrExit()
    try? dev.enableDirectMode()
    try? dev.setColors(map)
    print("set \(map.count) key(s)")

case "rainbow":
    let seconds = ArgumentParsing.clamped(
        ArgumentParsing.finiteNumber(args.count >= 2 ? args[1] : nil, or: 5), to: ArgumentParsing.durations)
    // 30 fps is the ceiling: faster frames outpace the LED controller and tear
    // (docs/PROTOCOL.md), and a zero or negative rate has no meaning.
    let requestedFps = ArgumentParsing.finiteNumber(args.count >= 3 ? args[2] : nil, or: 30)
    let fps = ArgumentParsing.clamped(requestedFps, to: ArgumentParsing.frameRates)
    if fps != requestedFps { print("note: frame rate limited to \(Int(fps)) fps (allowed range: 1 to 30)") }
    let dev = connectOrExit()
    try? dev.enableDirectMode()
    let frames = Int(seconds * fps)
    let keys = ApexProTKLGen3.keys.filter(\.hasLED)
    for step in 0..<frames {
        let phase = Double(step) / fps * 0.25
        var list: [(hid: UInt8, color: LEDColor)] = []
        for k in keys {
            let hue = (k.x / ApexProTKLGen3.layoutWidth + phase).truncatingRemainder(dividingBy: 1.0)
            list.append((hid: k.hid, color: .hsv(hue, 1, 1)))
        }
        try? dev.setColors(list)
        usleep(useconds_t(1_000_000 / fps))
    }
    print("rainbow done (last frame held)")

case "wave":
    let seconds = ArgumentParsing.clamped(
        ArgumentParsing.finiteNumber(args.count >= 2 ? args[1] : nil, or: 5), to: ArgumentParsing.durations)
    let dev = connectOrExit()
    try? dev.enableDirectMode()
    let fps = 30.0
    for step in 0..<Int(seconds * fps) {
        let t = Double(step) / fps
        var list: [(hid: UInt8, color: LEDColor)] = []
        for k in ApexProTKLGen3.keys.filter(\.hasLED) {
            let v = 0.5 + 0.5 * sin((k.x / 2.0) - t * 4)
            list.append((hid: k.hid, color: .hsv(0.55, 0.8, v)))
        }
        try? dev.setColors(list)
        usleep(useconds_t(1_000_000 / fps))
    }
    print("wave done")

case "clear":
    let dev = connectOrExit()
    try? dev.clearLighting()
    print("cleared (returned to onboard lighting)")

case "actuation":
    guard args.count >= 2, let level = Int(args[1]) else { fail("usage: apexctl actuation <1-40>") }
    // Checked before connecting, so that a typo cannot leave the actuation half set.
    var rapidTriggerSensitivity: UInt8?
    if let idx = args.firstIndex(of: "--rapid-trigger") {
        rapidTriggerSensitivity = 2
        if idx + 1 < args.count {
            rapidTriggerSensitivity = UInt8(parseCount(args[idx + 1], option: "--rapid-trigger", in: 1...20))
        }
    }
    let dev = connectOrExit()
    try? dev.setActuation(defaultLevel: level)
    print("actuation set to level \(level) (\(Actuation.millimetres(forLevel: level)) mm)")
    if let sens = rapidTriggerSensitivity {
        let modes = Dictionary(uniqueKeysWithValues: ApexProTKLGen3.analogHIDOrder.map { ($0, Actuation.ReleaseMode.rapidTrigger) })
        let senses = Dictionary(uniqueKeysWithValues: ApexProTKLGen3.analogHIDOrder.map { ($0, sens) })
        try? dev.setRapidTriggerSensitivity(perKey: senses)
        try? dev.setRapidTriggerMode(perKeyMode: modes)
        print("rapid trigger ON, sensitivity \(sens)")
    }

case "rapidtrigger":
    guard args.count >= 2, args[1] == "off" else {
        fail("usage: apexctl rapidtrigger off  (use 'actuation <n> --rapid-trigger' to enable)")
    }
    let dev = connectOrExit()
    let modes = Dictionary(uniqueKeysWithValues: ApexProTKLGen3.analogHIDOrder.map { ($0, Actuation.ReleaseMode.off) })
    try? dev.setRapidTriggerMode(perKeyMode: modes)
    print("rapid trigger OFF")

// MARK: - Bindings

case "bindings":
    let layers: [Mappings.Layer] = args.count >= 2 ? [resolveLayer(args[1])] : Mappings.Layer.allCases
    let dev = connectOrExit()
    for layer in layers {
        do {
            printBindings(try dev.readMappings(layer: layer), layer: layer)
        } catch {
            fail("read failed for layer \(layer.displayName): \(error)")
        }
    }

case "bind":
    var rest = Array(args.dropFirst())
    var layer = Mappings.Layer.normal
    if rest.first == "--layer" {
        guard rest.count >= 2 else { fail("--layer needs a value") }
        layer = resolveLayer(rest[1]); rest.removeFirst(2)
    }
    guard rest.count >= 2 else { fail("usage: apexctl bind <key> key|media|mouse|disable|raw ...") }

    let hid = resolveHID(rest[0])
    requireRebindable(hid, on: layer)

    let binding: Mappings.Binding
    switch rest[1].lowercased() {
    case "key":
        guard rest.count >= 3 else { fail("usage: apexctl bind <key> key <target> [+ctrl +shift ...]") }
        let target = resolveHID(rest[2])
        let mods = rest.dropFirst(3).map { token -> UInt8 in
            guard token.hasPrefix("+") else {
                fail("unexpected argument '\(token)' (modifiers are written +ctrl +shift +alt +cmd, and --layer goes right after bind)")
            }
            guard let m = modifierAliases[String(token.dropFirst()).lowercased()] else {
                fail("unknown modifier '\(token)'")
            }
            return m
        }
        binding = .keyboard(usage: target, modifiers: mods)
    case "media":
        guard rest.count >= 3,
              let action = Mappings.ConsumerAction.allCases.first(where: { $0.rawValue.lowercased() == rest[2].lowercased() })
        else {
            fail("usage: apexctl bind <key> media <\(Mappings.ConsumerAction.allCases.map(\.rawValue).joined(separator: "|"))>")
        }
        requireNoExtraArguments(rest.dropFirst(3), hint: "--layer goes right after bind")
        binding = .consumer(action)
    case "mouse":
        guard rest.count >= 3,
              let action = Mappings.MouseAction.allCases.first(where: { $0.rawValue.lowercased() == rest[2].lowercased() })
        else {
            fail("usage: apexctl bind <key> mouse <\(Mappings.MouseAction.allCases.map(\.rawValue).joined(separator: "|"))>")
        }
        requireNoExtraArguments(rest.dropFirst(3), hint: "--layer goes right after bind")
        binding = .mouse(action)
    case "disable":
        requireNoExtraArguments(rest.dropFirst(2), hint: "--layer goes right after bind")
        binding = .disabled
    case "raw":
        guard rest.count >= 3, let fn = parseHexByte(rest[2]) else { fail("usage: apexctl bind <key> raw <fn-hex> [kc-hex ...]") }
        let keyCodes = parseHexBytes(Array(rest.dropFirst(3)))
        guard keyCodes.count <= 4 else { fail("a binding carries at most 4 key codes (got \(keyCodes.count))") }
        binding = Mappings.Binding(function: fn, keyCodes: keyCodes)
    default:
        fail("unknown binding kind '\(rest[1])'")
    }

    let dev = connectOrExit()
    // Seed from the device so we never clobber bindings we were not asked to
    // change — the write is always a complete frame for the layer.
    var current: [UInt8: Mappings.Binding]
    do {
        current = try dev.readMappings(layer: layer)
    } catch {
        // The write is a complete frame, so writing without the layer's current
        // contents would put every key we were not asked to change back to the
        // layer's blank: on the normal layer that silently undoes the user's
        // other remaps, and on the Fn layer it erases the shortcuts the keyboard
        // shipped with, which we know of no command to restore. Read-back is intermittent on
        // firmware 1.19.7, so refuse and let the user try again.
        fail("could not read the \(layer.displayName) layer (\(error)). Writing it without reading it "
             + "first would reset every other key on it, so nothing was written. Try again.")
    }
    current[hid] = binding
    do {
        try dev.writeMappings(layer: layer, bindings: current)
        print("bound \(ApexProTKLGen3.name(forHID: hid)) → \(binding.summary) on layer \(layer.displayName)")
    } catch {
        fail("write failed: \(error)")
    }

case "unbind":
    var rest = Array(args.dropFirst())
    var layer = Mappings.Layer.normal
    if let idx = rest.firstIndex(of: "--layer"), idx + 1 < rest.count {
        layer = resolveLayer(rest[idx + 1]); rest.removeSubrange(idx...(idx + 1))
    }
    guard let first = rest.first else { fail("usage: apexctl unbind <key> [--layer meta|second]") }
    requireNoExtraArguments(rest.dropFirst(1), hint: "usage: apexctl unbind <key> [--layer meta|second]")
    let hid = resolveHID(first)
    requireRebindable(hid, on: layer)
    let dev = connectOrExit()
    var current: [UInt8: Mappings.Binding]
    do {
        current = try dev.readMappings(layer: layer)
    } catch {
        // See `bind`: a complete frame written from nothing resets every other key.
        fail("could not read the \(layer.displayName) layer (\(error)). Writing it without reading it "
             + "first would reset every other key on it, so nothing was written. Try again.")
    }
    current[hid] = layer.blankBinding(forHID: hid)
    do {
        try dev.writeMappings(layer: layer, bindings: current)
        print("reset \(ApexProTKLGen3.name(forHID: hid)) to default on layer \(layer.displayName)")
    } catch { fail("write failed: \(error)") }

case "reset-bindings":
    let dev = connectOrExit()
    do {
        try dev.resetAllBindings()
        print("every key on the normal and second-actuation layers is back to its factory behaviour; the Fn layer was left alone")
    } catch { fail("write failed: \(error)") }

case "fn":
    let usage = "usage: apexctl fn <key|none>"
    guard args.count >= 2 else { fail(usage) }
    requireNoExtraArguments(args.dropFirst(2), hint: usage)
    // Everything that can be decided without the keyboard is decided first: a typo,
    // or a key that is not one of the rebindable ones (the app offers the same keys),
    // must never reach it.
    let clear = args[1].lowercased() == "none"
    let hid: UInt8 = clear ? 0 : resolveHID(args[1])
    if !clear, !ApexProTKLGen3.mappableHIDCodeSet.contains(hid) {
        fail(String(format: "key 0x%02X cannot be the Fn key: only the rebindable keys can (the media and screen buttons cannot)", hid))
    }
    let dev = connectOrExit()
    do {
        try dev.setMetaToggleKey(hid: hid)
    } catch {
        fail("could not set the Fn trigger: \(error)")
    }
    print(clear ? "Fn (meta) trigger cleared" : "Fn (meta) trigger is now \(ApexProTKLGen3.name(forHID: hid))")

case "verify":
    // Write a known binding, read it back, restore. Proves the 0x36 write and
    // 0xB6 read agree — PRD-01 AC-4.
    let dev = connectOrExit()
    let probeHID: UInt8 = 0x68            // F13: not a key this board has, so nothing user-visible changes
    let probe = Mappings.Binding.keyboard(usage: 0x04, modifiers: [HIDUsage.leftControl])
    do {
        let before = try dev.readMappings(layer: .normal)
        print("read-back works: \(before.count) keys reported on the normal layer")

        guard ApexProTKLGen3.mappableHIDCodeSet.contains(probeHID) else {
            print("note: 0x68 is not mappable on this model; using Caps Lock instead")
            var m = before; m[0x39] = probe
            try dev.writeMappings(layer: .normal, bindings: m)
            let after = try dev.readMappings(layer: .normal)
            print("Caps Lock round-trip: wrote \(probe.summary), read \((after[0x39] ?? .unbound).summary)")
            let matches = after[0x39] == probe
            print(matches ? "✅ round-trip matches" : "⚠️  round-trip differs — see docs/PROTOCOL.md")
            try dev.writeMappings(layer: .normal, bindings: before)
            print("restored original bindings")
            if !matches { fail("the read-back did not match what was written") }
            break
        }
        var m = before; m[probeHID] = probe
        try dev.writeMappings(layer: .normal, bindings: m)
        let after = try dev.readMappings(layer: .normal)
        let matches = after[probeHID] == probe
        print(matches ? "✅ round-trip matches" : "⚠️  round-trip differs")
        try dev.writeMappings(layer: .normal, bindings: before)
        if !matches { fail("the read-back did not match what was written") }
    } catch {
        fail("verify failed: \(error)")
    }

case "profile":
    guard args.count >= 2 else {
        fail("usage: apexctl profile <0-4> | read [slot] [--out file] | save [slot] | restore <slot> <file>")
    }

    /// One line per layer of an image's non-factory bindings, plus the header
    /// facts that identify it.
    func printImageSummary(_ image: OnboardProfile.Image, slot: UInt8) {
        print("onboard profile slot \(slot): \"\(image.name)\", "
              + String(format: "CRC %08X (valid), ", image.storedCRC)
              + "Fn key \(image.metaToggleHID.map { ApexProTKLGen3.name(forHID: $0) } ?? "none")")
        for layer in Mappings.Layer.allCases {
            printBindings(image.bindings(layer: layer), layer: layer)
        }
    }

    switch args[1] {
    case "read":
        var rest = Array(args.dropFirst(2))
        var outPath: String?
        if let i = rest.firstIndex(of: "--out"), i + 1 < rest.count {
            outPath = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
        let slot = rest.first.map(parseSlot) ?? 0
        let dev = connectOrExit()
        do {
            let image = try dev.readOnboardProfile(slot: slot)
            printImageSummary(image, slot: slot)
            if let outPath {
                try Data(image.bytes).write(to: URL(fileURLWithPath: outPath))
                print("wrote \(image.bytes.count) bytes to \(outPath)")
            }
        } catch { fail("\(error)") }

    case "save":
        // Persist the keyboard's *current* bindings into its boot profile, so
        // they survive a power cycle. Read-modify-write: everything this tool
        // does not model (macros, lighting, actuation, name) is preserved.
        let slot = args.count >= 3 ? parseSlot(args[2]) : 0
        let dev = connectOrExit()
        do {
            var image = try dev.readOnboardProfile(slot: slot)
            var described: [String] = []
            for layer in Mappings.Layer.allCases {
                // RAM is the truth of what the user is running right now; the
                // read is intermittent, so readMappings retries internally.
                let ram = try dev.readMappings(layer: layer)
                image.setBindings(layer: layer, frame: ram)
                if layer == .meta { image.setMetaMask(metaBindings: ram) }
                let changed = ram.filter { !Mappings.isBlank($1, layer: layer, hid: $0) }.count
                described.append("\(layer.displayName): \(changed) custom")
            }
            print("persisting current bindings (\(described.joined(separator: ", "))) "
                  + "to onboard profile slot \(slot)…")
            try dev.writeOnboardProfile(image, slot: slot)
            print("saved and verified by read-back — these bindings should now survive unplugging")
        } catch { fail("\(error)") }

    case "restore":
        guard args.count >= 4 else {
            fail("usage: apexctl profile restore <slot> <file>")
        }
        let slot = parseSlot(args[2])
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: args[3])) }
        catch { fail("could not read \(args[3]): \(error)") }
        do {
            // Validates size, schema, and CRC before anything touches flash.
            let image = try OnboardProfile.Image(validating: Array(data))
            let dev = connectOrExit()
            try dev.writeOnboardProfile(image, slot: slot)
            print("restored \(data.count) bytes to onboard profile slot \(slot) (verified)")
        } catch { fail("\(error)") }

    default:
        guard let slot = ArgumentParsing.slot(args[1]) else {
            fail("usage: apexctl profile <0-4> | read [slot] [--out file] | save [slot] | restore <slot> <file>")
        }
        let dev = connectOrExit()
        do {
            try dev.loadProfile(slot: slot)
            print("switched to onboard profile slot \(slot)")
        } catch { fail("\(error)") }
    }

case "oled":
    guard args.count >= 2 else { fail("usage: apexctl oled text|image|clear|persist ...") }
    var rest = Array(args.dropFirst())
    let persist = rest.first == "persist"
    if persist { rest.removeFirst() }
    // Everything that can be checked without the keyboard is checked first, and the image is
    // loaded, so that a typo or a missing file never reaches it.
    let send: (ApexDevice) -> Void
    switch rest.first {
    case "text":
        let lines = Array(rest.dropFirst())
        let bmp = OLEDGraphics.text(lines.isEmpty ? ["Apex"] : lines, fontSize: lines.count > 1 ? 16 : 22)
        send = { dev in
            if persist { try? dev.persistOLED(bmp) } else { try? dev.showOLED(bmp) }
            print("oled \(persist ? "persisted" : "showing"): \(lines.joined(separator: " / "))")
        }
    case "image":
        guard rest.count >= 2 else { fail("usage: apexctl oled image <path>") }
        guard let bmp = OLEDGraphics.image(contentsOf: URL(fileURLWithPath: rest[1])) else { fail("could not load image") }
        send = { dev in
            if persist { try? dev.persistOLED(bmp) } else { try? dev.showOLED(bmp) }
            print("oled image shown")
        }
    case "clear":
        send = { dev in
            try? dev.resetOLED()
            print("oled reset to firmware default")
        }
    default: fail("usage: apexctl oled text|image|clear")
    }
    send(connectOrExit())

case "raw":
    guard args.count >= 2 else { fail("usage: apexctl raw feature|output|read|query ...") }

    /// Print a byte buffer as offset-annotated hex, trimming the trailing zeros
    /// that dominate a 644-byte feature report.
    func hexDump(_ bytes: [UInt8], label: String) {
        let lastNonZero = bytes.lastIndex(where: { $0 != 0 }).map { $0 + 1 } ?? 0
        let shown = max(lastNonZero, min(16, bytes.count))
        print("\(label): \(bytes.count) bytes, \(bytes.count - lastNonZero) trailing zeros")
        for start in stride(from: 0, to: shown, by: 16) {
            let slice = bytes[start..<min(start + 16, shown)]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "  %04d  %@", start, hex as NSString))
        }
    }

    switch args[1] {
    case "feature", "output":
        guard args.count >= 3 else { fail("usage: apexctl raw feature|output <hex...>") }
        let bytes = parseHexBytes(Array(args.dropFirst(2)))
        let limit = args[1] == "feature" ? 644 : 64
        guard bytes.count <= limit else { fail("\(args[1]) reports carry at most \(limit) bytes (got \(bytes.count))") }
        let dev = connectOrExit()
        do {
            if args[1] == "feature" { try dev.sendRawFeature(bytes) } else { try dev.sendRawOutput(bytes) }
        } catch { fail("send failed: \(error)") }
        print("sent \(bytes.count) bytes via \(args[1])")
    case "read":
        // GET_REPORT on the feature pipe with no preceding write.
        let length = args.count >= 3 ? parseCount(args[2], option: "read length", in: 1...644) : 644
        let dev = connectOrExit()
        do { hexDump(try dev.readRawFeature(length: length), label: "feature read") }
        catch { fail("read failed: \(error)") }
    case "query":
        // SET_REPORT then GET_REPORT: the request-and-reply pattern used for bulk read-back.
        // `--delay <ms>` inserts a pause before the read.
        var rest = Array(args.dropFirst(2))
        var delayMS = 0
        if let i = rest.firstIndex(of: "--delay"), i + 1 < rest.count {
            delayMS = parseCount(rest[i + 1], option: "--delay", in: 0...10_000)
            rest.removeSubrange(i...(i + 1))
        }
        var gets = 1
        if let i = rest.firstIndex(of: "--gets"), i + 1 < rest.count {
            gets = parseCount(rest[i + 1], option: "--gets", in: 1...100)
            rest.removeSubrange(i...(i + 1))
        }
        var poll = 0
        if let i = rest.firstIndex(of: "--poll"), i + 1 < rest.count {
            poll = parseCount(rest[i + 1], option: "--poll", in: 0...1000)
            rest.removeSubrange(i...(i + 1))
        }
        guard !rest.isEmpty else { fail("usage: apexctl raw query [--delay ms] [--gets n] [--poll n] <hex...>") }
        var request = [UInt8](repeating: 0, count: 644)
        let requestBytes = parseHexBytes(rest)
        guard requestBytes.count <= 644 else { fail("a feature report carries at most 644 bytes (got \(requestBytes.count))") }
        for (i, b) in requestBytes.enumerated() { request[i] = b }
        let dev = connectOrExit()
        do {
            if poll > 0 {
                // Write once, then poll the reply slot until the error byte
                // clears — the firmware fills the header before the payload.
                try dev.sendRawFeature(request)
                for attempt in 1...poll {
                    let reply = try dev.readRawFeature(length: 644)
                    if reply.count > 1, reply[1] == 0 {
                        hexDump(reply, label: "poll hit on attempt #\(attempt)")
                        break
                    }
                    if attempt == poll { hexDump(reply, label: "poll gave up after \(poll)") }
                    if delayMS > 0 { Thread.sleep(forTimeInterval: Double(delayMS) / 1000.0) }
                }
            } else {
                for attempt in 1...max(1, gets) {
                    try dev.sendRawFeature(request)
                    if delayMS > 0 { Thread.sleep(forTimeInterval: Double(delayMS) / 1000.0) }
                    hexDump(try dev.readRawFeature(length: 644), label: "attempt #\(attempt)")
                }
            }
        } catch { fail("query failed: \(error)") }
    default:
        fail("usage: apexctl raw feature|output|read|query ...")
    }

case "debugoled":
    // Render text and print the 128x40 bitmap as ASCII to diagnose orientation.
    let txt = args.count >= 2 ? args[1] : "Fj"
    let bmp = OLEDGraphics.text([txt], fontSize: 30)
    print("Rendered '\(txt)' — 128x40 (top row first):")
    for y in 0..<MonoBitmap.height {
        var row = ""
        for x in 0..<MonoBitmap.width { row += bmp.pixel(x, y) ? "#" : "." }
        print(row)
    }

case "--version", "-V", "version":
    print("apexctl \(ApexVersion.current)")

case "-h", "--help", "help":
    usage()

default:
    fail("unknown command '\(cmd)' (try: apexctl help)")
}
