import Foundation
import Testing
@testable import MirageKit

private func tempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mirage-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("trips.json")
}

private let sf = SavedWaypoint(name: "San Francisco", latitude: 37.7749, longitude: -122.4194)
private let oak = SavedWaypoint(name: "Oakland", latitude: 37.8044, longitude: -122.2712, stopMinutes: 15)
private let sj = SavedWaypoint(name: "San Jose", latitude: 37.3382, longitude: -121.8863)

@Suite("Working state survives restart")
struct WorkingStateTests {

    @Test("A working trip is readable by a fresh store — the crash case")
    func survivesProcessRestart() {
        let url = tempURL()
        TripStore(url: url).saveWorking([sf, oak, sj])

        // A new instance is what the next launch sees. Nothing was flushed on quit,
        // because in a crash there is no quit.
        let reopened = TripStore(url: url)
        #expect(reopened.working.waypoints.count == 3)
        #expect(reopened.working.waypoints[1].name == "Oakland")
        #expect(reopened.working.waypoints[1].stopMinutes == 15)
    }

    @Test("Clearing the working trip persists too")
    func clearPersists() {
        let url = tempURL()
        let store = TripStore(url: url)
        store.saveWorking([sf])
        store.clearWorking()
        #expect(TripStore(url: url).working.waypoints.isEmpty)
    }

    @Test("Every save overwrites the previous working trip rather than appending")
    func savesReplace() {
        let url = tempURL()
        let store = TripStore(url: url)
        store.saveWorking([sf, oak])
        store.saveWorking([sj])
        #expect(TripStore(url: url).working.waypoints.map(\.name) == ["San Jose"])
    }
}

@Suite("Saved trips")
struct SavedTripTests {

    @Test("Saved trips round-trip through disk")
    func roundTrip() {
        let url = tempURL()
        let store = TripStore(url: url)
        store.save(SavedTrip(name: "Commute", waypoints: [sf, oak]))

        let reopened = TripStore(url: url)
        #expect(reopened.trips.count == 1)
        #expect(reopened.trips[0].name == "Commute")
        #expect(reopened.trips[0].isDrive)
    }

    @Test("Saving an existing id updates rather than duplicating")
    func updateInPlace() {
        let store = TripStore(url: tempURL())
        var trip = SavedTrip(name: "Commute", waypoints: [sf, oak])
        store.save(trip)
        trip.waypoints = [sf, oak, sj]
        store.save(trip)
        #expect(store.trips.count == 1)
        #expect(store.trips[0].waypoints.count == 3)
    }

    @Test("Delete and rename persist")
    func deleteAndRename() {
        let url = tempURL()
        let store = TripStore(url: url)
        let a = store.save(SavedTrip(name: "A", waypoints: [sf, oak]))
        let b = store.save(SavedTrip(name: "B", waypoints: [sf, sj]))

        store.rename(a.id, to: "Renamed")
        store.delete(b.id)

        let reopened = TripStore(url: url)
        #expect(reopened.trips.count == 1)
        #expect(reopened.trips[0].name == "Renamed")
    }

    @Test("Most recently updated trip sorts first")
    func sortedByRecency() {
        let store = TripStore(url: tempURL())
        store.save(SavedTrip(name: "older", waypoints: [sf, oak]))
        store.save(SavedTrip(name: "newer", waypoints: [sf, sj]))
        #expect(store.trips.first?.name == "newer")
    }

    @Test("A single waypoint is a place, not a drive")
    func singleWaypointIsNotADrive() {
        #expect(!SavedTrip(name: "Home", waypoints: [sf]).isDrive)
    }
}

@Suite("Robustness")
struct RobustnessTests {

    @Test("A corrupted file starts clean instead of bricking the app")
    func corruptedFile() {
        let url = tempURL()
        try? "{ not json at all".write(to: url, atomically: true, encoding: .utf8)
        let store = TripStore(url: url)
        #expect(store.trips.isEmpty)
        #expect(store.working.waypoints.isEmpty)

        // And it recovers: the next write succeeds.
        store.saveWorking([sf])
        #expect(TripStore(url: url).working.waypoints.count == 1)
    }

    @Test("A missing file is not an error")
    func missingFile() {
        #expect(TripStore(url: tempURL()).trips.isEmpty)
    }

    @Test("Non-finite coordinates are dropped before they reach MapKit")
    func rejectsNaN() {
        let url = tempURL()
        let poison = """
        {"version":1,
         "working":{"savedAt":"2026-01-01T00:00:00Z",
                    "waypoints":[{"name":"bad","latitude":null,"longitude":0,"stopMinutes":0}]},
         "trips":[]}
        """
        try? poison.write(to: url, atomically: true, encoding: .utf8)
        #expect(TripStore(url: url).working.waypoints.isEmpty)
    }

    @Test("Out-of-range coordinates are dropped")
    func rejectsOutOfRange() {
        #expect(!SavedWaypoint(name: "x", latitude: 91, longitude: 0).isValid)
        #expect(!SavedWaypoint(name: "x", latitude: 0, longitude: 181).isValid)
        #expect(!SavedWaypoint(name: "x", latitude: .nan, longitude: 0).isValid)
        #expect(SavedWaypoint(name: "x", latitude: 37.7, longitude: -122.4).isValid)
    }

    @Test("The store file is owner-only")
    func filePermissions() throws {
        let url = tempURL()
        TripStore(url: url).saveWorking([sf])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600, "trip history is location data; it must not be world-readable")
    }

    @Test("No temporary file is left behind after a write")
    func noTempFileLeftBehind() {
        let url = tempURL()
        TripStore(url: url).saveWorking([sf])
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)) ?? []
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })
    }
}

@Suite("Naming")
struct NamingTests {

    @Test("Suggested names describe the trip")
    func suggestedNames() {
        #expect(SavedTrip.suggestedName(for: [sf]) == "San Francisco")
        #expect(SavedTrip.suggestedName(for: [sf, sj]) == "San Francisco → San Jose")
        #expect(SavedTrip.suggestedName(for: [sf, oak, sj]).contains("1 stop"))
        #expect(SavedTrip.suggestedName(for: [sf, oak, oak, sj]).contains("2 stops"))
        #expect(SavedTrip.suggestedName(for: []) == "Empty trip")
    }
}
