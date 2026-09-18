import ActivityKit
import Foundation

/// The contract between the app and the Live Activity.
///
/// Deliberately carries **rendered strings** rather than a model. The widget runs in a
/// separate process with its own memory budget, and giving it the finished text means it
/// links nothing, decides nothing, and cannot disagree with the app about what is
/// happening. All of the wording lives in `LiveActivityContent`, which is tested.
///
/// `endsAt` is the exception, and it earns it: handing the widget a date lets
/// `Text(timerInterval:)` count down on its own. A Live Activity has a budget for updates
/// and a drive lasts an hour; a countdown that costs nothing to keep accurate is worth
/// one field.
struct MirageDriveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        /// Short enough for the Dynamic Island pill.
        var compactLabel: String
        var progress: Double
        var showsProgress: Bool
        /// When the journey is due to finish, for a self-updating countdown.
        var endsAt: Date?
        /// Something the person should look at: the session cap was reached, or the
        /// device stopped answering. Neither means anything was restored.
        var needsAttention: Bool
    }

    /// Fixed for the life of the activity. The trip's name, or "Mirage" when it has none.
    var tripName: String
}
