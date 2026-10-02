import SwiftUI

// MARK: - Card

/// A flat panel. No shadow and no gradient: depth in this app is reserved for
/// the keyboard render, so everything around it stays matte.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var content: Content
    var accessory: Accessory

    init(title: String? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let title { Eyebrow(title) }
                    Spacer(minLength: Theme.Space.s)
                    accessory
                }
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Buttons

enum ButtonRole2 {
    case primary, secondary, quiet, destructive
}

struct ApexButton: ButtonStyle {
    var role: ButtonRole2 = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, role: role, compact: compact)
    }

    /// Deliberately not named `Body` — a nested type with that name collides
    /// with `ButtonStyle`'s associated type. Not private either: it is the
    /// witness for that associated type, so it must be as visible as the style.
    struct Face: View {
        let configuration: ButtonStyleConfiguration
        let role: ButtonRole2
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var pressed: Bool { configuration.isPressed }

        private var fill: Color {
            switch role {
            case .primary:
                return Theme.signal.opacity(pressed ? 0.78 : (hovering ? 1 : 0.92))
            case .secondary:
                return pressed ? Theme.surfaceLo : (hovering ? Theme.surfaceHi.opacity(1) : Theme.surfaceHi.opacity(0.75))
            case .quiet:
                return hovering ? Theme.surfaceHi.opacity(0.7) : .clear
            case .destructive:
                return Theme.danger.opacity(pressed ? 0.3 : (hovering ? 0.22 : 0.12))
            }
        }

        private var stroke: Color {
            switch role {
            case .primary: return .clear
            case .secondary: return hovering ? Theme.hairlineStrong : Theme.hairline
            case .quiet: return hovering ? Theme.hairline : .clear
            case .destructive: return Theme.danger.opacity(hovering ? 0.5 : 0.3)
            }
        }

        private var foreground: Color {
            switch role {
            case .primary: return Color(srgb: 0x140A04)
            case .secondary: return Theme.ink
            case .quiet: return hovering ? Theme.ink : Theme.ink2
            case .destructive: return Theme.danger
            }
        }

        var body: some View {
            configuration.label
                .font(compact ? Typo.captionMedium : Typo.calloutMedium)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .frame(minHeight: compact ? 24 : 28)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(stroke, lineWidth: 1)
                )
                .foregroundStyle(foreground)
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onHover { hovering = $0 && isEnabled }
                .animation(Theme.Motion.snap, value: hovering)
                .animation(Theme.Motion.snap, value: pressed)
        }
    }
}

extension ButtonStyle where Self == ApexButton {
    static var primary: ApexButton { ApexButton(role: .primary) }
    static var secondary: ApexButton { ApexButton(role: .secondary) }
    static var quiet: ApexButton { ApexButton(role: .quiet) }
    static var destructive: ApexButton { ApexButton(role: .destructive) }
    static var compactSecondary: ApexButton { ApexButton(role: .secondary, compact: true) }
    static var compactQuiet: ApexButton { ApexButton(role: .quiet, compact: true) }
}

/// A square icon-only button, for row actions where a word would be noise.
struct IconButton: View {
    let systemName: String
    var help: String
    var role: ButtonRole2 = .quiet
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive
                         ? Theme.danger.opacity(hovering ? 1 : 0.75)
                         : (hovering ? Theme.ink : Theme.ink3))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering
                      ? (role == .destructive ? Theme.danger.opacity(0.15) : Theme.surfaceHi)
                      : .clear)
        )
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snap, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Switch row

/// A toggle with its explanation attached, so settings copy lives next to the
/// control it describes instead of floating under the card.
///
/// The switch is laid out explicitly rather than as a `Toggle` label: letting
/// the label size the row puts every switch at a different x, and a column of
/// settings should line up.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.bodyMedium).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.textMeasure, alignment: .leading)
                }
            }
            Spacer(minLength: Theme.Space.s)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.signal)
                .accessibilityLabel(title)
        }
        // A card can be 1100 points wide; a switch stranded that far from its
        // label stops looking like it belongs to it.
        .frame(maxWidth: Theme.controlMeasure, alignment: .leading)
    }
}

// MARK: - Segmented rail

/// A segmented control built from scratch, because the system one draws its own
/// light-mode chrome that fights every surface in this app.
struct SegmentedRail<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let label: String
        var icon: String?
        var id: Value { value }
        init(_ value: Value, _ label: String, icon: String? = nil) {
            self.value = value
            self.label = label
            self.icon = icon
        }
    }

    @Binding var selection: Value
    let items: [Item]
    var fillsWidth = true

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                segment(item)
            }
        }
        .padding(2)
        .background(Theme.surfaceLo, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        // Segments that stretch the full width of a wide card become buttons the
        // size of a paragraph; the rail stays inside the control measure.
        .frame(maxWidth: fillsWidth ? Theme.controlMeasure : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ item: Item) -> some View {
        let isOn = selection == item.value
        return Button {
            selection = item.value
        } label: {
            HStack(spacing: 5) {
                if let icon = item.icon {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                }
                Text(item.label).font(Typo.captionMedium)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.surfaceHi)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "seg", in: ns)
                }
            }
            .foregroundStyle(isOn ? Theme.ink : Theme.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.Motion.snap, value: selection)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Scale control

/// A calibrated scale — the app's signature control.
///
/// Every important number here is a physical distance on a 4 mm travel, so a
/// generic 0…1 slider would throw away the one piece of information that
/// matters. This draws the scale itself: minor ticks per step, major ticks with
/// labels, a machined indicator rather than a round knob, and the value set as
/// an instrument readout.
struct ScaleControl: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    /// Draw a labelled major tick every N steps. 0 disables tick labels.
    var majorEvery: Int = 5
    /// The readout, e.g. `("1.5", "mm")`.
    var readout: (Double) -> (String, String?)
    /// Label under a major tick.
    var tickLabel: ((Double) -> String)?
    var tint: Color = Theme.signal
    var detents: [Double] = []

    @State private var isDragging = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private let trackHeight: CGFloat = 26
    private let indicatorWidth: CGFloat = 3

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var stepCount: Int {
        max(1, Int(((range.upperBound - range.lowerBound) / step).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Typo.caption).foregroundStyle(Theme.ink2)
                Spacer(minLength: Theme.Space.s)
                let r = readout(value)
                Readout(r.0, unit: r.1, size: 14, color: isEnabled ? Theme.ink : Theme.ink3)
            }

            GeometryReader { geo in
                let inset = indicatorWidth / 2 + 1
                let usable = max(1, geo.size.width - inset * 2)
                let x = inset + usable * fraction

                ZStack(alignment: .leading) {
                    // Well
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.surfaceLo)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: 1))

                    // Filled span
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(colors: [tint.opacity(0.50), tint.opacity(0.26)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: max(0, x))
                        .allowsHitTesting(false)

                    // Graduations, drawn over the fill so the scale stays
                    // readable on both sides of the indicator.
                    Canvas { ctx, size in
                        let usable = max(1, size.width - inset * 2)
                        for i in 0...stepCount {
                            let isMajor = majorEvery > 0 && i % majorEvery == 0
                            let tx = inset + usable * (Double(i) / Double(stepCount))
                            let h: CGFloat = isMajor ? 8 : 4
                            let rect = CGRect(x: tx - 0.5, y: size.height - h - 3, width: 1, height: h)
                            ctx.fill(Path(rect),
                                     with: .color(.white.opacity(isMajor ? 0.34 : 0.16)))
                        }
                    }
                    .allowsHitTesting(false)

                    // Machined indicator
                    ZStack {
                        Capsule().fill(tint)
                            .frame(width: indicatorWidth, height: trackHeight - 6)
                        Capsule().fill(Color.white.opacity(isDragging ? 0.9 : (hovering ? 0.55 : 0.3)))
                            .frame(width: indicatorWidth, height: 6)
                            .offset(y: -(trackHeight - 6) / 2 + 3)
                    }
                    .shadow(color: tint.opacity(isDragging ? 0.75 : 0.4), radius: isDragging ? 6 : 3)
                    .offset(x: x - indicatorWidth / 2)
                    .allowsHitTesting(false)
                }
                .frame(height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isDragging = true
                            setValue(fromX: g.location.x, width: geo.size.width, inset: inset)
                        }
                        .onEnded { _ in isDragging = false }
                )
                .onHover { hovering = $0 }
            }
            .frame(height: trackHeight)

            if majorEvery > 0, let tickLabel {
                HStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, through: stepCount, by: majorEvery)), id: \.self) { i in
                        let v = range.lowerBound + Double(i) * step
                        Text(tickLabel(v))
                            .font(Typo.readout(9, weight: .regular))
                            .foregroundStyle(Theme.ink3.opacity(0.8))
                            .frame(maxWidth: .infinity,
                                   alignment: i == 0 ? .leading : (i == stepCount ? .trailing : .center))
                    }
                }
                .padding(.top, -2)
            }
        }
        .frame(maxWidth: Theme.controlMeasure, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(isDragging ? nil : Theme.Motion.snap, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue({ let r = readout(value); return "\(r.0) \(r.1 ?? "")" }())
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func setValue(fromX x: CGFloat, width: CGFloat, inset: CGFloat) {
        let usable = max(1, width - inset * 2)
        let f = min(1, max(0, (x - inset) / usable))
        var raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
        raw = (raw / step).rounded() * step

        // Snap to a meaningful value when the pointer is within half a step.
        if let nearest = detents.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(nearest - raw) <= step {
            raw = nearest
        }
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        if clamped != value { value = clamped }
    }
}

extension ScaleControl {
    /// Integer-valued convenience — actuation levels, sensitivity, etc.
    static func integer(label: String,
                        value: Binding<Int>,
                        range: ClosedRange<Int>,
                        majorEvery: Int = 5,
                        tint: Color = Theme.signal,
                        detents: [Int] = [],
                        readout: @escaping (Int) -> (String, String?),
                        tickLabel: ((Int) -> String)? = nil) -> ScaleControl {
        ScaleControl(
            label: label,
            value: Binding(get: { Double(value.wrappedValue) },
                           set: { value.wrappedValue = Int($0.rounded()) }),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: 1,
            majorEvery: majorEvery,
            readout: { readout(Int($0.rounded())) },
            tickLabel: tickLabel.map { f in { v in f(Int(v.rounded())) } },
            tint: tint,
            detents: detents.map(Double.init)
        )
    }
}

// MARK: - Banner

enum BannerKind {
    case error, warning, info

    var color: Color {
        switch self {
        case .error: return Theme.danger
        case .warning: return Theme.warn
        case .info: return Theme.readout
        }
    }

    var icon: String {
        switch self {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct Banner: View {
    let kind: BannerKind
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(kind.color)
                .padding(.top, 0.5)
            Text(message)
                .font(Typo.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            if let onDismiss {
                IconButton(systemName: "xmark", help: "Dismiss", action: onDismiss)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(kind.color.opacity(0.28), lineWidth: 1)
        )
    }
}

/// A quiet, inline note. Used where the old build had a floating paragraph of
/// grey text under a control.
struct Note: View {
    let text: String
    var icon: String?
    var color: Color = Theme.ink3

    init(_ text: String, icon: String? = nil, color: Color = Theme.ink3) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                    .padding(.top, 1)
            }
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Theme.textMeasure, alignment: .leading)
    }
}

// MARK: - Empty state

struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    var action: Action

    init(icon: String, title: String, message: String, @ViewBuilder action: () -> Action) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink3)
            Text(title).font(Typo.bodyMedium).foregroundStyle(Theme.ink2)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            action.padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

extension EmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message, action: { EmptyView() })
    }
}

// MARK: - Tags and rows

/// States where a setting is kept. Answers "will this survive quitting?" without
/// a paragraph of explanation.
///
/// For keyboard-stored panes the tag reports the **live** persistence state,
/// because "stored in the keyboard" has two different truths: RAM (gone at
/// power-off) and flash (the boot profile). The tag must never claim the
/// second while only the first has happened.
struct StorageTag: View {
    let storage: StorageKind
    var persist: DeviceController.PersistState? = nil

    private var label: String {
        guard storage == .keyboard, let persist else { return storage.label }
        switch persist {
        case .unknown: return storage.label
        case .saved: return "Saved in the keyboard"
        case .pending, .saving: return "Saving to the keyboard…"
        case .failed: return "Not saved to the keyboard"
        case .unsupported: return "Can't save to this keyboard"
        }
    }

    private var tint: Color {
        guard storage == .keyboard else { return Theme.ink3 }
        switch persist {
        case .failed, .unsupported: return Theme.warn
        case .pending, .saving: return Theme.ink2
        default: return Theme.readout
        }
    }

    private var detail: String {
        guard storage == .keyboard, let persist else { return storage.detail }
        switch persist {
        case .unknown:
            return storage.detail
        case .saved:
            return "Saved into the keyboard's onboard profile and read back, so it should survive unplugging and "
                + "work on any computer."
        case .pending, .saving:
            return "Applied to the keyboard. Writing it into the keyboard's onboard profile so it should also "
                + "survive unplugging."
        case .failed(let why):
            return "Applied to the keyboard, but saving it into the onboard profile failed — it will not survive "
                + "unplugging. \(why)"
        case .unsupported(let why):
            return "Applied to the keyboard, but this keyboard's saved profile could not be updated, so changes "
                + "will not survive unplugging. \(why)"
        }
    }

    var body: some View {
        if storage != .none {
            HStack(spacing: 4) {
                Image(systemName: storage.icon).font(.system(size: 9, weight: .medium))
                Text(label).font(Typo.eyebrow).tracking(0.9)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(storage == .keyboard ? tint.opacity(0.10) : Theme.surfaceHi.opacity(0.6))
            )
            .overlay(
                Capsule().strokeBorder(
                    storage == .keyboard ? tint.opacity(0.25) : Theme.hairline, lineWidth: 1)
            )
            .help(detail)
        }
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.ink3
    var filled = false

    var body: some View {
        Text(text.uppercased())
            .font(Typo.eyebrow)
            .tracking(0.9)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(filled ? 0.18 : 0.08)))
    }
}

/// A label/value line. The value is a readout, so a stack of these aligns.
struct InfoRow: View {
    let label: String
    let value: String
    var mono = true
    var color: Color = Theme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typo.callout).foregroundStyle(Theme.ink3)
            Spacer(minLength: Theme.Space.m)
            Text(value)
                .font(mono ? Typo.readout(12) : Typo.calloutMedium)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Hairline divider tuned for these surfaces — `Divider()` picks up a system
/// colour that reads as a light grey line on graphite.
struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

// MARK: - Field styling

/// A text field that matches the rest of the chassis.
struct ApexFieldStyle: TextFieldStyle {
    var mono = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(mono ? Typo.readout(12) : Typo.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.surfaceLo, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension TextFieldStyle where Self == ApexFieldStyle {
    static var apex: ApexFieldStyle { ApexFieldStyle() }
    static var apexMono: ApexFieldStyle { ApexFieldStyle(mono: true) }
}

/// Menu-style pickers inherit system chrome; this keeps them on-palette.
struct ApexPickerChrome: ViewModifier {
    var width: CGFloat?
    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .font(Typo.callout)
            .tint(Theme.signal)
            .frame(width: width)
    }
}

extension View {
    func apexPicker(width: CGFloat? = nil) -> some View {
        modifier(ApexPickerChrome(width: width))
    }
}


// MARK: - Confirmation

extension View {
    /// A confirmation whose title, message and action all come from the change
    /// being confirmed, so the two can never describe different things.
    func confirmationDialog<Item: Identifiable, Actions: View>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: @escaping (Item) -> String,
        @ViewBuilder actions: @escaping (Item) -> Actions
    ) -> some View {
        confirmationDialog(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil },
                                 set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue,
            actions: actions,
            message: { Text(message($0)) }
        )
    }
}
