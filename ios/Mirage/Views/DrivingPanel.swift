import MirageKit
import SwiftUI

/// What a running session looks like from inside the app.
///
/// Restore is on this card in every state, including the two where something has gone
/// wrong, because those are exactly the states where someone needs it most.
struct DrivingPanel: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false

    private var state: SessionState { model.state }

    var body: some View {
        VStack(spacing: 14) {
            if !state.deviceConnected {
                Notice(icon: "wifi.exclamationmark",
                       tint: .orange,
                       title: "Not reaching the iPhone",
                       detail: "The journey is still running on the clock. Nothing has been restored. \(unreachable)")
            } else if state.limitReached {
                Notice(icon: "clock.badge.exclamationmark",
                       tint: .orange,
                       title: "Session length reached",
                       detail: "Mirage has stopped the journey where it is. It is still simulating — nothing has been restored.")
            }

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Readout(value: model.units.speed(state.speed), label: "speed")
                Readout(value: LiveActivityContent.shortDuration(state.etaRemaining), label: "remaining")
                Readout(value: model.units.distance(state.distance), label: "route")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if state.mode == .driving {
                ProgressView(value: min(1, max(0, state.progress)))
                    .tint(.blue)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.mode == .driving ? "Driving" : "Holding position")
                        .font(.subheadline.weight(.semibold))
                    Text(model.tripName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    restoring = true
                    Task { await model.restore(); restoring = false }
                } label: {
                    Group {
                        if restoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restore")
                        }
                    }
                    .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(restoring)
            }

            if let busy = model.busy {
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var unreachable: String {
        state.unreachableFor > 1
            ? "Out of touch for \(LiveActivityContent.shortDuration(state.unreachableFor))."
            : ""
    }
}

private struct Readout: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

struct Notice: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
