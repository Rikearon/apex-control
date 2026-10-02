import SwiftUI
import ApexKit

/// True while the snapshot harness is rendering.
///
/// `ImageRenderer` cannot draw `List` or `ScrollView`, so those two containers
/// are swapped for plain stacks during a capture. Nothing else changes, and the
/// shipping app always uses the native containers — the harness bends to the
/// app, not the other way round.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotting: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var nav: Navigator

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn()
                .navigationSplitViewColumnWidth(min: 208, ideal: 226, max: 268)
        } detail: {
            DetailColumn()
        }
        .navigationTitle(nav.pane.title)
        .toolbar { PaneToolbar() }
        .toolbarBackground(Theme.chassis, for: .windowToolbar)
        .tint(Theme.signal)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sidebar

struct SidebarColumn: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var nav: Navigator
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            if isSnapshotting {
                snapshotList
                Spacer(minLength: 0)
            } else {
                navigationList
            }
            Rule()
            DeviceStatusFooter()
        }
        .background(Theme.chassis)
    }

    /// Stand-in for `List` during a capture; same rows, same selection accent.
    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Pane.groups, id: \.0) { group in
                Eyebrow(group.0)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 3)
                ForEach(group.1) { pane in
                    row(pane)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(nav.pane == pane ? Theme.signal.opacity(0.85) : .clear)
                        )
                        .foregroundStyle(nav.pane == pane ? .white : Theme.ink2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var identity: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.signal.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.signal)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Apex Control")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Eyebrow("Pro TKL Gen 3")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var navigationList: some View {
        List(selection: $nav.pane) {
            ForEach(Pane.groups, id: \.0) { group in
                Section {
                    ForEach(group.1) { pane in
                        row(pane).tag(pane)
                    }
                } header: {
                    Eyebrow(group.0).padding(.top, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.chassis)
        .environment(\.defaultMinListRowHeight, 28)
    }

    @ViewBuilder
    private func row(_ pane: Pane) -> some View {
        HStack(spacing: 0) {
            Label {
                Text(pane.title).font(Typo.body)
            } icon: {
                Image(systemName: pane.icon).font(.system(size: 12))
            }
            Spacer(minLength: 6)
            if let badge = badge(for: pane) {
                Text(badge)
                    .font(Typo.readout(10))
                    .foregroundStyle(nav.pane == pane ? Theme.ink : Theme.ink3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .help(pane.subtitle)
    }

    /// Counts that tell you where you have made changes, so the sidebar reports
    /// state instead of only listing destinations.
    private func badge(for pane: Pane) -> String? {
        switch pane {
        case .bindings:
            let n = controller.bindings.changedCount
            return n > 0 ? "\(n)" : nil
        case .rapidTap:
            let n = controller.rapidTap.enabled ? controller.rapidTap.validPairs.count : 0
            return n > 0 ? "\(n)" : nil
        case .actuation:
            let n = controller.actuation.usePerKey ? controller.actuation.perKey.count : 0
            return n > 0 ? "\(n)" : nil
        default:
            return nil
        }
    }
}

// MARK: - Device status

struct DeviceStatusFooter: View {
    @EnvironmentObject var controller: DeviceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ZStack {
                    if controller.isConnected && !reduceMotion {
                        Circle()
                            .fill(Theme.ok.opacity(0.35))
                            .frame(width: 14, height: 14)
                            .scaleEffect(pulse ? 1.0 : 0.55)
                            .opacity(pulse ? 0 : 0.9)
                    }
                    Circle()
                        .fill(controller.isConnected ? Theme.ok : Theme.ink3)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 14, height: 14)

                Text(controller.isConnected ? "Connected" : "No keyboard")
                    .font(Typo.captionMedium)
                    .foregroundStyle(controller.isConnected ? Theme.ink : Theme.ink2)
                Spacer(minLength: 0)
            }

            if controller.isConnected {
                HStack(spacing: 5) {
                    Text(controller.firmware).font(Typo.readout(10))
                    Text("·").foregroundStyle(Theme.ink3.opacity(0.5))
                    Text(controller.regionName).font(Typo.readout(10))
                    if let layout = controller.layout {
                        Text("·").foregroundStyle(Theme.ink3.opacity(0.5))
                        Text(layout.shortName).font(Typo.readout(10))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
            } else {
                Text(controller.statusMessage)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startPulse() }
        .onChange(of: controller.isConnected) { _, _ in startPulse() }
        .accessibilityElement(children: .combine)
    }

    private func startPulse() {
        guard controller.isConnected, !reduceMotion else { pulse = false; return }
        pulse = false
        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: - Detail column

struct DetailColumn: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var nav: Navigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        ZStack(alignment: .top) {
            Theme.void.ignoresSafeArea()

            if isSnapshotting {
                column
            } else {
                ScrollView { column }
                    .scrollBounceBehavior(.basedOnSize)
            }

            messages
        }
        .animation(reduceMotion ? nil : Theme.Motion.pane, value: nav.pane)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            contextBar
            paneContent
                .id(nav.pane)
                .transition(reduceMotion
                            ? .opacity
                            : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                          removal: .opacity))
        }
        .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Subtitle plus where the settings on this pane are kept. The window title
    /// bar already carries the pane name, so it is not repeated here.
    private var contextBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(nav.pane.subtitle)
                .font(Typo.callout)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.m)
            StorageTag(storage: nav.pane.storage,
                       persist: controller.isConnected ? controller.persistState : nil)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch nav.pane {
        case .lighting: LightingView()
        case .bindings: BindingsView()
        case .oled: OLEDView()
        case .actuation: ActuationView()
        case .rapidTrigger: RapidTriggerView()
        case .rapidTap: RapidTapView()
        case .profiles: ProfilesView()
        case .settings: SettingsView()
        }
    }

    /// Floating messages, so an error or confirmation never reflows the pane
    /// underneath it.
    private var messages: some View {
        VStack(spacing: Theme.Space.s) {
            if let error = controller.lastError {
                Banner(kind: .error, message: error) {
                    controller.lastError = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let note = controller.actionNote {
                Banner(kind: .info, message: note)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.s)
        .frame(maxWidth: Theme.contentMaxWidth)
        .animation(reduceMotion ? nil : Theme.Motion.reveal, value: controller.lastError)
        .animation(reduceMotion ? nil : Theme.Motion.reveal, value: controller.actionNote)
    }
}

// MARK: - Toolbar

private struct PaneToolbar: ToolbarContent {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var nav: Navigator

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch nav.pane {
            case .lighting:
                Button {
                    controller.setLightingOff(!controller.isLightingOff)
                } label: {
                    Label(controller.isLightingOff ? "Turn lighting on" : "Turn lighting off",
                          systemImage: controller.isLightingOff ? "lightbulb.slash" : "lightbulb.fill")
                }
                .help(controller.isLightingOff
                      ? "Light the keyboard again"
                      : "Hand lighting back to the keyboard")

            case .bindings:
                Button {
                    controller.readBindingsFromDevice(seedEditor: true)
                } label: {
                    Label("Read from keyboard", systemImage: "arrow.down.doc")
                }
                .disabled(!controller.isConnected || controller.isReadingBindings)
                .help("Load the bindings the keyboard is actually using")

            case .oled:
                Button {
                    controller.persistOLED()
                } label: {
                    Label("Save to keyboard", systemImage: "internaldrive")
                }
                .disabled(!controller.canPersistOLED)
                .help("Write this screen into the keyboard so it survives quitting")

            case .profiles:
                Button {
                    store.markApplied(store.add(controller.captureCurrent(name: store.nextProfileName())).id)
                } label: {
                    Label("Save current setup", systemImage: "plus")
                }
                .help("Capture everything the keyboard is doing right now as a profile")

            case .actuation, .rapidTrigger, .rapidTap, .settings:
                EmptyView()
            }
        }
    }
}

// MARK: - Small extensions

extension KeyboardLayout {
    var shortName: String {
        switch self {
        case .ansi: return "ANSI"
        case .iso: return "ISO"
        case .jis: return "JIS"
        }
    }
}
