import SwiftUI
import AppKit
import ApexKit

/// The menu-bar panel. Built from the same models as the main window, so the
/// two can never disagree.
struct MenuBarView: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var navigator: Navigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header

            Rule()

            lighting

            Rule()

            screenAndProfile

            Rule()

            actions
        }
        .padding(Theme.Space.m)
        .frame(width: 296)
        .background(Theme.chassis)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(controller.isConnected ? Theme.ok : Theme.ink3)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text("Apex Pro TKL Gen 3")
                    .font(Typo.captionMedium).foregroundStyle(Theme.ink)
                Text(controller.isConnected
                     ? "Connected · \(controller.firmware)"
                     : controller.statusMessage)
                    .font(Typo.caption).foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Lighting

    private var lighting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle("Lighting", isOn: Binding(
                get: { !controller.isLightingOff && !controller.isHandedBack },
                set: { controller.setLightingOff(!$0) })
            )
            .toggleStyle(.switch)
            .tint(Theme.signal)
            .font(Typo.calloutMedium)
            .foregroundStyle(Theme.ink)

            Picker("Effect", selection: Binding(
                get: { controller.lighting.kind },
                set: { controller.selectEffect($0) })
            ) {
                ForEach(EffectKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .font(Typo.callout)
            .disabled(controller.isLightingOff)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Brightness").font(Typo.caption).foregroundStyle(Theme.ink3)
                    Spacer()
                    Readout("\(Int(controller.lighting.brightness * 100))", unit: "%", size: 11,
                            color: Theme.ink2)
                }
                Slider(value: $controller.lighting.brightness, in: 0...1)
                    .tint(Theme.signal)
                    .controlSize(.small)
                    .disabled(controller.isLightingOff)
            }
        }
    }

    // MARK: - Screen and profile

    private var screenAndProfile: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Screen", selection: Binding(
                get: { controller.oled.mode },
                set: { controller.oled.mode = $0; controller.applyOLED() })
            ) {
                ForEach(OLEDConfig.Mode.allCases) { Text($0.displayName).tag($0) }
            }
            .font(Typo.callout)

            if store.profiles.isEmpty {
                HStack {
                    Text("Profiles").font(Typo.caption).foregroundStyle(Theme.ink3)
                    Spacer()
                    Text("None saved").font(Typo.caption).foregroundStyle(Theme.ink3)
                }
            } else {
                Picker("Profile", selection: Binding(
                    get: { store.appliedProfileID ?? store.profiles[0].id },
                    set: { id in
                        guard let p = store.profile(id: id) else { return }
                        controller.apply(p)
                        store.markApplied(p.id)
                    })
                ) {
                    ForEach(store.profiles) { Text($0.name).tag($0.id) }
                }
                .font(Typo.callout)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuAction("Open Apex Control", icon: "macwindow") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            MenuAction("Hand lighting back to the keyboard", icon: "keyboard") {
                controller.handBackToKeyboard()
            }
            MenuAction("Reset all key bindings", icon: "arrow.uturn.backward") {
                controller.resetAllBindings()
            }
            Divider().padding(.vertical, 3)
            MenuAction("Quit Apex Control", icon: "power", shortcut: "⌘Q",
                       key: KeyboardShortcut("q")) {
                NSApp.terminate(nil)
            }
        }
    }
}

/// A menu row that behaves like one: full-width hit area and a hover highlight.
/// Plain `Button`s in a `MenuBarExtra` window render as inert text.
private struct MenuAction: View {
    let title: String
    let icon: String
    var shortcut: String?
    var key: KeyboardShortcut?
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, icon: String, shortcut: String? = nil,
         key: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.key = key
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 15)
                    .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                Text(title).font(Typo.callout)
                Spacer(minLength: Theme.Space.s)
                if let shortcut {
                    Text(shortcut).font(Typo.readout(10)).foregroundStyle(Theme.ink3)
                }
            }
            .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.surfaceHi : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(key)
    }
}
