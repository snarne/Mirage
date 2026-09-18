import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        if model.needsSetup {
            // Everything is gated behind setup: the engine refuses location changes
            // without consent anyway, so showing the map first would only mislead.
            OnboardingView()
        } else {
            mainInterface
        }
    }

    private var mainInterface: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
        } detail: {
            ZStack(alignment: .top) {
                MapCanvas()
                    .ignoresSafeArea()

                if model.mode != .idle {
                    StatusBanner()
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let error = model.connectionError {
                    ErrorCard(message: error, remedy: model.remedy)
                        .padding()
                }
            }
            .animation(.smooth(duration: 0.3), value: model.mode)
        }
    }
}

// MARK: - Map

struct MapCanvas: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let route = model.plannedRoute {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }

                ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    Annotation(waypoint.name, coordinate: waypoint.coordinate) {
                        WaypointPin(position: index, total: model.waypoints.count,
                                    stopMinutes: waypoint.stopMinutes)
                            .onTapGesture { model.removeWaypoint(waypoint.id) }
                            .help("Click to remove")
                    }
                }

                if let here = model.currentCoordinate, CLLocationCoordinate2DIsValid(here) {
                    Annotation("", coordinate: here) {
                        // Values are passed in, not read from the environment — see PuckView.
                        PuckView(isDriving: model.mode == .driving,
                                 heading: model.headingDegrees)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, showsTraffic: true))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }
            // Drop a pin wherever the user clicks. Panning is a drag, so it does not
            // collide with this.
            .onTapGesture { screenPoint in
                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                model.addWaypoint(at: coordinate)
            }
            .onChange(of: model.waypoints.count) {
                guard !model.waypoints.isEmpty else { return }
                camera = .automatic
            }
            // Keep the search bias on what the user is actually looking at, so
            // "high street" means the one on screen rather than one in another country.
            .onMapCameraChange(frequency: .onEnd) { context in
                model.cameraRegion = context.region
            }
        }
    }
}

/// A numbered trip pin. The last one is the destination; anything between the first and
/// last is a stop, and shows how long the drive waits there.
struct WaypointPin: View {
    let position: Int
    let total: Int
    let stopMinutes: Int

    private var isEnd: Bool { position == total - 1 && total > 1 }
    private var isStop: Bool { position > 0 && position < total - 1 }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(isEnd ? Color.red : Color.accentColor)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                if isEnd {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(position + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            if isStop && stopMinutes > 0 {
                Text("\(stopMinutes)m")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            }
        }
    }
}

/// The simulated position indicator. Mirrors Apple's own blue dot closely enough to read
/// at a glance, but deliberately in the accent colour rather than system blue — inside
/// Mirage you should always be able to tell a simulated position from a real one.
///
/// Everything it needs is passed in. `Map`'s content builder does **not** propagate the
/// SwiftUI environment into `Annotation` content, so an `@Environment(AppModel.self)`
/// here traps at runtime the moment the annotation first appears — which is exactly when
/// a location starts being simulated. Views placed inside map content must take plain
/// values, as `WaypointPin` does.
struct PuckView: View {
    let isDriving: Bool
    let heading: Double

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.18))
                .frame(width: pulse ? 46 : 26, height: pulse ? 46 : 26)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(.tint)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 3, y: 1)
            if isDriving {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(heading))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - Status

struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.mode == .driving ? "car.fill" : "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.mode == .driving ? "Driving" : "Location pinned")
                    .font(.system(size: 13, weight: .semibold))
                if model.mode == .driving {
                    Text("\(Int(model.speedKPH)) km/h · \(formatted(model.etaRemaining)) remaining")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if model.mode == .driving {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }

            Button {
                Task { await model.restore() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }

    private func formatted(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m > 0 ? "\(m) min" : "\(s)s"
    }
}

struct ErrorCard: View {
    let message: String
    let remedy: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.system(size: 12, weight: .medium))
                if let remedy {
                    Text(remedy)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .shadow(radius: 10, y: 3)
    }
}
