import SwiftUI
import AppKit
import ApexKit

@main
struct ApexControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some Scene {
        Window("Apex Control", id: "main") {
            ContentView()
                .withAppEnvironment()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // ⌘, is where every Mac user looks for settings, and this app keeps
            // them in the window rather than a second one.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    env.navigator.pane = .settings
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Undo is where every Mac user reaches after a mistake, and a
            // mistake here is written into the keyboard's own memory.
            CommandGroup(replacing: .undoRedo) {
                Button(env.controller.undoBindingLabel.map { "Undo \($0)" } ?? "Undo") {
                    env.controller.undoBindingChange()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!env.controller.canUndoBindings)

                Button(env.controller.redoBindingLabel.map { "Redo \($0)" } ?? "Redo") {
                    env.controller.redoBindingChange()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!env.controller.canRedoBindings)
            }

            CommandMenu("Keyboard") {
                Button("Read Bindings from Keyboard") {
                    env.controller.readBindingsFromDevice(seedEditor: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!env.controller.isConnected)

                Button("Reset All Key Bindings") { env.controller.resetAllBindings() }

                Divider()

                Button("Turn Lighting Off") { env.controller.setLightingOff(true) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Hand Lighting Back to Keyboard") { env.controller.handBackToKeyboard() }
            }

            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(Pane.allCases.enumerated()), id: \.element) { index, pane in
                    Button(pane.title) { env.navigator.pane = pane }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .withAppEnvironment()
        } label: {
            Image(systemName: "keyboard.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns process-level behaviour: activation policy, background operation,
/// sleep/wake re-apply, and single-instance enforcement (PRD-15).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private var observers: [NSObjectProtocol] = []

    private var env: AppEnvironment { AppEnvironment.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicate() else { return }

        applyActivationPolicy(showDock: env.prefs.showDockIcon)
        observeWorkspace()
        observePrefs()

        // Start the keyboard connection here rather than from a view, so the
        // app works with no window on screen. The screenshot harness is the one
        // launch that must not: it exists to photograph the interface, and a
        // second process taking over the LEDs of a keyboard the real app is
        // already driving is not a screenshot, it is a fight.
        if !SnapshotHarness.isEnabled, !KeyCaptureSelfTest.isEnabled, !InputDiagnostic.isEnabled {
            env.bootstrap()
        }

        SnapshotHarness.runIfEnabled(navigator: env.navigator)
        KeyCaptureSelfTest.runIfEnabled()
        InputDiagnostic.runIfEnabled()

        if env.prefs.showDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Menu-bar-only mode: the SwiftUI `Window` scene always creates its
            // window at launch, so close it and let the menu bar be the way in.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.windows.first { $0.canBecomeMain }?.close()
                }
            }
        }
    }

    // MARK: - Activation policy / background

    private func applyActivationPolicy(showDock: Bool) {
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    private func observePrefs() {
        // `showDockIcon` is the only preference with an immediate process-level
        // effect; the rest are read at the moment they matter.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyActivationPolicy(showDock: self.env.prefs.showDockIcon)
            }
        })
    }

    /// Coming to the front is when someone has just come back from System
    /// Settings, so it is where a refused key listener gets another go. It lives
    /// here rather than only on the Lighting pane because the app can be running
    /// with no window at all, and reactive is exactly the effect someone leaves
    /// running in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !SnapshotHarness.isEnabled, !KeyCaptureSelfTest.isEnabled else { return }
        env.controller.refreshReactiveInput()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Effects are rendered by this process, so quitting on window close
        // would darken the keyboard. Stay resident unless the user opted out.
        !env.prefs.runInBackground
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.activate(ignoringOtherApps: true) }
        return true
    }

    // MARK: - Sleep / wake

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.env.prefs.pauseWhileAsleep else { return }
                self.env.controller.pauseRendering()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Always undo the sleep pause, whatever the re-apply setting
                // says. Otherwise turning "re-apply after wake" off leaves the
                // keyboard dark for the rest of the session.
                self.env.controller.resumeRendering()

                guard self.env.prefs.reapplyOnWake else { return }
                // The USB device can re-enumerate slightly after the wake
                // notification, so re-apply once now and once shortly after.
                self.env.controller.reapply()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    MainActor.assumeIsolated { self.env.controller.reapply() }
                }
            }
        })
    }

    // MARK: - Single instance

    /// A login launch plus a manual launch would otherwise run two engines both
    /// streaming frames to the same keyboard.
    private func terminateIfDuplicate() -> Bool {
        // The development harnesses drive this process and then quit it. They
        // touch no hardware, so letting one run alongside the real app is safe
        // — and refusing to would make them unusable on the machine where the
        // app is actually in use.
        guard !SnapshotHarness.isEnabled, !KeyCaptureSelfTest.isEnabled,
              !InputDiagnostic.isEnabled else { return false }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.controller.shutdown()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
}
