import SwiftUI
import AppKit
import ApexKit

// MARK: - Direct manipulation

/// Dragging one key onto another.
///
/// The board is the most direct statement of what the keyboard does, so the
/// most direct way to say "make this key send that one" is to pick the key up
/// and drop it. Everything the board needs to run that interaction is here;
/// what a drop *means* belongs to the pane that supplies it.
struct KeyDragBehaviour {
    /// Whether a key can be picked up as the thing being copied.
    var canDrag: (Key) -> Bool = { _ in true }
    /// Whether `source` may be dropped on `target`.
    var canDrop: (Key, Key) -> Bool = { _, _ in true }
    /// One short line naming the result, shown against the target while
    /// hovering. `heldModifiers` are the modifier usages down at that instant,
    /// so a drop can mean "⌘ and that key" and say so before it happens.
    var describeDrop: (Key, Key, [UInt8]) -> String
    var onDrop: (Key, Key, [UInt8]) -> Void
}

/// The board asking a question: "which key?".
///
/// This is drag-and-drop's accessible twin. Everything reachable by dragging is
/// reachable by arming a pick and then clicking — or, for VoiceOver, by
/// activating the key's accessibility element.
struct KeyPickRequest {
    var prompt: String
    var isEligible: (Key) -> Bool = { _ in true }
    var onPick: (Key) -> Void
    var onCancel: () -> Void
}

// MARK: - Render style

/// Whether the colours on the render mean *light* or *data*.
///
/// On the Lighting pane the keycap colour is literally what the LEDs are about
/// to emit, so the render blooms: light spills onto the top plate the way it
/// does on the real board. Everywhere else the colour encodes a value — an
/// actuation depth, a binding state — and blooming it would dress data up as
/// something the hardware is doing. Those panes render flat.
enum KeyRenderStyle {
    case light
    case data
}

// MARK: - Keyboard

/// The Apex Pro TKL Gen 3 as a physical object: milled top plate, keycaps with
/// real bevels, the OLED live in place, and the volume roller.
///
/// This is the one element in the app allowed to have depth. Everything around
/// it stays matte so the board reads as the thing you are actually editing.
struct KeyboardView: View {
    /// The colour each key shows.
    var colorFor: (Key) -> LEDColor
    /// Keys that are relevant to the current task. Others are dimmed back.
    var isEnabled: (Key) -> Bool = { _ in true }
    /// Optional short text under the legend.
    var badgeFor: (Key) -> String? = { _ in nil }
    /// Extra ring colour, e.g. to mark the Fn key.
    var markFor: (Key) -> Color? = { _ in nil }
    var selected: UInt8?
    var layout: KeyboardLayout = .ansi
    var style: KeyRenderStyle = .light
    /// Live OLED contents. `nil` draws the screen dark.
    var oled: MonoBitmap?
    /// Called on click and, while dragging, each time the pointer enters a new
    /// key — so painting and multi-key selection come for free.
    var onKey: ((Key) -> Void)?
    /// Description used for the keycap's accessibility label.
    var describe: (Key) -> String = { $0.label }
    /// Enables drag-one-key-onto-another. When set, dragging no longer paints.
    var dragBehaviour: KeyDragBehaviour?
    /// When set, the next click answers a question instead of selecting.
    var pickRequest: KeyPickRequest?

    @State private var hovered: UInt8?
    @State private var dragKey: UInt8?
    @State private var pressedKey: UInt8?
    @State private var dragSource: Key?
    @State private var dragTarget: Key?
    @State private var dragPoint: CGPoint?
    @State private var dragModifiers: [UInt8] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting

    /// Widest the board is allowed to get. Past this the keycaps stop reading as
    /// keycaps and start reading as tiles.
    private let maxBoardWidth: CGFloat = 940

    // Geometry, in key units.
    private let bezel: Double = 0.42
    private var boardW: Double { ApexProTKLGen3.layoutWidth + bezel * 2 }
    private var boardH: Double { ApexProTKLGen3.layoutHeight + bezel * 2 }

    /// Where the OLED and roller sit — the strip right of the media button on
    /// the top row of the real board.
    private let oledRect = (x: 16.55, y: 0.06, w: 1.45, h: 0.88)
    private let wheelRect = (x: 18.12, y: 0.02, w: 0.38, h: 0.96)

    var body: some View {
        Group {
            if isSnapshotting {
                // `ImageRenderer` draws no `Text` at all inside a
                // `GeometryReader` subtree, so a capture takes the board at its
                // maximum size instead of measuring the container. Only the
                // harness sees this path.
                board(unit: maxBoardWidth / boardW)
            } else {
                GeometryReader { geo in
                    board(unit: geo.size.width / boardW)
                }
                .aspectRatio(boardW / boardH, contentMode: .fit)
                .frame(maxWidth: maxBoardWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard")
    }

    // MARK: Board

    /// The board is drawn in three layers, split by how often each one changes.
    ///
    /// An animated effect hands this view ninety new colours thirty times a
    /// second. Building ninety keycap view subtrees at that rate costs about
    /// two thirds of a CPU core — measured — because SwiftUI has to diff the
    /// whole tree every frame. So everything that changes with the colours is
    /// drawn imperatively in one `Canvas` pass, and everything that does not
    /// (the plate, the screen, the roller, the accessibility elements) stays a
    /// view and is left alone between frames.
    private func board(unit: CGFloat) -> some View {
        let keys = ApexProTKLGen3.keys(for: layout)
        return ZStack(alignment: .topLeading) {
            chassis(unit: unit)

            Canvas(rendersAsynchronously: false) { ctx, _ in
                if style == .light { drawBloom(ctx, keys: keys, unit: unit) }
                for key in keys { drawKeycap(ctx, key: key, unit: unit) }
                drawDrag(ctx, unit: unit)
            }
            .allowsHitTesting(false)

            oledPanel(unit: unit)
            volumeRoller(unit: unit)

            KeyAccessibilityLayer(
                keys: keys, unit: unit, bezel: bezel, selected: selected,
                mode: pickRequest == nil ? .select : .pick,
                describe: accessibilityDescription, isEnabled: isAvailable, onKey: activate
            )
            .equatable()
        }
        .frame(width: unit * boardW, height: unit * boardH)
        .contentShape(Rectangle())
        .gesture(boardGesture(unit: unit))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = key(at: point, unit: unit)?.hid
            case .ended: hovered = nil
            }
        }
    }

    /// A key is available when the current mode says it can be acted on.
    private func isAvailable(_ key: Key) -> Bool {
        if let pickRequest { return pickRequest.isEligible(key) }
        return isEnabled(key)
    }

    private func activate(_ key: Key) {
        if let pickRequest {
            guard pickRequest.isEligible(key) else { return }
            pickRequest.onPick(key)
            return
        }
        guard isEnabled(key) else { return }
        onKey?(key)
    }

    private func accessibilityDescription(_ key: Key) -> String {
        guard let pickRequest else { return describe(key) }
        return pickRequest.isEligible(key)
            ? "\(key.label), choose this key"
            : "\(key.label), not available"
    }


    /// Milled aluminium top plate. A single soft directional gradient plus two
    /// hairlines — enough to read as metal without becoming a texture study.
    private func chassis(unit: CGFloat) -> some View {
        let radius = unit * 0.5
        return ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(srgb: 0x2A2E35), location: 0),
                            .init(color: Color(srgb: 0x1E2127), location: 0.34),
                            .init(color: Color(srgb: 0x16181D), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .black.opacity(0.4)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: unit * 0.5, y: unit * 0.16)
    }

    /// Light spilling from under the caps onto the plate — what per-key RGB
    /// actually looks like on an aluminium top plate.
    private func drawBloom(_ ctx: GraphicsContext, keys: [Key], unit: CGFloat) {
        var g = ctx
        g.blendMode = .plusLighter
        for key in keys where key.hasLED {
            let led = colorFor(key)
            let lum = led.luminance
            guard lum > 0.02 else { continue }

            let cx = unit * (bezel + key.x + key.w / 2)
            let cy = unit * (bezel + key.y + key.h / 2)
            let radius = unit * (0.72 + 0.34 * lum)
            let alpha = 0.10 + 0.34 * lum
            let color = Color(led)

            let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            g.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(alpha), location: 0),
                        .init(color: color.opacity(alpha * 0.42), location: 0.45),
                        .init(color: color.opacity(0), location: 1),
                    ]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: radius)
            )
        }
    }

    // MARK: Keycap

    private func drawKeycap(_ ctx: GraphicsContext, key: Key, unit: CGFloat) {
        let led = colorFor(key)
        let face = CapFace(led)
        // While a drag or a pick is in flight the board answers one question, so
        // everything that cannot answer it steps back.
        let dimmed = !isAvailable(key)
            || (dragSource != nil && dragTarget?.hid != key.hid && dragSource?.hid != key.hid)

        let rect = capRect(key, unit: unit)
        let path = Path(roundedRect: rect, cornerRadius: unit * 0.17)
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)

        var g = ctx
        if dimmed { g.opacity = 0.38 }

        // Cap body: lit from beneath, so the top is brighter than the skirt.
        g.fill(path, with: .linearGradient(
            Gradient(colors: [face.lightened(0.13), face.color, face.darkened(0.24)]),
            startPoint: top, endPoint: bottom))

        // Moulded top surface.
        g.stroke(path, with: .color(.white.opacity(0.13)),
                 lineWidth: max(0.7, unit * 0.028))

        if hovered == key.hid, onKey != nil, !dimmed {
            g.fill(path, with: .color(.white.opacity(0.10)))
        }

        drawLegend(g, key: key, face: face, rect: rect, unit: unit)

        if let mark = markFor(key) {
            g.stroke(path, with: .color(mark), lineWidth: max(1, unit * 0.05))
        }

        if selected == key.hid, pickRequest == nil {
            var ring = g
            ring.addFilter(.shadow(color: Theme.signal.opacity(0.6), radius: unit * 0.16))
            ring.stroke(path, with: .color(Theme.signal), lineWidth: max(1.4, unit * 0.062))
        }

        // The key being copied stays outlined at its home position, so the drag
        // reads as "a copy of this", not "this key has gone somewhere".
        if dragSource?.hid == key.hid {
            ctx.stroke(path, with: .color(Theme.ink2.opacity(0.8)),
                       style: StrokeStyle(lineWidth: max(1, unit * 0.04),
                                          dash: [unit * 0.12, unit * 0.1]))
        }

        // Where the drop will land, and — in pick mode — every key that would
        // be a valid answer.
        if dragTarget?.hid == key.hid || (pickRequest != nil && isAvailable(key)) {
            var ring = ctx
            let strong = dragTarget?.hid == key.hid || hovered == key.hid
            ring.addFilter(.shadow(color: Theme.readout.opacity(strong ? 0.75 : 0.25),
                                   radius: unit * (strong ? 0.2 : 0.08)))
            ring.stroke(path, with: .color(Theme.readout.opacity(strong ? 1 : 0.5)),
                        lineWidth: max(1.4, unit * (strong ? 0.07 : 0.04)))
        }
    }

    private func capRect(_ key: Key, unit: CGFloat) -> CGRect {
        let gap = unit * 0.045
        return CGRect(x: unit * (bezel + key.x) + gap,
                      y: unit * (bezel + key.y) + gap,
                      width: unit * key.w - gap * 2,
                      height: unit * key.h - gap * 2)
    }

    // MARK: Drag

    /// The keycap under the pointer plus a caption for what dropping it does.
    ///
    /// Drawn in the same `Canvas` as the board rather than as an overlay view so
    /// it cannot lag a frame behind the pointer, which is exactly the kind of
    /// slack that makes a drag feel like a simulation of a drag.
    private func drawDrag(_ ctx: GraphicsContext, unit: CGFloat) {
        guard let source = dragSource, let point = dragPoint, let behaviour = dragBehaviour else { return }

        let w = unit * max(1, min(source.w, 1.75))
        let h = unit
        let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        let path = Path(roundedRect: rect, cornerRadius: unit * 0.17)

        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(0.6), radius: unit * 0.3, y: unit * 0.14))
        g.opacity = 0.96

        let face = CapFace(colorFor(source))
        g.fill(path, with: .linearGradient(
            Gradient(colors: [face.lightened(0.2), face.color, face.darkened(0.2)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        g.stroke(path, with: .color(Theme.readout.opacity(0.9)), lineWidth: max(1, unit * 0.05))

        let label = ctx.resolve(
            Text(source.label)
                .font(.system(size: legendSize(for: source.label, width: 1, unit: unit), weight: .semibold))
                .foregroundStyle(face.legendInk))
        g.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)

        guard let target = dragTarget else { return }
        let caption = behaviour.describeDrop(source, target, dragModifiers)
        let resolved = ctx.resolve(
            Text(caption)
                .font(.system(size: max(9, unit * 0.2), weight: .medium))
                .foregroundStyle(Theme.ink))
        let measured = resolved.measure(in: CGSize(width: unit * 12, height: unit))
        let centre = CGPoint(x: rect.midX, y: rect.maxY + measured.height * 0.9)
        let pill = CGRect(x: centre.x - measured.width / 2 - unit * 0.16,
                          y: centre.y - measured.height / 2 - unit * 0.07,
                          width: measured.width + unit * 0.32,
                          height: measured.height + unit * 0.14)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                 with: .color(Theme.chassis.opacity(0.97)))
        ctx.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                   with: .color(Theme.readout.opacity(0.5)), lineWidth: 1)
        ctx.draw(resolved, at: centre, anchor: .center)
    }

    private func drawLegend(_ ctx: GraphicsContext, key: Key, face: CapFace,
                            rect: CGRect, unit: CGFloat) {
        let badge = badgeFor(key)
        let size = legendSize(for: key.label, width: key.w, unit: unit)
        let label = ctx.resolve(
            Text(key.label)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(face.legendInk))

        // With a badge the legend rides above centre to make room for it.
        let labelY = badge == nil ? rect.midY : rect.midY - rect.height * 0.15
        ctx.draw(label, at: CGPoint(x: rect.midX, y: labelY), anchor: .center)

        guard let badge else { return }

        let badgeSize = legendSize(for: badge, width: key.w, unit: unit) * 0.8
        let resolved = ctx.resolve(
            Text(badge)
                .font(.system(size: badgeSize, weight: .semibold))
                .foregroundStyle(Theme.signal))
        let measured = resolved.measure(in: rect.size)
        let centre = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.24)
        let pill = CGRect(x: centre.x - measured.width / 2 - unit * 0.06,
                          y: centre.y - measured.height / 2 - unit * 0.01,
                          width: measured.width + unit * 0.12,
                          height: measured.height + unit * 0.02)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                 with: .color(.black.opacity(0.6)))
        ctx.draw(resolved, at: centre, anchor: .center)
    }

    /// Size the legend from the keycap it has to fit inside.
    ///
    /// Deliberately not `minimumScaleFactor`: letting SwiftUI shrink text makes
    /// the legends on a row of keys land at slightly different sizes, which on a
    /// keyboard reads as a printing defect.
    private func legendSize(for text: String, width: Double, unit: CGFloat) -> CGFloat {
        let characters = max(1, text.count)
        let available = unit * width * 0.82
        // Roughly the advance width of SF Pro Medium at size 1.
        let byWidth = available / (CGFloat(characters) * 0.62)
        return max(unit * 0.13, min(unit * 0.26, byWidth))
    }

    // MARK: OLED and roller

    private func oledPanel(unit: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: unit * 0.09)
                .fill(Color.black)
            if let oled {
                OLEDPixels(bitmap: oled, color: Theme.readout).equatable()
                    .padding(unit * 0.05)
            }
            RoundedRectangle(cornerRadius: unit * 0.09)
                .fill(
                    LinearGradient(colors: [.white.opacity(0.10), .clear],
                                   startPoint: .top, endPoint: .center)
                )
            RoundedRectangle(cornerRadius: unit * 0.09)
                .strokeBorder(.black.opacity(0.85), lineWidth: max(1, unit * 0.05))
        }
        .frame(width: unit * oledRect.w, height: unit * oledRect.h)
        .position(x: unit * (bezel + oledRect.x + oledRect.w / 2),
                  y: unit * (bezel + oledRect.y + oledRect.h / 2))
        .shadow(color: Theme.readout.opacity(oled == nil ? 0 : 0.28), radius: unit * 0.25)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func volumeRoller(unit: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: unit * 0.1)
                .fill(
                    LinearGradient(colors: [Color(srgb: 0x0D0E11), Color(srgb: 0x33373E),
                                            Color(srgb: 0x1A1C21), Color(srgb: 0x0D0E11)],
                                   startPoint: .leading, endPoint: .trailing)
                )
            // Knurling.
            GeometryReader { g in
                let n = 7
                Path { p in
                    for i in 0..<n {
                        let y = g.size.height * (CGFloat(i) + 0.5) / CGFloat(n)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                }
                .stroke(.black.opacity(0.55), lineWidth: max(0.6, unit * 0.022))
            }
            RoundedRectangle(cornerRadius: unit * 0.1)
                .strokeBorder(.black.opacity(0.8), lineWidth: max(0.8, unit * 0.035))
        }
        .frame(width: unit * wheelRect.w, height: unit * wheelRect.h)
        .position(x: unit * (bezel + wheelRect.x + wheelRect.w / 2),
                  y: unit * (bezel + wheelRect.y + wheelRect.h / 2))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Interaction

    /// One gesture with two jobs, because two gestures over the same board fight
    /// each other: without a drag behaviour it paints (the lighting pane selects
    /// a run of keys by sweeping across them); with one, the first press selects
    /// and any movement past a few points picks the key up instead.
    private func boardGesture(unit: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard dragBehaviour != nil else {
                    guard let key = key(at: g.location, unit: unit), isAvailable(key) else { return }
                    guard key.hid != dragKey else { return }
                    dragKey = key.hid
                    activate(key)
                    return
                }

                if pressedKey == nil, dragSource == nil {
                    pressedKey = key(at: g.startLocation, unit: unit)?.hid ?? 0
                    if let key = key(at: g.startLocation, unit: unit) { activate(key) }
                }

                // Picking a key up is a deliberate act; a two-point wobble while
                // clicking is not.
                let moved = hypot(g.translation.width, g.translation.height)
                if dragSource == nil, moved > 5, pickRequest == nil,
                   let start = key(at: g.startLocation, unit: unit),
                   dragBehaviour?.canDrag(start) == true {
                    dragSource = start
                }

                guard let source = dragSource else { return }
                dragPoint = g.location
                dragModifiers = ModifierFlagsReader.usages(in: NSEvent.modifierFlags)
                let over = key(at: g.location, unit: unit)
                dragTarget = over.flatMap { dragBehaviour?.canDrop(source, $0) == true ? $0 : nil }
            }
            .onEnded { _ in
                if let source = dragSource, let target = dragTarget {
                    dragBehaviour?.onDrop(source, target, dragModifiers)
                }
                dragKey = nil
                pressedKey = nil
                dragSource = nil
                dragTarget = nil
                dragPoint = nil
                dragModifiers = []
            }
    }


    /// Hit-test in key-unit space. Cheap, and it makes drag-to-paint and
    /// drag-to-select work without 90 competing gestures.
    private func key(at point: CGPoint, unit: CGFloat) -> Key? {
        let ux = point.x / unit - bezel
        let uy = point.y / unit - bezel
        return ApexProTKLGen3.keys(for: layout).first { k in
            ux >= k.x && ux < k.x + k.w && uy >= k.y && uy < k.y + k.h
        }
    }

}

// MARK: - Accessibility

/// Invisible, one per key, carrying the labels and actions VoiceOver needs.
///
/// A `Canvas` is a single opaque element to assistive technology, so the keys
/// have to be described separately. This layer is `Equatable` on purpose:
/// rebuilding ninety accessibility elements on every frame of an animated
/// effect was, by measurement, the single most expensive thing this view did —
/// more than all the drawing combined. None of it changes while an effect
/// plays, so SwiftUI is told it can skip the whole subtree.
private struct KeyAccessibilityLayer: View, Equatable {
    enum Mode { case select, pick }

    let keys: [Key]
    let unit: CGFloat
    let bezel: Double
    let selected: UInt8?
    let mode: Mode
    let describe: (Key) -> String
    let isEnabled: (Key) -> Bool
    let onKey: (Key) -> Void

    /// Closures cannot be compared, so equality covers the values the layout
    /// and labels are derived from. Callers must therefore keep `describe`
    /// stable while only the colours change — `LiveKeyboardView` drops the
    /// colour from its description for animated effects for exactly this
    /// reason (and because narrating a colour that changes twenty times a
    /// second helps nobody).
    nonisolated static func == (a: KeyAccessibilityLayer, b: KeyAccessibilityLayer) -> Bool {
        a.unit == b.unit
            && a.selected == b.selected
            && a.keys.count == b.keys.count
            && a.mode == b.mode
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(keys) { key in
                Color.clear
                    .frame(width: unit * key.w, height: unit * key.h)
                    .position(x: unit * (bezel + key.x + key.w / 2),
                              y: unit * (bezel + key.y + key.h / 2))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(describe(key))
                    .accessibilityAddTraits(selected == key.hid ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { if isEnabled(key) { onKey(key) } }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Keycap colour

/// The colour of one keycap, kept as plain numbers.
///
/// This is on the hot path: the lighting pane rebuilds ninety keycaps thirty
/// times a second, and every `NSColor(someSwiftUIColor)` round-trip in there
/// costs more than all the drawing put together. Everything derived from the
/// cap colour — the bevel stops, the legend contrast — comes off these three
/// Doubles instead.
private struct CapFace {
    let r: Double, g: Double, b: Double

    /// A keycap is unlit plastic *plus* whatever the LED emits, so the LED
    /// colour is screened over a graphite floor. A black LED leaves a real
    /// keycap behind instead of a hole in the board.
    init(_ led: LEDColor) {
        let floor = (r: 0.145, g: 0.157, b: 0.180)
        r = 1 - (1 - floor.r) * (1 - Double(led.r) / 255)
        g = 1 - (1 - floor.g) * (1 - Double(led.g) / 255)
        b = 1 - (1 - floor.b) * (1 - Double(led.b) / 255)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    func lightened(_ amount: Double) -> Color {
        Color(.sRGB, red: min(1, r + amount), green: min(1, g + amount), blue: min(1, b + amount))
    }

    func darkened(_ amount: Double) -> Color {
        Color(.sRGB, red: r * (1 - amount), green: g * (1 - amount), blue: b * (1 - amount))
    }

    var legendInk: Color {
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? .black.opacity(0.72) : .white.opacity(0.9)
    }
}

// MARK: - Live keyboard

/// A keyboard driven by a lighting config, animating in step with the frames
/// actually being streamed to the hardware.
struct LiveKeyboardView: View {
    let config: LightingConfig
    var selected: UInt8?
    var layout: KeyboardLayout = .ansi
    var oled: MonoBitmap?
    var onKey: ((Key) -> Void)?
    /// Live key-press times for the reactive effect, read once per frame.
    /// Absent for every other effect, which ignores them.
    var hits: (() -> [UInt8: TimeInterval])?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState

    /// The preview runs at 20 fps while the hardware is fed at 30.
    ///
    /// The keyboard needs 30 to keep the LEDs smooth; a colour wash on screen
    /// does not, and the extra third of the frames cost real CPU in a window
    /// that may be open all day.
    private static let previewFrameRate = 20.0

    var body: some View {
        // Stop drawing frames nobody is looking at. The keyboard itself keeps
        // being fed the whole time — this is the picture of it, not the thing.
        let visible = windowState != .inactive
        let animated = config.kind.isAnimated && !reduceMotion && visible
        return TimelineView(.animation(minimumInterval: 1 / Self.previewFrameRate,
                                       paused: !animated)) { timeline in
            // Key-press times come from the same monotonic clock the streamer
            // ages them against, so the fade on screen tracks the fade on the
            // board rather than running to its own schedule.
            let live = (animated && config.kind.usesReactive) ? (hits?() ?? [:]) : [:]
            let frame = LightingRender.render(
                config: config,
                time: animated ? timeline.date.timeIntervalSinceReferenceDate : 0,
                hits: live)
            KeyboardView(
                colorFor: { frame[$0.hid]?.scaled(by: config.brightness) ?? .black },
                selected: selected,
                layout: layout,
                style: .light,
                oled: oled,
                onKey: onKey,
                // While an effect plays the colour of a key is different every
                // frame, so naming it is both useless to a screen reader and
                // enough to defeat the accessibility layer's caching.
                describe: { key in
                    guard !animated else { return key.label }
                    let colour = frame[key.hid]?.scaled(by: config.brightness) ?? .black
                    return "\(key.label), \(colour.describedName)"
                }
            )
        }
    }
}

// MARK: - OLED pixels

/// Draws a `MonoBitmap` as a single image rather than five thousand rectangles.
///
/// `Equatable` so the keyboard render does not rebuild a 20 KB bitmap every
/// frame of an animated effect: the screen only changes when its contents do.
struct OLEDPixels: View, Equatable {
    let bitmap: MonoBitmap
    var color: Color = Theme.readout

    nonisolated static func == (a: OLEDPixels, b: OLEDPixels) -> Bool {
        a.bitmap == b.bitmap && a.color == b.color
    }

    var body: some View {
        if let cg = Self.image(from: bitmap, tint: color) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .aspectRatio(CGFloat(MonoBitmap.width) / CGFloat(MonoBitmap.height), contentMode: .fit)
        }
    }

    /// The tint is baked into the pixels rather than applied as a template.
    /// A lit pixel is opaque, an unlit one fully transparent, so the panel
    /// underneath shows through as the screen's own black.
    static func image(from bitmap: MonoBitmap, tint: Color) -> CGImage? {
        let ns = NSColor(tint).usingColorSpace(.sRGB) ?? .white
        let r = UInt8(max(0, min(1, ns.redComponent)) * 255)
        let g = UInt8(max(0, min(1, ns.greenComponent)) * 255)
        let b = UInt8(max(0, min(1, ns.blueComponent)) * 255)

        let w = MonoBitmap.width, h = MonoBitmap.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where bitmap.pixels[i] {
            // Little-endian, alpha first — in memory that is B, G, R, A.
            bytes[i * 4 + 0] = b
            bytes[i * 4 + 1] = g
            bytes[i * 4 + 2] = r
            bytes[i * 4 + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

extension LEDColor {
    /// A plain-language colour name, so VoiceOver can describe the board.
    var describedName: String {
        if luminance < 0.04 { return "off" }
        let maxC = Double(max(r, max(g, b))) / 255
        let minC = Double(min(r, min(g, b))) / 255
        if maxC - minC < 0.12 { return luminance > 0.7 ? "white" : "grey" }

        let rr = Double(r) / 255, gg = Double(g) / 255, bb = Double(b) / 255
        var hue: Double
        if maxC == rr { hue = (gg - bb) / (maxC - minC) }
        else if maxC == gg { hue = 2 + (bb - rr) / (maxC - minC) }
        else { hue = 4 + (rr - gg) / (maxC - minC) }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }

        switch hue {
        case ..<15, 345...: return "red"
        case ..<45: return "orange"
        case ..<70: return "yellow"
        case ..<160: return "green"
        case ..<200: return "cyan"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }
}
