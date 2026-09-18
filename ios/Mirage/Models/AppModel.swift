import Foundation
import MapKit
import MirageKit
import Observation
// For MapCameraPosition. MapKit's SwiftUI types are declared in MapKit but only visible
// once SwiftUI is in scope, and the camera genuinely belongs here: Mirage recentres the
// map on the simulated position, which is model behaviour rather than view state.
import SwiftUI

/// What the app is doing, and everything the screens read.
///
/// The Mac version of this file talks to a Python engine over a socket. Here there is no
/// engine and no socket: `DriveSession` runs in-process, the trajectory maths is the same
/// Swift that the Mac's tests cover, and the only thing below it is the Rust bridge.
///
/// The safety model is unchanged and deliberately awkward. `deviceDirty` is Mirage's
/// durable belief that the phone is reporting a simulated location; it is written to disk
/// the moment a fix is accepted, it survives the app being killed, and **it cannot be
/// dismissed** — only a confirmed restore clears it. Forgetting was the old failure.
@MainActor
@Observable
final class AppModel {

    // MARK: - Collaborators

    let setup: SetupStore
    let preferences: Preferences
    let completer = AddressCompleter()

    private let tripStore: TripStore
    private let marker: SimulationMarker
    private let liveActivity = LiveActivityController()
    private let keepAlive = BackgroundKeepAlive()

    private var session: DriveSession?
    private var ticker: Task<Void, Never>?

    // MARK: - Session state

    private(set) var state = SessionState()
    private(set) var connecting = false
    /// Set while a request is in flight, so a button can say what it is doing rather than
    /// looking inert for the twenty seconds a first tunnel takes.
    private(set) var busy: String?

    var mode: SessionMode { state.mode }
    var isSimulating: Bool { state.mode != .idle }
    var units: UnitSystem { preferences.units }

    /// Mirage believes the phone is reporting a simulated location. Not dismissible.
    var deviceDirty: Bool { state.deviceDirty }
    var restorePending: Bool { state.restorePending }

    var currentCoordinate: CLLocationCoordinate2D? {
        guard let lat = state.lat, let lon = state.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Errors

    /// One place for anything that went wrong, with the remedy attached. Never a bare
    /// error string: every failure here has something the person can actually do.
    struct Problem: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String
        var remedy: String?
    }

    var problem: Problem?

    // MARK: - Planning

    /// Mutated through the methods below rather than directly: every change has to
    /// invalidate the plan and be written to disk, and `@Observable` leaves no room for a
    /// `didSet` to do it.
    private(set) var waypoints: [Waypoint] = []

    private func waypointsChanged() {
        planned = nil
        lastRoadLimits = nil
        roadLimitCoverage = nil
        tripStore.saveWorking(waypoints.map(\.saved))
    }

    func setStopMinutes(_ minutes: Int, at index: Int) {
        guard waypoints.indices.contains(index) else { return }
        waypoints[index].stopMinutes = minutes
        waypointsChanged()
    }
    private(set) var planned: PlannedRoute?
    private(set) var roadLimitCoverage: Double?
    private(set) var isPlanning = false

    private(set) var savedTrips: [SavedTrip] = []
    private(set) var tripName: String = "Mirage"

    var canDrive: Bool { waypoints.count >= 2 && !isSimulating }
    var canPin: Bool { !waypoints.isEmpty && !isSimulating }

    var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25))))

    // MARK: - Init

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        self.setup = SetupStore()
        self.preferences = Preferences()
        self.tripStore = TripStore(url: root.appendingPathComponent("trips.json"))
        self.marker = SimulationMarker(url: root.appendingPathComponent("marker.json"))

        self.savedTrips = tripStore.trips
        self.waypoints = tripStore.working.waypoints.compactMap(Waypoint.init(saved:))

        // Whatever a previous run left behind is true before this one does anything.
        state.deviceDirty = marker.isActive
        state.restorePending = marker.isRestorePending
    }

    var needsSetup: Bool { setup.status == .missing || !preferences.acknowledged }

    /// What a previous run left set, in words.
    var strandedDescription: String { marker.describe() }

    // MARK: - Driving

    func startDrive() async {
        guard canDrive else { return }
        await plan()
        guard let planned, let poly = try? Polyline(planned.coordinates.map { LatLon($0.latitude, $0.longitude) })
        else { return }

        let drivePlan = buildPlan(
            poly,
            expectedTravelTime: planned.drivingTime,
            waypointStops: Dictionary(uniqueKeysWithValues: planned.stops.map { ($0.index, $0.seconds) }),
            roadLimits: lastRoadLimits)

        await run(named: tripNameForCurrentTrip()) { session in
            try await session.drive(drivePlan)
        }
    }

    func startPin() async {
        guard let first = waypoints.first else { return }
        await run(named: first.name) { session in
            try await session.pin(lat: first.coordinate.latitude, lon: first.coordinate.longitude)
        }
    }

    /// Open the connection, start whatever was asked for, and begin ticking.
    private func run(named name: String, _ begin: (DriveSession) async throws -> Void) async {
        connecting = true
        busy = "Connecting to your iPhone…"
        defer { connecting = false; busy = nil }

        let session = makeSession()
        do {
            try await begin(session)
        } catch {
            self.session = nil
            problem = Self.connectionProblem(error, addressInUse: preferences.vpnAddress)
            return
        }

        self.session = session
        self.tripName = name
        state = session.state

        keepAlive.begin()
        liveActivity.start(tripName: name, content: content())
        startTicking()
    }

    private func makeSession() -> DriveSession {
        let transport = DeviceTransport.loopback(
            address: preferences.vpnAddress,
            pairingFile: setup.pairingFileURL,
            developerImage: setup.developerImageIfPresent)

        return DriveSession(
            injector: IdeviceInjector(transport: transport),
            marker: marker,
            maxDuration: preferences.sessionCap,
            tickInterval: 1.0)
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                let next = await session.tick()
                self.state = next
                self.liveActivity.update(self.content())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func content() -> LiveActivityContent {
        LiveActivityContent(state: state,
                            units: units,
                            destination: waypoints.last?.name,
                            nextStop: nil)
    }

    // MARK: - Restoring

    /// Put the phone back on real GPS.
    ///
    /// Always available, in every state, including the ones where Mirage believes nothing
    /// is running — that belief is exactly what can be wrong, and a restore against a
    /// clean device is a no-op.
    func restore() async {
        busy = "Restoring your real location…"
        defer { busy = nil }

        let session = self.session ?? makeSession()
        do {
            try await session.restore()
            ticker?.cancel()
            ticker = nil
            self.session = nil
            state = session.state
            keepAlive.end()
            liveActivity.end(restored: true)
            try? await session.close()
        } catch let unreachable as DeviceUnreachable {
            state = session.state
            problem = Problem(
                title: "Your iPhone is still reporting a simulated location",
                detail: unreachable.underlyingDescription,
                remedy: unreachable.remedy)
            liveActivity.end(restored: false)
        } catch {
            state = session.state
            problem = Self.connectionProblem(error, addressInUse: preferences.vpnAddress)
            liveActivity.end(restored: false)
        }
    }

    // MARK: - Planning

    func plan() async {
        guard waypoints.count >= 2 else { planned = nil; return }
        isPlanning = true
        defer { isPlanning = false }

        do {
            let route = try await RouteService.route(through: waypoints)
            planned = route
            await loadRoadLimits(for: route)
        } catch {
            planned = nil
            problem = Problem(title: "Could not plan that route",
                              detail: error.localizedDescription,
                              remedy: "Try moving a pin, or removing a stop.")
        }
    }

    private var lastRoadLimits: [Double]?

    /// Posted speed limits from OpenStreetMap, which is free and needs no key.
    ///
    /// Best effort by design: a failure here costs realism, not the drive. Without limits
    /// the trajectory falls back to the vehicle's own ceiling and the corner-speed model,
    /// which is what Mirage did before this existed.
    private func loadRoadLimits(for route: PlannedRoute) async {
        lastRoadLimits = nil
        roadLimitCoverage = nil
        guard let poly = try? Polyline(route.coordinates.map { LatLon($0.latitude, $0.longitude) })
        else { return }
        guard let limits = await OverpassClient.speedLimits(for: poly) else { return }
        lastRoadLimits = limits
        let known = limits.filter { $0 > 0 }.count
        roadLimitCoverage = limits.isEmpty ? nil : Double(known) / Double(limits.count)
    }

    // MARK: - Waypoints

    func add(_ item: MKMapItem) {
        let name = item.name ?? "Dropped pin"
        waypoints.append(Waypoint(name: name, coordinate: item.placemark.coordinate))
        waypointsChanged()
    }

    func addPin(at coordinate: CLLocationCoordinate2D) async {
        let name = await RouteService.describe(coordinate)
        waypoints.append(Waypoint(name: name, coordinate: coordinate))
        waypointsChanged()
    }

    func remove(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        waypointsChanged()
    }

    func move(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
        waypointsChanged()
    }

    func clearTrip() {
        waypoints = []
        planned = nil
        lastRoadLimits = nil
        roadLimitCoverage = nil
        tripStore.clearWorking()
    }

    private func tripNameForCurrentTrip() -> String {
        waypoints.last?.name ?? "Mirage"
    }

    // MARK: - Saved trips

    func saveCurrentTrip(named name: String? = nil) {
        let saved = waypoints.map(\.saved)
        guard !saved.isEmpty else { return }
        let title = name ?? SavedTrip.suggestedName(for: saved)
        _ = tripStore.save(SavedTrip(name: title, waypoints: saved))
        savedTrips = tripStore.trips
    }

    func load(_ trip: SavedTrip) {
        waypoints = trip.waypoints.compactMap(Waypoint.init(saved:))
        waypointsChanged()
    }

    func delete(_ trip: SavedTrip) {
        tripStore.delete(trip.id)
        savedTrips = tripStore.trips
    }

    // MARK: - Teardown

    /// Called when the app is being put away. Deliberately does **not** restore: a drive
    /// is meant to keep running with the phone in a pocket, and silently undoing it here
    /// would be the opposite of what the person asked for.
    func willResignActive() {
        liveActivity.update(content())
    }

    func requestLocationPermission() {
        keepAlive.requestAuthorization()
    }

    var locationPermissionGranted: Bool { keepAlive.isAuthorized }

    // MARK: - Errors

    private static func connectionProblem(_ error: Error, addressInUse: String) -> Problem {
        let detail = String(describing: error)

        if detail.contains("pairing") || detail.contains("Pairing") || detail.contains("session") {
            return Problem(
                title: "The pairing file was not accepted",
                detail: detail,
                remedy: "Pairing files expire. Run ./scripts/prepare-phone.sh on the Mac again and re-import the folder in Setup.")
        }
        if detail.contains("Developer Mode") {
            return Problem(
                title: "Developer Mode is off",
                detail: detail,
                remedy: "Settings > Privacy & Security > Developer Mode. Turning it on restarts the iPhone.")
        }
        if detail.contains("developer disk image") || detail.contains("developer-tools") {
            return Problem(
                title: "No developer disk image is mounted",
                detail: detail,
                remedy: "Import the folder from ./scripts/prepare-phone.sh in Setup, and Mirage will mount it itself after every restart.")
        }
        // The commonest failure by far, and the one whose message says least: nothing
        // answered at the address. Three causes, in the order they actually happen.
        if detail.contains("socket io") || detail.contains("SocketIo")
            || detail.contains("timed out") || detail.contains("tunnel")
            || detail.contains("refused") || detail.contains("image mounter") {
            return Problem(
                title: "Nothing answered at \(addressInUse)",
                detail: detail,
                remedy: """
                    Check these three, in order:

                    1. The loopback VPN is connected — look for the VPN badge in the                     status bar, not just that the app is open.

                    2. The address in Mirage's Settings matches the one the VPN shows.                     Mirage is using \(addressInUse).

                    3. Settings > Mirage > Local Network is on. Without it iOS refuses                     the connection before it leaves the app, and the failure looks                     identical to the VPN being off.
                    """)
        }
        return Problem(title: "Could not start", detail: detail, remedy: nil)
    }
}

extension Waypoint {
    /// Rebuild from storage. Returns nil for a record that cannot be a place, so one bad
    /// row cannot take a whole saved trip down with it.
    init?(saved: SavedWaypoint) {
        guard saved.isValid else { return nil }
        self.init(name: saved.name,
                  coordinate: CLLocationCoordinate2D(latitude: saved.latitude,
                                                     longitude: saved.longitude),
                  stopMinutes: saved.stopMinutes)
    }
}
