import MirageKit
import SwiftUI

struct SavedTripsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.savedTrips.isEmpty {
                    ContentUnavailableView(
                        "No saved trips",
                        systemImage: "bookmark",
                        description: Text("Plan a trip and save it, and it will be here next time."))
                }

                ForEach(model.savedTrips) { trip in
                    Button {
                        model.load(trip)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(subtitle(for: trip))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.delete(trip) }
                    }
                }
            }
            .navigationTitle("Saved trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func subtitle(for trip: SavedTrip) -> String {
        let places = trip.waypoints.count
        let kind = trip.isDrive ? "\(places) places" : "one place"
        return "\(kind) · \(trip.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
