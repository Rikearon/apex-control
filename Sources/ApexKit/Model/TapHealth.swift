import Foundation

/// Judges whether a keyboard event tap that macOS agreed to *create* is
/// actually being *fed* every key press.
///
/// Those are different facts. Since Catalina the window server will hand a
/// listen-only keyboard tap to a process whose Input Monitoring /
/// Accessibility grant it does not honour — never given, keyed to a stale
/// code signature after a rebuild, or granted after the process started — and
/// then silently withhold every `keyDown` that belongs to another app.
/// Modifiers (`flagsChanged`) and the process's own key presses still arrive,
/// so from the inside the tap looks alive while most of the keyboard is
/// inaudible. On a reactive lighting effect that presents as "shift and
/// control ripple, letters only while the app is frontmost" — which reads as
/// a lighting bug and is nothing of the sort.
///
/// Three signals, each covering the others' blind spots:
///
/// * **What macOS claims** (`expectedToHear`): the permission APIs. Wrong
///   exactly when it matters most — a stale grant can pass every record
///   check while the window server ignores it.
/// * **What we provably miss**: the HID system's own last-key-down clock
///   moved and the tap heard nothing. One miss is never conviction — an
///   evaluation can race an event still in flight — so it takes
///   `strikesToConvict` *distinct* missed presses with nothing heard between.
/// * **What we provably hear**: a `keyDown` targeted at *another* process is
///   the one event a filtered tap can never receive, so it is proof of
///   delivery. The app's own key presses prove nothing; they arrive
///   regardless.
///
/// Deliberately pure — values in, verdict out — because the real condition
/// can only be reproduced by mangling TCC grants mid-session, and rules that
/// cannot be tested are the kind that rot.
public struct TapHealth: Sendable, Equatable {

    public enum Verdict: Sendable, Equatable {
        /// Nothing contradicts full delivery.
        case hearingEverything
        /// The tap is being starved of other apps' key presses.
        case filtered
    }

    /// How long after a system key-down the tap is still given the benefit of
    /// the doubt for having heard it — covers delivery latency and a watchdog
    /// that woke up mid-keystroke.
    private let slack: TimeInterval
    /// Distinct missed presses, with nothing heard in between, before the tap
    /// is declared filtered.
    private let strikesToConvict: Int

    /// System-clock time of the last press that earned a strike, so one press
    /// is never counted twice however many evaluations see it. Starts at the
    /// tap's birth: presses from before it existed prove nothing.
    private var lastStrikeAt: TimeInterval
    private var lastHeardAt: TimeInterval?
    private var strikes = 0
    private var convicted = false
    private var proven = false

    public init(startedAt: TimeInterval,
                slack: TimeInterval = 0.5,
                strikesToConvict: Int = 2) {
        self.lastStrikeAt = startedAt
        self.slack = slack
        self.strikesToConvict = max(1, strikesToConvict)
    }

    /// Record a `keyDown` the tap delivered. `foreign` means the event was
    /// targeted at a different process — pass `false` when the target is this
    /// process *or unknown*, so an unpopulated target field can never fake
    /// proof of delivery.
    public mutating func heardKeyDown(foreign: Bool, at now: TimeInterval) {
        lastHeardAt = now
        strikes = 0
        if foreign {
            proven = true
            convicted = false
        }
    }

    /// Periodic judgement.
    ///
    /// - Parameters:
    ///   - expectedToHear: what the permission APIs claim.
    ///   - secureInput: whether a password field has secure event input on.
    ///     No tap anywhere receives key presses then, so silence proves
    ///     nothing and evidence-gathering pauses.
    ///   - systemSecondsSinceKeyDown: the window server's seconds since *any*
    ///     process's key-down (`CGEventSource.secondsSinceLastEventType`),
    ///     readable without any permission — which is what makes deafness
    ///     detectable at all.
    ///   - now: the current time on the same clock the other timestamps use.
    public mutating func evaluate(expectedToHear: Bool,
                                  secureInput: Bool,
                                  systemSecondsSinceKeyDown: TimeInterval,
                                  at now: TimeInterval) -> Verdict {
        if !secureInput {
            let systemPressAt = now - systemSecondsSinceKeyDown
            let isNewPress = systemPressAt > lastStrikeAt
            let heardIt = lastHeardAt.map { $0 >= systemPressAt - slack } ?? false
            if isNewPress && !heardIt {
                lastStrikeAt = systemPressAt
                strikes += 1
                if strikes >= strikesToConvict {
                    convicted = true
                    // Deafness outranks old proof: delivery that stops is
                    // exactly what a mid-session revocation looks like.
                    proven = false
                }
            }
        }
        if convicted { return .filtered }
        if proven { return .hearingEverything }
        return expectedToHear ? .hearingEverything : .filtered
    }
}
