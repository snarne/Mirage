import ActivityKit
import Foundation
import MirageKit

/// Starts, updates and ends the Live Activity.
///
/// Two jobs. The obvious one is keeping the app scheduled while the phone is in a pocket.
/// The one that matters more is that a simulated location becomes visible on the Lock
/// Screen without opening Mirage — the state this app most needs to avoid is someone
/// believing they are back on real GPS when they are not.
///
/// Updates are throttled. ActivityKit budgets them, and a drive ticks once a second for an
/// hour; sending every tick would get the activity cut off long before the journey ends.
@MainActor
final class LiveActivityController {

    private var activity: Activity<MirageDriveAttributes>?
    private var lastPush: Date = .distantPast
    private var lastState: MirageDriveAttributes.ContentState?

    /// One second of drive detail is not worth a second of budget. Anything that changes
    /// the *meaning* — arrived, held, disconnected — bypasses this.
    private let minimumInterval: TimeInterval = 8

    var isRunning: Bool { activity != nil }

    static var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(tripName: String, content: LiveActivityContent) {
        guard Self.isAvailable, activity == nil else { return }
        let state = Self.render(content)
        do {
            activity = try Activity.request(
                attributes: MirageDriveAttributes(tripName: tripName),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
            lastPush = Date()
        } catch {
            // A refused activity is not a reason to refuse a drive. The session runs
            // either way; it just loses its Lock Screen face.
            activity = nil
        }
    }

    func update(_ content: LiveActivityContent) {
        guard let activity else { return }
        let state = Self.render(content)
        guard state != lastState else { return }

        let urgent = state.needsAttention != lastState?.needsAttention
            || state.title != lastState?.title
        guard urgent || Date().timeIntervalSince(lastPush) >= minimumInterval else { return }

        lastState = state
        lastPush = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Ends the activity. `restored` decides the last thing it says, and it is the only
    /// place Mirage is allowed to claim the device is back on real GPS.
    func end(restored: Bool) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil

        let final = MirageDriveAttributes.ContentState(
            title: restored ? "Real location restored" : "Session ended",
            subtitle: restored
                ? "Find My shows where you actually are."
                : "The iPhone may still be reporting a simulated location.",
            compactLabel: restored ? "Done" : "Check",
            progress: 1,
            showsProgress: false,
            endsAt: nil,
            needsAttention: !restored
        )
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: restored ? .after(.now + 4) : .default)
        }
    }

    // MARK: - Rendering

    /// All of the wording comes from `LiveActivityContent`, which is tested on both
    /// platforms. This only reshapes it.
    private static func render(_ content: LiveActivityContent) -> MirageDriveAttributes.ContentState {
        let endsAt = content.showsProgress && content.etaRemaining > 0
            ? Date().addingTimeInterval(content.etaRemaining)
            : nil
        return MirageDriveAttributes.ContentState(
            title: content.title,
            subtitle: content.subtitle,
            compactLabel: content.compactLabel,
            progress: content.progress,
            showsProgress: content.showsProgress,
            endsAt: endsAt,
            needsAttention: content.kind == .held || content.kind == .disconnected
        )
    }
}
