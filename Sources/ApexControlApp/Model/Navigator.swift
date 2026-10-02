import SwiftUI

/// Which pane the main window is showing.
///
/// Selection lives outside the view tree so the menu bar, the ⌘, shortcut, and
/// the snapshot harness can all drive navigation without reaching into
/// `ContentView`'s private state.
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case lighting
    case bindings
    case oled
    case actuation
    case rapidTrigger
    case rapidTap
    case profiles
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lighting: return "Lighting"
        case .bindings: return "Key Bindings"
        case .oled: return "OLED Screen"
        case .actuation: return "Actuation"
        case .rapidTrigger: return "Rapid Trigger"
        case .rapidTap: return "Rapid Tap"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .lighting: return "light.max"
        case .bindings: return "keyboard"
        case .oled: return "rectangle.inset.filled"
        case .actuation: return "ruler"
        case .rapidTrigger: return "bolt"
        case .rapidTap: return "arrow.left.arrow.right"
        case .profiles: return "square.stack.3d.up"
        case .settings: return "gearshape"
        }
    }

    /// One line under the pane title. Says what the pane is for, in the user's
    /// terms — not what command it sends.
    var subtitle: String {
        switch self {
        case .lighting: return "Colour and effects, rendered on your Mac and streamed to every key."
        case .bindings: return "Change what each key does. Bindings are stored in the keyboard."
        case .oled: return "The 128 × 40 screen at the top right of the keyboard."
        case .actuation: return "How far a key travels before it registers."
        case .rapidTrigger: return "Reset a key the moment you lift, instead of at a fixed point."
        case .rapidTap: return "Decide which key wins when two opposing keys are held."
        case .profiles: return "Save complete setups and switch between them."
        case .settings: return "How Apex Control behaves on your Mac."
        }
    }

    /// Where the settings on this pane actually live. This is the deepest fact
    /// about the hardware — some settings are held by the Mac and vanish when
    /// the app quits, others are burned into the keyboard and outlive it — so
    /// the UI states it rather than burying it in prose.
    var storage: StorageKind {
        switch self {
        case .lighting: return .host
        case .bindings: return .keyboard
        case .oled: return .host
        case .actuation: return .keyboard
        case .rapidTrigger: return .keyboard
        case .rapidTap: return .keyboard
        case .profiles: return .host
        case .settings: return .none
        }
    }

    static let groups: [(String, [Pane])] = [
        ("Customise", [.lighting, .bindings, .oled]),
        ("Performance", [.actuation, .rapidTrigger, .rapidTap]),
        ("Library", [.profiles, .settings]),
    ]
}

/// Where a pane's settings are kept once you set them.
enum StorageKind {
    /// Rendered by this app. Stops when Apex Control quits.
    case host
    /// Written into the keyboard. Works with the app closed, and should on any computer.
    case keyboard
    /// App preferences — neither.
    case none

    var label: String {
        switch self {
        case .host: return "Runs on this Mac"
        case .keyboard: return "Stored in the keyboard"
        case .none: return ""
        }
    }

    var detail: String {
        switch self {
        case .host: return "Apex Control renders this. It stops when the app quits."
        case .keyboard: return "Written into the keyboard and saved to its onboard profile, so it keeps working "
            + "with the app closed, and should after unplugging and on any other computer."
        case .none: return ""
        }
    }

    var icon: String {
        switch self {
        case .host: return "laptopcomputer"
        case .keyboard: return "keyboard"
        case .none: return ""
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    @Published var pane: Pane = .lighting
}
