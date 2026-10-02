import SwiftUI
import ApexKit

struct SettingsView: View {
    @EnvironmentObject var controller: DeviceController
    @EnvironmentObject var prefs: AppPrefs
    @EnvironmentObject var loginItem: LoginItemManager

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.l) {
                startupCard
                backgroundCard
            }
            VStack(spacing: Theme.Space.l) {
                deviceCard
                permissionCard
            }
            .frame(width: 320)
        }
        .onAppear {
            loginItem.refresh()
            controller.refreshReactiveInput()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            controller.refreshReactiveInput()
        }
    }

    // MARK: - Startup

    private var startupCard: some View {
        Card(title: "Startup") {
            SwitchRow(
                title: "Open at login",
                detail: "Apex Control starts with your Mac and lights the keyboard before you get to it.",
                isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
            )

            if let explanation = loginItem.explanation {
                Banner(kind: .warning, message: explanation)
                Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                    .buttonStyle(.secondary)
            }

            Rule()

            SwitchRow(
                title: "Restore the last profile on launch",
                detail: "After a restart the keyboard comes back looking the way you left it.",
                isOn: $prefs.applyLastProfileOnLaunch
            )
        }
    }

    // MARK: - Background

    private var backgroundCard: some View {
        Card(title: "While you work") {
            Note("Effects are drawn by this app, so it has to be running for them to show. "
                 + "These keep it out of the way while it is.", icon: "info.circle")

            Rule()

            SwitchRow(
                title: "Keep running when the window is closed",
                detail: "Turn this off and closing the window quits Apex Control — animated effects stop with it.",
                isOn: $prefs.runInBackground
            )

            Rule()

            SwitchRow(
                title: "Show in the Dock",
                detail: "Off hides Apex Control from the Dock and the app switcher. The menu-bar icon stays, "
                    + "so you can always get back in.",
                isOn: $prefs.showDockIcon
            )

            Rule()

            SwitchRow(
                title: "Re-light after the Mac wakes",
                detail: "The keyboard drops host lighting when it sleeps, so Apex Control switches it back on "
                    + "and resends the current frame and screen.",
                isOn: $prefs.reapplyOnWake
            )

            SwitchRow(
                title: "Pause effects while the Mac sleeps",
                detail: "Stops rendering frames nobody can see.",
                isOn: $prefs.pauseWhileAsleep
            )
        }
    }

    // MARK: - Device

    private var deviceCard: some View {
        Card(title: "Keyboard") {
            InfoRow(label: "Status",
                    value: controller.isConnected ? "Connected" : "Not found",
                    mono: false,
                    color: controller.isConnected ? Theme.ok : Theme.ink2)
            InfoRow(label: "Firmware", value: controller.firmware)
            InfoRow(label: "Region", value: controller.regionName)
            InfoRow(label: "Layout", value: controller.layout?.displayName ?? "—")

            Rule()

            InfoRow(label: "Lit keys", value: "\(ApexProTKLGen3.ledHIDOrder.count)")
            InfoRow(label: "Adjustable keys", value: "\(ApexProTKLGen3.analogHIDOrder.count)")
            InfoRow(label: "Rebindable keys", value: "\(ApexProTKLGen3.mappableHIDOrder.count)")

            if !controller.isConnected {
                Rule()
                Note("Plug the keyboard in with its USB cable. Apex Control picks it up on its own — "
                     + "there is nothing to press.", icon: "cable.connector")
            }
        }
    }

    // MARK: - Permissions

    private var permissionCard: some View {
        // Two separate grants, either of which is enough, in two different
        // panes of System Settings. Both are shown because "it says granted but
        // nothing happens" is nearly always the other one.
        let status = controller.reactiveInput
        return Card(title: "Permissions") {
            permissionRow(title: "Input Monitoring", granted: status.inputMonitoring) {
                KeyMonitor.openInputMonitoringSettings()
            }
            permissionRow(title: "Accessibility", granted: status.accessibility) {
                KeyMonitor.openAccessibilitySettings()
            }

            if !status.hasAnyGrant {
                Button("Grant permission…") { controller.requestReactiveInputPermission() }
                    .buttonStyle(.secondary)
            }

            Rule()

            switch status.listener {
            case .listening:
                Note("Reactive lighting is watching key presses.",
                     icon: "checkmark.circle.fill", color: Theme.ok)
            case .needsRelaunch:
                Note("Granted, but macOS only hands the permission to apps that start after it. "
                     + "Quit and reopen Apex Control.", icon: "arrow.clockwise.circle.fill", color: Theme.warn)
            case .degraded:
                Note("The listener is running but macOS is delivering only modifier keys to it"
                     + (status.hasAnyGrant
                        ? " — the grant on record is not being honoured for this copy of the app. "
                          + "Quit and reopen; if that is not enough, remove Apex Control from the "
                          + "permission list with “−” and add this copy again."
                        : ". Grant Input Monitoring or Accessibility above."),
                     icon: "ear.trianglebadge.exclamationmark", color: Theme.warn)
            case .needsPermission:
                Note("Reactive lighting asked to watch key presses and macOS refused.",
                     icon: "lock.fill", color: Theme.warn)
            case .off:
                Note("Only the Reactive lighting effect needs this. Lighting, actuation, bindings and the "
                     + "screen all work without it, because the keyboard exposes its controls to any app.")
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Theme.ok : Theme.ink3)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.bodyMedium).foregroundStyle(Theme.ink)
                Text(granted ? "Granted" : "Not granted")
                    .font(Typo.caption)
                    .foregroundStyle(granted ? Theme.ok : Theme.ink3)
            }
            Spacer(minLength: 0)
            Button("Open…", action: open).buttonStyle(.compactSecondary)
        }
    }
}
