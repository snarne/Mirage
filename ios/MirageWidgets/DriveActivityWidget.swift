import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island face of a running session.
///
/// This exists for two reasons, and the second is the important one. It keeps a drive
/// alive while the phone is in a pocket — but it also makes a simulated location
/// *visible* without opening Mirage. Someone who has forgotten they left a location set
/// sees it on the Lock Screen, which is the failure this whole app is built to avoid.
///
/// Every line of text arrives pre-rendered from the app. Nothing here interprets state.
struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MirageDriveAttributes.self) { context in
            LockScreenView(state: context.state, tripName: context.attributes.tripName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.needsAttention ? "exclamationmark.triangle.fill" : "location.fill")
                        .foregroundStyle(context.state.needsAttention ? .orange : .blue)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = context.state.endsAt, context.state.showsProgress {
                        Text(timerInterval: Date.now...endsAt, countsDown: true)
                            .monospacedDigit()
                            .font(.title3)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 74)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if context.state.showsProgress {
                            ProgressView(value: context.state.progress.clampedToUnit)
                                .tint(.blue)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.needsAttention ? "exclamationmark.triangle.fill" : "location.fill")
                    .foregroundStyle(context.state.needsAttention ? .orange : .blue)
            } compactTrailing: {
                Text(context.state.compactLabel)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(context.state.needsAttention ? .orange : .blue)
            }
            .keylineTint(context.state.needsAttention ? .orange : .blue)
        }
    }
}

private struct LockScreenView: View {
    let state: MirageDriveAttributes.ContentState
    let tripName: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.needsAttention ? "exclamationmark.triangle.fill" : "location.fill")
                .font(.title2)
                .foregroundStyle(state.needsAttention ? .orange : .blue)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(state.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if state.showsProgress {
                    ProgressView(value: state.progress.clampedToUnit)
                        .tint(.blue)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if let endsAt = state.endsAt, state.showsProgress {
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .font(.title3.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 78)
            }
        }
        .padding(16)
    }
}

private extension Double {
    /// A progress bar given NaN renders as a full bar, which would quietly say "arrived".
    var clampedToUnit: Double { isFinite ? Swift.min(1, Swift.max(0, self)) : 0 }
}
