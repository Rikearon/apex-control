import SwiftUI
import ApexKit

// MARK: - Selectable chip

/// One choice in a grid. Big enough to hit, quiet enough that forty of them do
/// not shout, and it says what it is rather than needing a legend.
struct ChoiceChip: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var isOn: Bool
    var isHighlighted = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typo.captionMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typo.readout(9, weight: .regular))
                            .foregroundStyle(isOn ? Color(srgb: 0x140A04).opacity(0.7) : Theme.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isHighlighted && !isOn ? Theme.signal.opacity(0.7)
                                  : (isOn ? .clear : Theme.hairline), lineWidth: 1)
            )
            .foregroundStyle(isOn ? Color(srgb: 0x140A04) : Theme.ink)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isOn { return Theme.signal }
        if hovering { return Theme.surfaceHi }
        if isHighlighted { return Theme.surfaceHi.opacity(0.6) }
        return Theme.surfaceLo
    }
}

// MARK: - Usage picker

/// "Which key should this send?" as a search field over every HID usage the
/// keyboard can emit — including the ones this board does not physically have,
/// like F13–F24 and the keypad, which is precisely why a picker has to exist
/// alongside pressing the key or dragging one.
///
/// Typing filters; ↑/↓ move; Return picks; Escape closes. That set of keys is
/// what makes this usable without the mouse, and it is also the whole
/// accessibility story for the drag-and-drop shortcut on the board.
struct UsagePickerPopover: View {
    var current: UInt8?
    var onPick: (UInt8) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var highlighted: Int = 0
    @FocusState private var searchFocused: Bool

    private var results: [HIDUsage.Entry] { HIDUsage.search(query) }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 5)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rule()
            if results.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.ink3)
                    .padding(Theme.Space.l)
            } else {
                list
            }
        }
        .frame(width: 460)
        .frame(maxHeight: 420)
        .background(Theme.surface)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
            TextField("Search keys — “esc”, “f13”, “keypad 5”, “0x1A”", text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onSubmit { pickHighlighted() }
                .accessibilityLabel("Search for a key to send")
                // On the focused view rather than an ancestor: a text field
                // consumes the arrow keys for its own insertion point, and an
                // outer handler would never see them. Return picks the top
                // match either way, which is the path most people take.
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
            if !query.isEmpty {
                IconButton(systemName: "xmark.circle.fill", help: "Clear") { query = "" }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 9)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                    ForEach(Array(results.enumerated()), id: \.element.usage) { index, entry in
                        ChoiceChip(
                            title: entry.name,
                            subtitle: subtitle(for: entry),
                            isOn: entry.usage == current,
                            isHighlighted: index == highlighted
                        ) {
                            onPick(entry.usage)
                        }
                        .id(index)
                    }
                }
                .padding(Theme.Space.m)
            }
            .onChange(of: highlighted) { _, new in
                withAnimation(Theme.Motion.snap) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// The group for a browse, the usage code for a search: when someone types
    /// "0x1a" they want to see the code confirmed back.
    private func subtitle(for entry: HIDUsage.Entry) -> String {
        query.isEmpty ? entry.group : String(format: "0x%02X", entry.usage)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(0, highlighted + delta), results.count - 1)
    }

    private func pickHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        onPick(results[highlighted].usage)
    }
}

// MARK: - Media

/// The media controls as a board of buttons rather than a drop-down.
///
/// Six of these are what the keyboard already drives on its own media keys and
/// are the only ones known to work; the standard-but-unverified rest are one
/// disclosure away instead of mixed in, so a first choice is a choice between
/// six obvious things.
struct MediaActionGrid: View {
    var current: Mappings.ConsumerAction?
    var onPick: (Mappings.ConsumerAction) -> Void

    @State private var showAll = false

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 190), spacing: 5)]

    private var verified: [Mappings.ConsumerAction] {
        Mappings.ConsumerAction.allCases.filter(\.isVerifiedOnThisFirmware)
    }
    private var rest: [Mappings.ConsumerAction] {
        Mappings.ConsumerAction.allCases.filter { !$0.isVerifiedOnThisFirmware }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach(verified) { action in
                    ChoiceChip(title: action.displayName, icon: icon(action),
                               isOn: action == current) { onPick(action) }
                }
            }
            .frame(maxWidth: Theme.controlMeasure, alignment: .leading)

            DisclosureRow(title: "Other standard media controls",
                          detail: "Defined by the HID standard. This firmware may ignore them.",
                          isExpanded: $showAll)

            if showAll {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                    ForEach(rest) { action in
                        ChoiceChip(title: action.displayName, icon: icon(action),
                                   isOn: action == current) { onPick(action) }
                    }
                }
                .frame(maxWidth: Theme.controlMeasure, alignment: .leading)
            }
        }
    }

    private func icon(_ a: Mappings.ConsumerAction) -> String {
        switch a {
        case .playPause: return "playpause.fill"
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .stop: return "stop.fill"
        case .nextTrack: return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .fastForward: return "forward.fill"
        case .rewind: return "backward.fill"
        case .mute: return "speaker.slash.fill"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .launchEmail: return "envelope.fill"
        case .launchCalculator: return "function"
        case .launchBrowser, .browserHome: return "globe"
        case .launchMediaPlayer: return "music.note"
        case .browserBack: return "chevron.left"
        case .browserForward: return "chevron.right"
        case .browserRefresh: return "arrow.clockwise"
        case .browserSearch: return "magnifyingglass"
        }
    }
}

// MARK: - Mouse

/// Mouse actions laid out the way a mouse is: the three buttons you can point
/// at, then the thumb buttons, then the wheel.
struct MouseActionGrid: View {
    var current: Mappings.MouseAction?
    var onPick: (Mappings.MouseAction) -> Void

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 180), spacing: 5)]

    private let groups: [(String, [Mappings.MouseAction])] = [
        ("Buttons", [.button1, .button2, .button3, .button4, .button5]),
        ("Extra buttons", [.button6, .button7, .button8]),
        ("Wheel", [.wheelUp, .wheelDown, .panLeft, .panRight]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(groups, id: \.0) { name, actions in
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(name)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                        ForEach(actions) { action in
                            ChoiceChip(title: action.displayName, icon: icon(action),
                                       isOn: action == current) { onPick(action) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: Theme.controlMeasure, alignment: .leading)
    }

    private func icon(_ a: Mappings.MouseAction) -> String {
        switch a {
        case .button1: return "cursorarrow.click"
        case .button2: return "cursorarrow.click.2"
        case .button3: return "computermouse.fill"
        case .button4: return "arrow.left.circle"
        case .button5: return "arrow.right.circle"
        case .wheelUp: return "arrow.up"
        case .wheelDown: return "arrow.down"
        case .panLeft: return "arrow.left"
        case .panRight: return "arrow.right"
        default: return "computermouse"
        }
    }
}

// MARK: - Disclosure

/// A disclosure that reads as a sentence rather than a widget.
struct DisclosureRow: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(Theme.Motion.reveal) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typo.captionMedium)
                    if let detail, isExpanded {
                        Text(detail).font(Typo.caption).foregroundStyle(Theme.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Theme.textMeasure, alignment: .leading)
    }
}
