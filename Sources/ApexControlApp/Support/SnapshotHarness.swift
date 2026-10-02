import AppKit
import QuartzCore
import SwiftUI
import ApexKit

/// Development-only screenshot harness.
///
/// The app draws its own window into a bitmap and writes it out as PNG, which
/// needs no Screen Recording permission because nothing outside this process is
/// ever captured. Entirely inert unless `APEX_SNAPSHOT_DIR` is set:
///
/// ```
/// APEX_SNAPSHOT_DIR=/tmp/shots "build/Apex Control.app/Contents/MacOS/Apex Control"
/// ```
///
/// Optional `APEX_SNAPSHOT_PANES` limits which panes are captured (comma
/// separated raw values); the default is all of them. The app quits when done.
@MainActor
enum SnapshotHarness {

    static var isEnabled: Bool { directory != nil }

    private static var directory: URL? {
        ProcessInfo.processInfo.environment["APEX_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static var panes: [Pane] {
        guard let raw = ProcessInfo.processInfo.environment["APEX_SNAPSHOT_PANES"], !raw.isEmpty else {
            return Pane.allCases
        }
        return raw.split(separator: ",").compactMap { Pane(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Walk every requested pane, write a PNG per pane, then terminate.
    static func runIfEnabled(navigator: Navigator) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Task { @MainActor in
            // A process launched straight from a shell is not the active app,
            // and an inactive window may never get composited — which reads as
            // a blank capture. Force it front before the first frame.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)

            // Let the window finish its first layout pass before the first
            // frame is captured. (There is no device connection to wait for:
            // this mode never starts one.)
            try? await Task.sleep(for: .milliseconds(1800))

            for (index, pane) in panes.enumerated() {
                navigator.pane = pane
                // Two runloop turns plus a beat: SwiftUI needs to commit the
                // transition, and any TimelineView needs a tick to draw.
                try? await Task.sleep(for: .milliseconds(700))
                let name = String(format: "%02d-%@.png", index + 1, pane.rawValue)
                capture(to: directory.appendingPathComponent(name))
            }

            if ProcessInfo.processInfo.environment["APEX_SNAPSHOT_ACTIVE"] != nil {
                configureForActiveStates()
                try? await Task.sleep(for: .milliseconds(400))
                for (index, pane) in panes.enumerated() {
                    navigator.pane = pane
                    try? await Task.sleep(for: .milliseconds(700))
                    let name = String(format: "%02d-%@-active.png", index + 1, pane.rawValue)
                    capture(to: directory.appendingPathComponent(name))
                }
            }

            captureMenuBar(to: directory.appendingPathComponent("00-menubar.png"))

            NSApp.terminate(nil)
        }
    }

    /// The menu-bar panel is its own scene, so it needs its own capture.
    private static func captureMenuBar(to url: URL) {
        let renderer = ImageRenderer(
            content: MenuBarView()
                .withAppEnvironment()
                .environment(\.isSnapshotting, true)
        )
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
        FileHandle.standardError.write(Data("snapshot: \(url.lastPathComponent)\n".utf8))
    }

    /// Put the view models into the states that only appear once you have
    /// selected something, so a capture can show the panes doing their job
    /// rather than only their empty states.
    ///
    /// Nothing here reaches the hardware: the `apply…` calls that write to the
    /// keyboard are made by the views' `onChange` handlers, and these fields are
    /// set while a different pane is on screen. The exception is lighting, which
    /// streams continuously anyway and is entirely transient.
    private static func configureForActiveStates() {
        let env = AppEnvironment.shared
        let controller = env.controller

        controller.selectedKey = 0x04                    // A

        // A key with a real combination on it, so the bindings inspector shows
        // its editor rather than only the "this key is unchanged" state.
        controller.bindings.normal[0x04] = .keyboard(usages: [HIDUsage.leftGUI, 0x06])
        controller.bindings.normal[0x39] = .keyboard(usages: [HIDUsage.leftControl])
        controller.bindings.normal[0x35] = .disabled
        controller.bindings.metaToggleHID = 0xF0

        controller.actuation.usePerKey = true
        controller.actuation.perKey[0x04] = 4
        controller.actuation.perKey[0x16] = 6
        controller.actuation.perKey[0x07] = 4
        controller.actuation.perKey[0x1A] = 5
        controller.actuation.rapidTrigger = true
        controller.actuation.secondActuationEnabled = true
        controller.actuation.perKeySecondActuation[0x04] = 30
        for hid in [UInt8(0x1A), 0x04, 0x16, 0x07] {
            controller.actuation.perKeyRapidTrigger[hid] = true
        }

        controller.rapidTap.enabled = true

        var lighting = controller.lighting
        lighting.kind = .perKey
        for (index, hid) in ApexProTKLGen3.ledHIDOrder.enumerated() {
            lighting.perKeyColors[hid] = LEDColor.hsv(Double(index % 24) / 24, 0.9, 1)
        }
        controller.lighting = lighting
    }

    /// Render the app's own view tree to a PNG.
    ///
    /// `ImageRenderer` walks the SwiftUI view tree directly. The alternatives —
    /// `cacheDisplay` and `CALayer.render(in:)` — both come back blank, because
    /// SwiftUI's macOS backing store is not reachable through either.
    @discardableResult
    static func capture(to url: URL) -> Bool {
        // Width is fixed; height follows the content, so a long pane is
        // captured whole instead of cropped at an arbitrary window height.
        let renderer = ImageRenderer(
            content: SnapshotShell()
                .withAppEnvironment()
                .environment(\.isSnapshotting, true)
                .frame(width: captureSize.width)
        )
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: renderer produced nothing\n".utf8))
            return false
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }

        do {
            try data.write(to: url)
            FileHandle.standardError.write(Data("snapshot: \(url.lastPathComponent)\n".utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return false
        }
    }

    private static var captureSize: CGSize {
        let env = ProcessInfo.processInfo.environment
        let w = env["APEX_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1280
        let h = env["APEX_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 860
        return CGSize(width: w, height: h)
    }
}

/// The window's layout without the system split view.
///
/// `NavigationSplitView` does not survive `ImageRenderer`, so snapshots compose
/// the same two columns by hand. Everything inside them is the real thing —
/// same sidebar rows, same panes, same design system — so what you see here is
/// what the window draws, minus the title bar.
private struct SnapshotShell: View {
    var body: some View {
        HStack(spacing: 0) {
            SidebarColumn()
                .frame(width: 226)
            Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
            DetailColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.void)
        .preferredColorScheme(.dark)
    }
}
