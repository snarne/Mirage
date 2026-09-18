import Foundation

/// A place on a saved trip. Coordinates are stored as plain numbers rather than
/// `CLLocationCoordinate2D` so this file stays free of MapKit and testable on its own.
public struct SavedWaypoint: Codable, Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var stopMinutes: Int

    public init(name: String, latitude: Double, longitude: Double, stopMinutes: Int = 5) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.stopMinutes = stopMinutes
    }

    /// Guards against coordinates that would be rejected downstream, and against the
    /// NaN that a corrupted file could otherwise feed straight into MapKit.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct SavedTrip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var waypoints: [SavedWaypoint]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, waypoints: [SavedWaypoint], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.updatedAt = updatedAt
    }

    public var isDrive: Bool { waypoints.count >= 2 }

    /// A readable default name, so saving never demands the user invent one.
    public static func suggestedName(for waypoints: [SavedWaypoint]) -> String {
        guard let last = waypoints.last else { return "Empty trip" }
        if waypoints.count == 1 { return last.name }
        let stops = waypoints.count - 2
        let base = "\(waypoints[0].name) → \(last.name)"
        return stops > 0 ? "\(base) (\(stops) stop\(stops == 1 ? "" : "s"))" : base
    }
}

/// The trip the user was building when Mirage last shut down — the bit that has to
/// survive a crash, not just a clean quit.
///
/// Deliberately says nothing about whether a location was *set*. The engine's marker file
/// is the single record of that, and a second, weaker copy here could drift from it —
/// which is precisely the class of bug that let Mirage forget a device was simulating.
public struct WorkingState: Codable, Equatable, Sendable {
    public var waypoints: [SavedWaypoint]
    public var savedAt: Date

    public init(waypoints: [SavedWaypoint] = [], savedAt: Date = Date()) {
        self.waypoints = waypoints
        self.savedAt = savedAt
    }
}

private struct Library: Codable {
    var version: Int = 1
    var working: WorkingState = WorkingState()
    var trips: [SavedTrip] = []
}

/// Persists the working trip and the user's saved trips.
///
/// Every mutation writes immediately rather than waiting for termination: the failure
/// this exists to survive is the app being killed, and a store that only flushes on a
/// clean quit would lose exactly the cases that matter.
///
/// Writes go to a temporary file and are then atomically replaced, so an interrupted
/// write cannot leave a half-written file behind.
public final class TripStore: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "io.mirage.tripstore")
    private var library = Library()

    public init(url: URL) {
        self.url = url
        self.library = Self.read(from: url) ?? Library()
    }

    /// Where trips live when nobody says otherwise.
    ///
    /// On the Mac this is the same directory the Python engine and the control socket
    /// use, reached through the real home directory so that the app and the engine agree
    /// on one path. On iOS there is no such thing as a home directory to reach — an app
    /// gets a container and `homeDirectoryForCurrentUser` is not merely different but
    /// unavailable — so the search-path API is the only correct answer, and it happens to
    /// land in the same relative place.
    public static func defaultURL() -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["MIRAGE_STATE_DIR"] {
            base = URL(fileURLWithPath: override)
        } else {
            #if os(macOS)
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Mirage")
            #else
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mirage", isDirectory: true)
            #endif
        }
        return base.appendingPathComponent("trips.json")
    }

    // MARK: - Working state

    public var working: WorkingState {
        queue.sync { library.working }
    }

    public func saveWorking(_ waypoints: [SavedWaypoint]) {
        queue.sync {
            library.working = WorkingState(waypoints: waypoints, savedAt: Date())
            write()
        }
    }

    public func clearWorking() {
        queue.sync {
            library.working = WorkingState()
            write()
        }
    }

    // MARK: - Saved trips

    public var trips: [SavedTrip] {
        queue.sync { library.trips.sorted { $0.updatedAt > $1.updatedAt } }
    }

    @discardableResult
    public func save(_ trip: SavedTrip) -> SavedTrip {
        queue.sync {
            var stored = trip
            stored.updatedAt = Date()
            if let index = library.trips.firstIndex(where: { $0.id == trip.id }) {
                library.trips[index] = stored
            } else {
                library.trips.append(stored)
            }
            write()
            return stored
        }
    }

    public func delete(_ id: SavedTrip.ID) {
        queue.sync {
            library.trips.removeAll { $0.id == id }
            write()
        }
    }

    public func rename(_ id: SavedTrip.ID, to name: String) {
        queue.sync {
            guard let index = library.trips.firstIndex(where: { $0.id == id }) else { return }
            library.trips[index].name = name
            library.trips[index].updatedAt = Date()
            write()
        }
    }

    // MARK: - Disk

    private static func read(from url: URL) -> Library? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var library = try? decoder.decode(Library.self, from: data) else {
            // A corrupted file must not brick the app. Start clean rather than throwing
            // on every launch; the working trip is a convenience, not user data to
            // fight for.
            return nil
        }
        // Drop anything unusable before it reaches MapKit.
        library.working.waypoints = library.working.waypoints.filter(\.isValid)
        library.trips = library.trips.compactMap { trip in
            var t = trip
            t.waypoints = t.waypoints.filter(\.isValid)
            return t.waypoints.isEmpty ? nil : t
        }
        return library
    }

    /// Caller holds `queue`.
    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(library) else { return }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
