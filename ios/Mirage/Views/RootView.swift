import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var showingProblem: Binding<Bool> {
        Binding(get: { model.problem != nil },
                set: { if !$0 { model.problem = nil } })
    }

    var body: some View {
        Group {
            if model.needsSetup {
                SetupView()
            } else {
                MapScreen()
            }
        }
        .animation(.default, value: model.needsSetup)
        .alert(model.problem?.title ?? "", isPresented: showingProblem, presenting: model.problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text([problem.detail, problem.remedy].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}

/// The banner that cannot be dismissed.
///
/// It is showing because Mirage's durable record says this iPhone is reporting a location
/// that is not where it is. The only thing that clears it is a restore that the device
/// confirmed. Offering a "dismiss" here would recreate exactly the failure the record
/// exists to prevent: someone believing they are back on real GPS when they are not.
struct StrandedBanner: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.restorePending
                     ? "Waiting to restore your real location"
                     : "This iPhone is reporting a simulated location")
                    .font(.subheadline.weight(.semibold))
                Text(model.strandedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                restoring = true
                Task { await model.restore(); restoring = false }
            } label: {
                if restoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Restore")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(restoring)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
