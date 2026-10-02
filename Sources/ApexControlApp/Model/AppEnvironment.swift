import Foundation
import SwiftUI
import ApexKit

/// The app's long-lived objects, owned outside the SwiftUI scene graph.
///
/// This matters for background operation (PRD-15): with "run in background" on,
/// Apex Control can be running with no window at all — at login, or after the
/// user closes it. If the device connection were owned by a `@StateObject` on a
/// view, none of it would start until a window appeared, and a login launch
/// would leave the keyboard dark.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let controller = DeviceController()
    let store = ProfileStore()
    let prefs = AppPrefs()
    let loginItem = LoginItemManager()
    let navigator = Navigator()

    private var booted = false

    private init() {}

    /// Start the device connection and restore saved state. Runs once.
    func bootstrap() {
        guard !booted else { return }
        booted = true

        store.load()
        controller.start()

        if prefs.applyLastProfileOnLaunch, let last = store.profile(id: store.appliedProfileID) {
            controller.apply(last)
        }
    }
}

extension View {
    /// Inject the shared models. Used by both the main window and the menu bar
    /// so they render from the same state.
    func withAppEnvironment(_ env: AppEnvironment = .shared) -> some View {
        self
            .environmentObject(env.controller)
            .environmentObject(env.store)
            .environmentObject(env.prefs)
            .environmentObject(env.loginItem)
            .environmentObject(env.navigator)
    }
}
