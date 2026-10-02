import Foundation
import SwiftUI
import ServiceManagement

/// User preferences that outlive a launch (PRD-15 FR-7). Backed by
/// `UserDefaults` and published so the menu bar and Settings pane stay in sync.
@MainActor
final class AppPrefs: ObservableObject {

    private enum Key {
        static let runInBackground = "runInBackground"
        static let showDockIcon = "showDockIcon"
        static let applyLastProfileOnLaunch = "applyLastProfileOnLaunch"
        static let reapplyOnWake = "reapplyOnWake"
        static let pauseWhileAsleep = "pauseWhileAsleep"
        static let hasShownBackgroundHint = "hasShownBackgroundHint"
    }

    private let defaults: UserDefaults

    /// Keep effects running when the last window closes. On by default: a
    /// host-rendered effect only exists while the app is alive, so quitting on
    /// window close would make the keyboard go dark every time (PRD-15 §2).
    @Published var runInBackground: Bool { didSet { defaults.set(runInBackground, forKey: Key.runInBackground) } }
    /// Start `.regular` (discoverable) and let people opt into menu-bar-only.
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) } }
    @Published var applyLastProfileOnLaunch: Bool { didSet { defaults.set(applyLastProfileOnLaunch, forKey: Key.applyLastProfileOnLaunch) } }
    @Published var reapplyOnWake: Bool { didSet { defaults.set(reapplyOnWake, forKey: Key.reapplyOnWake) } }
    @Published var pauseWhileAsleep: Bool { didSet { defaults.set(pauseWhileAsleep, forKey: Key.pauseWhileAsleep) } }
    @Published var hasShownBackgroundHint: Bool { didSet { defaults.set(hasShownBackgroundHint, forKey: Key.hasShownBackgroundHint) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.runInBackground: true,
            Key.showDockIcon: true,
            Key.applyLastProfileOnLaunch: true,
            Key.reapplyOnWake: true,
            Key.pauseWhileAsleep: false,
            Key.hasShownBackgroundHint: false,
        ])
        runInBackground = defaults.bool(forKey: Key.runInBackground)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        applyLastProfileOnLaunch = defaults.bool(forKey: Key.applyLastProfileOnLaunch)
        reapplyOnWake = defaults.bool(forKey: Key.reapplyOnWake)
        pauseWhileAsleep = defaults.bool(forKey: Key.pauseWhileAsleep)
        hasShownBackgroundHint = defaults.bool(forKey: Key.hasShownBackgroundHint)
    }
}

/// Wraps `SMAppService` so "start at login" reflects the real system state,
/// including changes the user makes in System Settings › Login Items.
@MainActor
final class LoginItemManager: ObservableObject {

    @Published private(set) var isEnabled = false
    /// Set when registration is impossible in this build/location.
    @Published private(set) var explanation: String?

    init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            explanation = nil
        case .requiresApproval:
            isEnabled = false
            explanation = "macOS is waiting for you to allow Apex Control in System Settings › General › Login Items."
        case .notFound:
            isEnabled = false
            explanation = "Launch at login needs Apex Control to be a signed app in /Applications. "
                + "Move it there and reopen it."
        case .notRegistered:
            isEnabled = false
            explanation = nil
        @unknown default:
            isEnabled = false
            explanation = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            explanation = nil
        } catch {
            explanation = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
