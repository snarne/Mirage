import MapKit
import MirageKit
import SwiftUI

/// Building the trip: where it starts, where it ends, and anything to stop at on the way.
struct TripBuilderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var saving = false
    @State private var tripName = ""

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("Results") { results }
                }

                Section {
                    if model.waypoints.isEmpty {
                        Text("Search above, or tap the map to drop a pin.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        WaypointRow(index: index, waypoint: waypoint, count: model.waypoints.count)
                    }
                    .onDelete { model.remove(at: $0) }
                    .onMove { model.move(from: $0, to: $1) }
                } header: {
                    Text("Trip")
                } footer: {
                    if model.waypoints.count > 2 {
                        Text("Stops in the middle are added on top of the driving estimate — Apple's number is how long the driving takes, and it cannot know you meant to sit somewhere for ten minutes.")
                    }
                }

                if let route = model.planned {
                    Section("Estimate") {
                        LabeledContent("Distance", value: model.units.distance(route.distance))
                        LabeledContent("Driving", value: LiveActivityContent.shortDuration(route.drivingTime))
                        if route.stopTime > 0 {
                            LabeledContent("Stops", value: LiveActivityContent.shortDuration(route.stopTime))
                        }
                        if let coverage = model.roadLimitCoverage {
                            LabeledContent("Posted limits") {
                                Text("\(Int(coverage * 100))% of the route")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a place")
            .onChange(of: query) { _, new in
                model.completer.update(query: new, near: visibleRegion)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { model.clearTrip() }
                        .disabled(model.waypoints.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .navigationTitle("Plan a trip")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: model.waypoints.map(\.id)) {
                await model.plan()
            }
            .alert("Save this trip", isPresented: $saving) {
                TextField("Name", text: $tripName)
                Button("Save") { model.saveCurrentTrip(named: tripName.isEmpty ? nil : tripName) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var results: some View {
        if model.completer.suggestions.isEmpty && model.completer.isSearching {
            HStack { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
        }
        ForEach(model.completer.suggestions) { suggestion in
            Button {
                Task {
                    if let item = try? await model.completer.resolve(suggestion) {
                        model.add(item)
                        query = ""
                        model.completer.clear()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title).foregroundStyle(.primary)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Built by hand rather than put in a `.bottomBar` toolbar item.
    ///
    /// A toolbar lays its contents out as a single run and lets the prominent style span
    /// the whole width, which turned Save and Drive into one capsule with two icons in it
    /// and no labels — two different actions that looked like one button.
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                tripName = ""
                saving = true
            } label: {
                Label("Save", systemImage: "bookmark")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.waypoints.isEmpty)

            Button {
                dismiss()
                Task { await model.startDrive() }
            } label: {
                Group {
                    if model.isPlanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Drive", systemImage: "car.fill")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canDrive || model.isPlanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Bias search toward what the map is showing, so "high street" means a nearby one.
    private var visibleRegion: MKCoordinateRegion {
        model.cameraPosition.region ?? MKCoordinateRegion(
            center: model.waypoints.first?.coordinate
                ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25))
    }
}

private struct WaypointRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let waypoint: Waypoint
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(waypoint.name).lineLimit(1)
                Text(role).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isIntermediate {
                Picker("", selection: stopBinding) {
                    ForEach([0, 2, 5, 10, 20, 30, 60], id: \.self) { minutes in
                        Text(minutes == 0 ? "no stop" : "\(minutes) min").tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var isIntermediate: Bool { index > 0 && index < count - 1 }

    private var icon: String {
        if index == 0 { return "flag.fill" }
        if index == count - 1 { return "mappin.circle.fill" }
        return "pause.circle.fill"
    }

    private var tint: Color {
        if index == 0 { return .green }
        if index == count - 1 { return .red }
        return .orange
    }

    private var role: String {
        if index == 0 { return "start" }
        if index == count - 1 { return "destination" }
        return "stop"
    }

    private var stopBinding: Binding<Int> {
        Binding(
            get: { model.waypoints[safe: index]?.stopMinutes ?? 0 },
            set: { model.setStopMinutes($0, at: index) })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
