import Foundation
import MapKit
import MirageKit
import Observation

/// What the owner has allowed. Defaults are the restrictive ones — a grant should be a
/// deliberate act, not something you get by clicking through.
struct GrantSelection: Equatable {
    var allowPin = false
    var allowDrive = false
    var maxSessionMinutes = 60

    var json: JSON {
        [
            "allow_pin": .bool(allowPin),
            "allow_drive": .bool(allowDrive),
            "max_session_minutes": .int(maxSessionMinutes),
        ]
    }
}

struct DeviceEligibility: Equatable {
    var ok = false
    var checked = false
    var reasons: [String] = []

    init() {}
    init(_ j: JSON) {
        ok = j["ok"]?.boolValue ?? false
        checked = j["checked"]?.boolValue ?? false
        reasons = j["blocking_reasons"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

@MainActor
@Observable
final class AppModel {
    enum Mode: String { case idle, pinned, driving }

    // Connection
    var connected = false
    var connectionError: String?
    var remedy: String?

    // Live state from the engine
    var mode: Mode = .idle
    var currentCoordinate: CLLocationCoordinate2D?
    var speedKPH: Double = 0
    var headingDegrees: Double = 0
    var progress: Double = 0
    var etaRemaining: TimeInterval = 0
    /// False while the phone is unreachable. The journey keeps running regardless.
    var deviceConnected = true
    var unreachableFor: TimeInterval = 0
    /// The consented session length elapsed. Mirage is holding, not restoring.
    var limitReached = false
    var limitAcknowledged = false

    /// Mirage's durable belief that the phone is reporting a simulated location, from
    /// the engine's marker file. Survives crashes and restarts, and is **not
    /// dismissible** — it clears only when a restore is confirmed. Dismissing it was
    /// how Mirage used to forget.
    var deviceDirty = false
    var restorePending = false
    /// A request is in flight, so the controls can say so instead of looking inert.
    var busy: String?

    // Planning
    var searchQuery = ""
    let completer = AddressCompleter()
    var waypoints: [Waypoint] = []
    var plannedRoute: PlannedRoute?
    var etaUnachievable = false
    var isPlanning = false
    var planError: String?

    var canDrive: Bool { driveBlockedReason == nil }
    /// Holding works with any trip — it pins the first place. Requiring exactly one
    /// waypoint meant that building a route locked you out of simply standing still.
    var canPin: Bool { pinBlockedReason == nil }

    var cameraRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))

    // Setup & consent
    var engine = EngineManager()
    var consentGranted = false
    var consentExpiry: String?
    var eligibility = DeviceEligibility()
    var ageVerification: AgeVerification?
    /// Set when Apple's age service could not answer, which unlocks the manual path.
    var appleAgeCheckUnavailable = false
    var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    var grants = GrantSelection()
    var consentError: String?

    /// The app is usable only once the owner has granted consent for an eligible device.
    var needsSetup: Bool { !consentGranted || !eligibility.ok }

    // Persistence
    var savedTrips: [SavedTrip] = []

    private let tripStore = TripStore(url: TripStore.defaultURL())
    private let client = ControlClient()
    private var stateTask: Task<Void, Never>?

    // MARK: - Connection

    /// Start the engine (the app owns it — no terminal involved), then connect.
    ///
    /// Establishing Apple's native tunnel can take twenty seconds or more on a first
    /// run while `remotepairingd` discovers the device, so the wait here is generous.
    /// Failing early would show "engine not running" on a perfectly healthy launch.
    func startUp() async {
        await engine.start()

        for _ in 0..<240 {                                  // up to 60 s
            if engine.phase.isRunning { break }
            if case .failed = engine.phase { return }
            if case .notConfigured = engine.phase { return }
            try? await Task.sleep(for: .milliseconds(250))
        }

        for _ in 0..<5 {
            await connect()
            if connected { break }
            try? await Task.sleep(for: .seconds(1))
        }
        await refreshConsent()
        restoreWorkingTrip()
    }

    // MARK: - Persistence

    /// Bring back whatever was on screen when Mirage last closed — cleanly or not.
    private func restoreWorkingTrip() {
        savedTrips = tripStore.trips
        let working = tripStore.working
        guard !working.waypoints.isEmpty else { return }

        waypoints = working.waypoints.map {
            Waypoint(name: $0.name,
                     coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                     stopMinutes: $0.stopMinutes)
        }
        if let first = waypoints.first { cameraRegion.center = first.coordinate }
        Task { await planRoute() }
    }

    /// Written on every change, not on quit: the failure this guards against is the app
    /// being killed, and a store that only flushes on a clean exit would lose exactly
    /// the cases that matter.
    private func persistWorking() {
        tripStore.saveWorking(waypoints.map(\.saved))
    }

    func saveCurrentTrip(named name: String? = nil) {
        guard !waypoints.isEmpty else { return }
        let saved = waypoints.map(\.saved)
        let trip = SavedTrip(name: name ?? SavedTrip.suggestedName(for: saved), waypoints: saved)
        tripStore.save(trip)
        savedTrips = tripStore.trips
    }

    func loadTrip(_ trip: SavedTrip) {
        waypoints = trip.waypoints.map {
            Waypoint(name: $0.name,
                     coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                     stopMinutes: $0.stopMinutes)
        }
        if let first = waypoints.first { cameraRegion.center = first.coordinate }
        persistWorking()
        Task { await planRoute() }
    }

    /// Dismiss the session-length notice and keep the location as it is.
    func acknowledgeLimit() {
        limitAcknowledged = true
    }

    func deleteTrip(_ id: SavedTrip.ID) {
        tripStore.delete(id)
        savedTrips = tripStore.trips
    }

    func renameTrip(_ id: SavedTrip.ID, to name: String) {
        tripStore.rename(id, to: name)
        savedTrips = tripStore.trips
    }

    /// Put the device back on real GPS *and* clear the working trip, so reopening Mirage
    /// does not present the old simulated setup as if it were still in effect.
    func resetToRealLocation() async {
        await restore()
        waypoints.removeAll()
        plannedRoute = nil
        planError = nil
        tripStore.clearWorking()
    }

    func connect() async {
        do {
            try await client.connect()
            connected = true
            connectionError = nil
            remedy = nil
            observeState()
            _ = try? await client.call("status")
        } catch {
            connected = false
            connectionError = error.localizedDescription
            remedy = (error as? ControlClient.Failure)?.recoverySuggestion
        }
    }

    func shutDown() {
        engine.stop()
    }

    // MARK: - Consent

    func refreshConsent() async {
        guard connected else { return }
        do {
            let status = try await client.call("consent.status")
            consentGranted = status["granted"]?.boolValue ?? false
            consentExpiry = status["record"]?["expires_at"]?.stringValue
            if let e = status["eligibility"] { eligibility = DeviceEligibility(e) }
            if let g = status["record"]?["grants"] {
                grants = GrantSelection(
                    allowPin: g["allow_pin"]?.boolValue ?? false,
                    allowDrive: g["allow_drive"]?.boolValue ?? false,
                    maxSessionMinutes: g["max_session_minutes"]?.intValue ?? 60)
            }
        } catch {
            consentError = error.localizedDescription
        }
    }

    func verifyAge() async {
        consentError = nil
        guard AgeGate.isSupported else {
            appleAgeCheckUnavailable = true
            consentError = "Apple's age verification requires macOS 26 or later."
            return
        }
        do {
            ageVerification = try await AgeGate.verify(threshold: 18)
            if let reason = ageVerification?.blockingReason { consentError = reason }
        } catch {
            // Most commonly: the build is not signed with a Developer ID, so Apple will
            // not serve account age data to it. Fall back rather than dead-end.
            appleAgeCheckUnavailable = true
            consentError = AgeGate.describe(error)
        }
    }

    /// Manual path, used only when Apple's service cannot answer. Recorded as
    /// self-attested so the consent record never overstates how it was verified.
    func confirmAgeManually() {
        let verification = AgeVerification.selfAttested(birthDate: birthDate)
        ageVerification = verification
        consentError = verification.blockingReason
    }

    func grantConsent() async {
        guard let age = ageVerification, age.blockingReason == nil else {
            consentError = "Age verification is required first."
            return
        }
        guard grants.allowPin || grants.allowDrive else {
            consentError = "Allow at least one capability, or there is nothing to grant."
            return
        }
        do {
            _ = try await client.call("consent.grant", [
                "meets_threshold": .bool(age.meetsThreshold),
                "threshold": .int(age.threshold),
                "lower_bound": age.lowerBound.map { JSON.int($0) } ?? .null,
                "upper_bound": age.upperBound.map { JSON.int($0) } ?? .null,
                "declaration": .string(age.declaration),
                "parental_controls_active": .bool(age.parentalControlsActive),
                "source": .string(age.source),
                "grants": grants.json,
            ])
            consentError = nil
            await refreshConsent()
        } catch {
            consentError = error.localizedDescription
        }
    }

    func revokeConsent() async {
        _ = try? await client.call("consent.revoke")
        ageVerification = nil
        await refreshConsent()
    }

    private func observeState() {
        stateTask?.cancel()
        let stream = client.states   // nonisolated, no await needed
        stateTask = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                await MainActor.run { self.apply(s) }
            }
        }
    }

    private func apply(_ s: JSON) {
        mode = Mode(rawValue: s["mode"]?.stringValue ?? "idle") ?? .idle
        if let lat = s["lat"]?.doubleValue, let lon = s["lon"]?.doubleValue {
            currentCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        speedKPH = (s["speed"]?.doubleValue ?? 0) * 3.6
        deviceConnected = s["device_connected"]?.boolValue ?? true
        unreachableFor = s["unreachable_for"]?.doubleValue ?? 0
        let nowLimited = s["limit_reached"]?.boolValue ?? false
        if nowLimited && !limitReached { limitAcknowledged = false }
        limitReached = nowLimited
        deviceDirty = s["device_dirty"]?.boolValue ?? false
        restorePending = s["restore_pending"]?.boolValue ?? false
        headingDegrees = s["heading"]?.doubleValue ?? 0
        progress = s["progress"]?.doubleValue ?? 0
        etaRemaining = s["eta_remaining"]?.doubleValue ?? 0
    }

    // MARK: - Search

    /// Called on every keystroke. `MKLocalSearchCompleter` does its own coalescing, so
    /// this does not need debouncing on top.
    func updateSuggestions() {
        completer.update(query: searchQuery, near: cameraRegion)
    }

    func choose(_ suggestion: AddressCompleter.Suggestion) async {
        do {
            let item = try await completer.resolve(suggestion)
            let name = item.name ?? suggestion.title
            addWaypoint(at: item.placemark.coordinate, name: name)
            searchQuery = ""
            completer.clear()
        } catch {
            planError = error.localizedDescription
        }
    }

    // MARK: - Waypoints

    /// Add a pin. Dropped pins get a readable name from reverse geocoding rather than
    /// being left as raw coordinates.
    func addWaypoint(at coordinate: CLLocationCoordinate2D, name: String? = nil) {
        let placeholder = name ?? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        let waypoint = Waypoint(name: placeholder, coordinate: coordinate)
        waypoints.append(waypoint)
        cameraRegion.center = coordinate
        persistWorking()

        if name == nil {
            let id = waypoint.id
            Task {
                let resolved = await RouteService.describe(coordinate)
                if let index = self.waypoints.firstIndex(where: { $0.id == id }) {
                    self.waypoints[index].name = resolved
                    self.persistWorking()
                }
            }
        }
        Task { await planRoute() }
    }

    func removeWaypoint(_ id: Waypoint.ID) {
        waypoints.removeAll { $0.id == id }
        persistWorking()
        Task { await planRoute() }
    }

    func moveWaypoints(from offsets: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: offsets, toOffset: destination)
        persistWorking()
        Task { await planRoute() }
    }

    func clearWaypoints() {
        waypoints.removeAll()
        plannedRoute = nil
        planError = nil
        persistWorking()
    }

    func setStopMinutes(_ minutes: Int, for id: Waypoint.ID) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[index].stopMinutes = minutes
        persistWorking()
        Task { await planRoute() }
    }

    // MARK: - Routing

    func planRoute() async {
        guard waypoints.count >= 2 else { plannedRoute = nil; planError = nil; return }
        isPlanning = true
        defer { isPlanning = false }
        do {
            plannedRoute = try await RouteService.route(through: waypoints)
            planError = nil
        } catch {
            plannedRoute = nil
            planError = error.localizedDescription
        }
    }

    // MARK: - Actions

    func pin(to coordinate: CLLocationCoordinate2D) async {
        await perform("Setting location") {
            try await self.client.call("session.pin", [
                "lat": .double(coordinate.latitude),
                "lon": .double(coordinate.longitude),
            ])
        }
    }

    func startDrive() async {
        guard let route = plannedRoute else { return }
        let points = JSON.array(route.coordinates.map {
            .array([.double($0.latitude), .double($0.longitude)])
        })
        let stops = JSON.array(route.stops.map {
            .object(["index": .int($0.index), "seconds": .double($0.seconds)])
        })
        await perform("Starting drive") {
            let result = try await self.client.call("session.drive", [
                "points": points,
                "expected_travel_time": .double(route.drivingTime),
                "stops": stops,
            ])
            self.etaUnachievable = (result["eta_achievable"]?.boolValue == false)
        }
    }

    /// Hold the single dropped pin as a static location.
    func pinFirstWaypoint() async {
        guard let waypoint = waypoints.first else { return }
        await pin(to: waypoint.coordinate)
    }

    func stop() async {
        await perform("Stopping") {
            try await self.client.call("session.stop")
            self.etaUnachievable = false
        }
    }

    /// Put the device back on real GPS, whatever Mirage currently believes.
    ///
    /// Always available while connected, never gated on consent or on `mode`. If a
    /// previous run was killed while simulating, this app has no record of it — but the
    /// device is still simulating, and this is the only way back.
    func restore() async {
        await perform("Restoring real location") {
            try await self.client.call("session.restore")
            self.etaUnachievable = false
        }
    }

    private func perform(_ label: String = "Working", _ body: @escaping () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do {
            try await body()
            connectionError = nil
            remedy = nil
        } catch {
            connectionError = error.localizedDescription
            remedy = (error as? ControlClient.Failure)?.recoverySuggestion
        }
        await refreshStatus()
    }

    /// Re-read the engine's view after any action, so the durable marker is never stale
    /// on screen — including after a failure.
    func refreshStatus() async {
        guard connected else { return }
        if let status = try? await client.call("status"), let state = status["state"] {
            apply(state)
        }
    }

    /// Why the main actions are unavailable, so a greyed-out button is never a mystery.
    var driveBlockedReason: String? {
        if !connected { return "The engine is not running." }
        if !grants.allowDrive { return "Simulating a drive was not allowed during setup." }
        if waypoints.count < 2 { return "Add at least two places." }
        if plannedRoute == nil { return "No route yet." }
        return nil
    }

    var pinBlockedReason: String? {
        if !connected { return "The engine is not running." }
        if !grants.allowPin { return "Holding a location was not allowed during setup." }
        if waypoints.isEmpty { return "Add a place, or click the map." }
        return nil
    }
}
