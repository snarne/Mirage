import MapKit
import MirageKit
import SwiftUI

/// The whole app, once setup is done: a map, whatever is being simulated on it, and one
/// card at the bottom that changes with what is happening.
struct MapScreen: View {
    @Environment(AppModel.self) private var model

    @State private var showingTripBuilder = false
    @State private var showingSaved = false
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $model.cameraPosition) {
                    UserAnnotation()

                    if let route = model.planned {
                        MapPolyline(coordinates: route.coordinates)
                            .stroke(.blue.opacity(0.85), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }

                    ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        Marker(waypoint.name, systemImage: symbol(for: index),
                               coordinate: waypoint.coordinate)
                            .tint(index == 0 ? .green : (index == model.waypoints.count - 1 ? .red : .orange))
                    }

                    if let here = model.currentCoordinate {
                        Annotation("", coordinate: here) { SimulatedDot() }
                            .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                // MapKit's own controls are pinned to the top trailing corner, which is
                // exactly where Settings is — they sat underneath it, unreachable. Mirage
                // draws its own instead, down beside the card where nothing overlaps.
                .mapControlVisibility(.hidden)
                .onTapGesture { screenPoint in
                    guard !model.isSimulating,
                          let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                    Task { await model.addPin(at: coordinate) }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                header
                if model.deviceDirty && !model.isSimulating {
                    StrandedBanner()
                }
            }
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                locateButton
                bottomCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingTripBuilder) {
            TripBuilderView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSaved) { SavedTripsView() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task {
            if !model.locationPermissionGranted { model.requestLocationPermission() }
        }
    }

    private func symbol(for index: Int) -> String {
        if index == 0 { return "flag.fill" }
        if index == model.waypoints.count - 1 { return "mappin" }
        return "pause.circle.fill"
    }

    // MARK: - Chrome

    /// Recentre on where the phone actually is. Distinct from the simulated position,
    /// which has its own marker — being able to find yourself again matters most when
    /// something else is claiming to be you.
    private var locateButton: some View {
        Button {
            withAnimation {
                model.cameraPosition = .userLocation(fallback: .automatic)
            }
        } label: {
            Image(systemName: "location")
                .font(.body.weight(.semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { showingSaved = true } label: {
                Image(systemName: "bookmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())

            Spacer()

            Text(model.isSimulating ? "Simulating" : "Mirage")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var bottomCard: some View {
        if model.isSimulating {
            DrivingPanel()
        } else {
            IdleCard(showingTripBuilder: $showingTripBuilder)
        }
    }
}

/// Where Mirage says the phone is. Distinct from the blue dot, which is where it is.
private struct SimulatedDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.22))
                .frame(width: pulse ? 46 : 26, height: pulse ? 46 : 26)
            Circle()
                .fill(Color.orange)
                .frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
        }
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

private struct IdleCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showingTripBuilder: Bool
    @State private var working = false

    var body: some View {
        VStack(spacing: 12) {
            if model.waypoints.isEmpty {
                Text("Tap the map to drop a pin, or search for a place.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button { showingTripBuilder = true } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let route = model.planned {
                                Text("\(model.units.distance(route.distance)) · \(LiveActivityContent.shortDuration(route.totalTime))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button {
                    showingTripBuilder = true
                } label: {
                    Label("Plan a trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    working = true
                    Task {
                        if model.canDrive { await model.startDrive() } else { await model.startPin() }
                        working = false
                    }
                } label: {
                    Group {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(model.canDrive ? "Drive" : "Hold here",
                                  systemImage: model.canDrive ? "car.fill" : "mappin.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working || (!model.canDrive && !model.canPin))
            }

            if let busy = model.busy {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var summary: String {
        let names = model.waypoints.map(\.name)
        if names.count == 1 { return names[0] }
        return "\(names.first ?? "") → \(names.last ?? "")"
    }
}
