import SwiftUI
import ApexKit

/// What a click on the keyboard does while painting per-key colours.
private enum PaintTool: String, CaseIterable, Identifiable {
    case paint, pick, erase
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paint: return "Paint"
        case .pick: return "Pick"
        case .erase: return "Erase"
        }
    }
    var icon: String {
        switch self {
        case .paint: return "paintbrush.fill"
        case .pick: return "eyedropper"
        case .erase: return "eraser.fill"
        }
    }
}

struct LightingView: View {
    @EnvironmentObject var controller: DeviceController

    @State private var editColor: Color = Color(LEDColor.steelOrange)
    @State private var tool: PaintTool = .paint
    @State private var recents: [LEDColor] = []

    private var lighting: Binding<LightingConfig> { $controller.lighting }
    private var isPerKey: Bool { controller.lighting.kind == .perKey }

    /// The wave and cycle effects derive every colour from the spectrum, so a
    /// colour well would be a control that does nothing. It is absent instead.
    private var effectUsesColour: Bool {
        switch controller.lighting.kind {
        case .staticColor, .perKey, .breathe, .reactive: return true
        case .rainbowWave, .spectrumCycle: return false
        }
    }

    var body: some View {
        // Only the per-key effect responds to clicks, so the handler is absent
        // rather than inert on the other effects — that also stops the keycaps
        // advertising themselves as buttons to VoiceOver.
        let paintHandler: ((Key) -> Void)? = isPerKey ? { handlePaint($0) } : nil

        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            if controller.isHandedBack { handedBackBanner }

            LiveKeyboardView(
                config: controller.lighting,
                selected: isPerKey ? controller.selectedKey : nil,
                layout: controller.layout ?? .ansi,
                oled: controller.oledBitmap,
                onKey: paintHandler,
                // So the picture of the keyboard lights up under your fingers
                // exactly like the keyboard does. Without it the one place a
                // user looks to check whether reactive works never reacts.
                hits: { controller.reactiveHits() }
            )
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: Theme.Space.l) {
                effectCard
                // The right column is always present so switching effects does
                // not shuffle the whole pane sideways.
                Group {
                    if effectUsesColour { colourCard } else { aboutCard }
                }
                .frame(width: 330)
            }
        }
        .onAppear { controller.refreshReactiveInput() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back to the front is when someone has just returned from
            // granting the permission, so this is where the retry belongs.
            controller.refreshReactiveInput()
        }
    }

    // MARK: - Handed back

    private var handedBackBanner: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "keyboard").foregroundStyle(Theme.readout).font(.system(size: 12))
            Text("The keyboard is lighting itself. Change anything below to take over again.")
                .font(Typo.callout).foregroundStyle(Theme.ink2)
            Spacer(minLength: Theme.Space.s)
            Button("Take over") { controller.takeOverLighting() }
                .buttonStyle(.compactSecondary)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 9)
        .background(Theme.readout.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Theme.readout.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Effect

    private var effectCard: some View {
        Card(title: "Effect") {
            // Six effects in a fixed 3 × 2 grid. An adaptive grid reflows to
            // 4 + 2 at some widths, which reads as an accident.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3),
                      spacing: Theme.Space.s) {
                ForEach(EffectKind.allCases) { kind in
                    effectTile(kind)
                }
            }

            Rule()
            parameters
        }
    }

    private func effectTile(_ kind: EffectKind) -> some View {
        let isOn = controller.lighting.kind == kind
        return Button {
            controller.selectEffect(kind)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: kind)).font(.system(size: 11, weight: .medium))
                    Text(kind.rawValue).font(Typo.captionMedium)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isOn ? Theme.ink : Theme.ink2)

                EffectSwatch(kind: kind, config: controller.lighting)
                    .frame(height: 5)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.signal.opacity(0.13) : Theme.surfaceHi.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(isOn ? Theme.signal.opacity(0.65) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.snap, value: isOn)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var parameters: some View {
        let kind = controller.lighting.kind

        // On reactive, Speed drives the ripple and nothing else — so with no
        // ripple it would be a control that does nothing, and it is absent
        // rather than inert.
        let speedDoesSomething = kind.isAnimated
            && (kind != .reactive || controller.lighting.reactiveRipple > 0)

        HStack(alignment: .top, spacing: Theme.Space.xl) {
            ScaleControl(
                label: "Brightness",
                value: lighting.brightness,
                range: 0...1, step: 0.01, majorEvery: 25,
                readout: { (String(Int($0 * 100)), "%") },
                tickLabel: { "\(Int($0 * 100))" }
            )

            if speedDoesSomething {
                ScaleControl(
                    label: kind == .reactive ? "Ripple speed" : "Speed",
                    value: lighting.speed,
                    range: 0...1, step: 0.01, majorEvery: 25,
                    readout: { (String(format: "%.2f", $0), "×") },
                    tickLabel: { $0 == 0 ? "slow" : ($0 >= 1 ? "fast" : "") }
                )
            }
        }

        if kind == .rainbowWave {
            HStack {
                Text("Direction").font(Typo.caption).foregroundStyle(Theme.ink2)
                Spacer()
                SegmentedRail(
                    selection: lighting.horizontal,
                    items: [.init(true, "Across", icon: "arrow.left.and.right"),
                            .init(false, "Down", icon: "arrow.up.and.down")],
                    fillsWidth: false
                )
            }
        }

        if kind == .reactive {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ScaleControl(
                    label: "Fade",
                    value: lighting.reactiveFade,
                    range: 0.1...2.0, step: 0.05, majorEvery: 10,
                    readout: { (String(format: "%.2f", $0), "s") },
                    tickLabel: { String(format: "%.1f", $0) }
                )
                ScaleControl(
                    label: "Ripple",
                    value: lighting.reactiveRipple,
                    range: 0...1, step: 0.01, majorEvery: 25,
                    readout: { (String(Int($0 * 100)), "%") },
                    tickLabel: { $0 == 0 ? "off" : ($0 >= 1 ? "board" : "") }
                )
            }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ScaleControl(
                    label: "Resting glow",
                    value: lighting.reactiveRestLevel,
                    range: 0...0.5, step: 0.01, majorEvery: 10,
                    readout: { (String(Int($0 * 100)), "%") },
                    tickLabel: { $0 == 0 ? "off" : "\(Int($0 * 100))" }
                )
            }
            reactivePermission
        }

    }

    // MARK: - About

    /// Stands in for the colour card on the effects that have no colour to set.
    private var aboutCard: some View {
        Card(title: "About") {
            Text(controller.lighting.kind.rawValue)
                .font(Typo.heading).foregroundStyle(Theme.ink)

            EffectSwatch(kind: controller.lighting.kind, config: controller.lighting)
                .frame(height: 8)
                .clipShape(Capsule())

            Text(Self.describe(controller.lighting.kind))
                .font(Typo.callout).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Rule()

            Note("Every colour comes from the spectrum, so there is nothing to pick. "
                 + "Use Static or Breathe to choose your own.", icon: "paintpalette")
        }
    }

    private static func describe(_ kind: EffectKind) -> String {
        switch kind {
        case .staticColor: return "One colour, held steady."
        case .perKey: return "Paint each key its own colour."
        case .rainbowWave: return "The spectrum laid across the board, drifting sideways or down."
        case .spectrumCycle: return "The whole board one colour at a time, working through the spectrum."
        case .breathe: return "One colour rising and falling."
        case .reactive: return "Keys light as you press them, send a ripple out across the board, "
            + "and fade back to the resting colour."
        }
    }

    /// Reports the listener, not the checkbox.
    ///
    /// macOS having recorded a permission and macOS honouring it for *this*
    /// process are different facts, and the gap between them is the whole of
    /// "I granted it and reactive still does nothing".
    @ViewBuilder
    private var reactivePermission: some View {
        let status = controller.reactiveInput
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch status.listener {
            case .listening:
                if status.secureInput {
                    Note("A password field is open, so macOS is hiding key presses from every app on the "
                         + "Mac. Reactive picks up again as soon as you leave it.",
                         icon: "lock.shield", color: Theme.warn)
                } else {
                    // Names the key it last saw. A silent green tick cannot tell
                    // "listening and receiving" from "listening to nothing",
                    // which is the difference that matters when the board looks
                    // dead. Polled slowly rather than published, so typing does
                    // not invalidate the pane on every keystroke.
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        if let key = controller.lastReactiveKeyName() {
                            Note("Watching key presses — last seen: \(key)",
                                 icon: "checkmark.circle.fill", color: Theme.ok)
                        } else {
                            Note("Watching key presses. Nothing you type is written to disk, logged or sent anywhere.",
                                 icon: "checkmark.circle.fill", color: Theme.ok)
                        }
                    }
                }

            case .needsRelaunch:
                Note("Permission is granted, but macOS only hands it to apps that start after it is "
                     + "given. Quit and reopen Apex Control to finish.",
                     icon: "arrow.clockwise.circle.fill", color: Theme.warn)
                Button("Quit and reopen") { AppRelaunch.now() }
                    .buttonStyle(.secondary)

            case .degraded:
                // The tap exists but macOS is starving it. Said plainly,
                // because from the keyboard this looks like a lighting bug:
                // modifiers ripple, letters do nothing.
                Note("macOS is letting Apex Control hear only the modifier keys — ⇧ ⌃ ⌥ ⌘ ripple, but "
                     + "letters and everything else stay quiet unless Apex Control is the app you are "
                     + "typing into.", icon: "ear.trianglebadge.exclamationmark", color: Theme.warn)
                if status.hasAnyGrant {
                    Note("A permission is on record, but macOS is not honouring it for this copy of the "
                         + "app. Quit and reopen first. If that is not enough, remove Apex Control from "
                         + "the System Settings list with “−” and add this copy again — a rebuilt app "
                         + "counts as a different one.", icon: "exclamationmark.triangle")
                    HStack(spacing: 6) {
                        Button("Quit and reopen") { AppRelaunch.now() }
                            .buttonStyle(.secondary)
                        Button("Input Monitoring…") { KeyMonitor.openInputMonitoringSettings() }
                            .buttonStyle(.compactSecondary)
                        Spacer(minLength: 0)
                    }
                } else {
                    Button("Grant permission…") { controller.requestReactiveInputPermission() }
                        .buttonStyle(.secondary)
                    HStack(spacing: 6) {
                        Button("Input Monitoring…") { KeyMonitor.openInputMonitoringSettings() }
                            .buttonStyle(.compactSecondary)
                        Button("Accessibility…") { KeyMonitor.openAccessibilitySettings() }
                            .buttonStyle(.compactSecondary)
                        Spacer(minLength: 0)
                    }
                }

            case .needsPermission, .off:
                Note("Reactive needs permission to see which keys you press. Nothing else in the app does.",
                     icon: "lock.fill", color: Theme.warn)
                Button("Grant permission…") { controller.requestReactiveInputPermission() }
                    .buttonStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Input Monitoring…") { KeyMonitor.openInputMonitoringSettings() }
                        .buttonStyle(.compactSecondary)
                    Button("Accessibility…") { KeyMonitor.openAccessibilitySettings() }
                        .buttonStyle(.compactSecondary)
                    Spacer(minLength: 0)
                }
                if status.hasAnyGrant {
                    // The usual cause of a grant that does not work: a rebuilt
                    // app is, to macOS, a different app wearing the same name.
                    Note("Apex Control is already ticked in that list? Remove it with “−” and add it "
                         + "again — a rebuilt copy counts as a different app.", icon: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Colour

    private var colourCard: some View {
        Card(title: isPerKey ? "Paint" : "Colour") {
            if isPerKey {
                SegmentedRail(selection: $tool,
                              items: PaintTool.allCases.map { .init($0, $0.label, icon: $0.icon) })
            }

            colourWell

            swatches

            if isPerKey {
                perKeyActions
            } else if controller.lighting.kind == .reactive {
                Rule()
                backgroundColourRow
            }
        }
        .onChange(of: editColor) { _, new in
            guard !isPerKey else { return }
            controller.lighting.baseColor = LEDColor(new)
        }
        // The colour can change without this well being touched — turning the
        // lights off, applying a profile, undoing. A well showing orange while
        // the effect renders black is a lie that reads as a broken effect.
        .onChange(of: controller.lighting.baseColor) { _, new in
            guard !isPerKey, LEDColor(editColor) != new else { return }
            editColor = Color(new)
        }
        .onAppear {
            if !isPerKey { editColor = Color(controller.lighting.baseColor) }
        }
    }

    private var colourWell: some View {
        HStack(spacing: Theme.Space.m) {
            ColorPicker("Colour", selection: $editColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 54, height: 30)
                .accessibilityLabel("Choose colour")

            VStack(alignment: .leading, spacing: 1) {
                Readout(LEDColor(editColor).hexString, size: 13, color: Theme.ink)
                Text(LEDColor(editColor).describedName.capitalized)
                    .font(Typo.caption).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 0)
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            swatchRow(title: "Presets", colors: Self.presets)
            if !recents.isEmpty {
                swatchRow(title: "Recent", colors: recents)
            }
        }
    }

    private func swatchRow(title: String, colors: [LEDColor]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(title)
            HStack(spacing: 6) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                    Button {
                        editColor = Color(c)
                    } label: {
                        Circle()
                            .fill(Color(c))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(c.hexString)
                    .accessibilityLabel("\(c.describedName), \(c.hexString)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var perKeyActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Rule()
            Note(toolHint, icon: tool.icon)
            HStack(spacing: 6) {
                Button("Fill all") { fillAll() }.buttonStyle(.compactSecondary)
                Button("Clear") { clearAll() }.buttonStyle(.compactSecondary)
                Spacer(minLength: 0)
            }
            Button("Start from the last effect") { seedFromRenderedFrame() }
                .buttonStyle(.compactSecondary)
                .help("Copy the colours currently on the keyboard into the per-key layer, then edit them")
        }
    }

    private var toolHint: String {
        switch tool {
        case .paint: return "Click or drag across the keyboard to paint."
        case .pick: return "Click a key to load its colour into the well."
        case .erase: return "Click or drag to turn keys off."
        }
    }

    private var backgroundColourRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Resting colour").font(Typo.callout).foregroundStyle(Theme.ink)
                Text("What unpressed keys show").font(Typo.caption).foregroundStyle(Theme.ink3)
            }
            Spacer()
            Button("Use this colour") { controller.lighting.secondaryColor = LEDColor(editColor) }
                .buttonStyle(.compactSecondary)
            Circle().fill(Color(controller.lighting.secondaryColor))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
    }

    // MARK: - Actions

    private func handlePaint(_ key: Key) {
        guard key.hasLED else { return }
        controller.selectedKey = key.hid
        switch tool {
        case .paint:
            let c = LEDColor(editColor)
            controller.setColor(c, forKey: key.hid)
            remember(c)
        case .erase:
            controller.setColor(.black, forKey: key.hid)
        case .pick:
            let existing = controller.lighting.perKeyColors[key.hid] ?? .black
            editColor = Color(existing)
        }
    }

    private func fillAll() {
        let c = LEDColor(editColor)
        for hid in ApexProTKLGen3.ledHIDOrder {
            controller.lighting.perKeyColors[hid] = c
        }
        remember(c)
        controller.applyLightingNow()
    }

    private func clearAll() {
        controller.lighting.perKeyColors = [:]
        controller.applyLightingNow()
    }

    /// Copy whatever the board is showing right now into the per-key layer, so
    /// painting can start from a rainbow instead of from black.
    private func seedFromRenderedFrame() {
        var config = controller.lighting
        if config.kind == .perKey { config.kind = .rainbowWave }
        let frame = LightingRender.render(config: config, time: 0)
        var colors = HIDMap<LEDColor>()
        for hid in ApexProTKLGen3.ledHIDOrder {
            colors[hid] = frame[hid] ?? .black
        }
        controller.lighting.perKeyColors = colors
        controller.lighting.kind = .perKey
    }

    private func remember(_ c: LEDColor) {
        guard c != .black else { return }
        recents.removeAll { $0 == c }
        recents.insert(c, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
    }

    // MARK: - Data

    private static let presets: [LEDColor] = [
        .steelOrange,
        LEDColor(r: 255, g: 0, b: 64),
        LEDColor(r: 255, g: 0, b: 200),
        LEDColor(r: 140, g: 0, b: 255),
        LEDColor(r: 0, g: 110, b: 255),
        LEDColor(r: 0, g: 220, b: 220),
        LEDColor(r: 0, g: 255, b: 90),
        LEDColor(r: 255, g: 220, b: 120),
        .white,
    ]

    private func icon(for kind: EffectKind) -> String {
        switch kind {
        case .staticColor: return "circle.fill"
        case .perKey: return "paintbrush.pointed.fill"
        case .rainbowWave: return "water.waves"
        case .spectrumCycle: return "arrow.triangle.2.circlepath"
        case .breathe: return "wind"
        case .reactive: return "hand.tap.fill"
        }
    }
}

// MARK: - Effect swatch

/// A one-line preview of what an effect looks like, so the grid shows the
/// effects rather than only naming them.
private struct EffectSwatch: View {
    let kind: EffectKind
    let config: LightingConfig

    var body: some View {
        switch kind {
        case .staticColor:
            Rectangle().fill(Color(config.baseColor))
        case .perKey:
            LinearGradient(colors: [Color(srgb: 0xFF4A00), Color(srgb: 0x00D2FF),
                                    Color(srgb: 0x9B5CFF), Color(srgb: 0x36FF9E)],
                           startPoint: .leading, endPoint: .trailing)
        case .rainbowWave:
            // Spatial: the spectrum spread across the board at one instant.
            LinearGradient(colors: rainbow, startPoint: .leading, endPoint: .trailing)
        case .spectrumCycle:
            // Temporal: the whole board one colour at a time. Drawn as discrete
            // steps so it cannot be mistaken for the wave above it.
            HStack(spacing: 1.5) {
                ForEach(0..<6) { i in
                    Rectangle().fill(LEDColor.hsv(Double(i) / 6, 1, 1).color)
                }
            }
        case .breathe:
            LinearGradient(colors: [Color(config.baseColor).opacity(0.15),
                                    Color(config.baseColor),
                                    Color(config.baseColor).opacity(0.15)],
                           startPoint: .leading, endPoint: .trailing)
        case .reactive:
            LinearGradient(stops: [
                .init(color: Color(config.secondaryColor).opacity(0.35), location: 0),
                .init(color: Color(config.secondaryColor).opacity(0.35), location: 0.34),
                .init(color: Color(config.baseColor), location: 0.5),
                .init(color: Color(config.secondaryColor).opacity(0.35), location: 0.66),
                .init(color: Color(config.secondaryColor).opacity(0.35), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var rainbow: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 8).map { LEDColor.hsv($0, 1, 1).color }
    }
}

// MARK: - Helpers

extension LEDColor {
    var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }
}
