import Foundation
import Testing
@testable import MirageKit

// MARK: - Helpers

private final class TestClock: MonotonicClock {
    var now: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { now += seconds }
}

private func tempURL(_ name: String = "simulation.json") -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mirage-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

/// A route long enough that a suspension can happen in the middle of it.
private func longDrive() throws -> DrivePlan {
    let poly = try Polyline([
        LatLon(51.4490, -2.6000), LatLon(51.4490, -2.5900), LatLon(51.4520, -2.5850),
        LatLon(51.4560, -2.5845), LatLon(51.4600, -2.5800), LatLon(51.4600, -2.5700),
        LatLon(51.4640, -2.5650),
    ])
    return buildPlan(poly, expectedTravelTime: 1800, includeStops: false)
}

private struct Unreachable: Error {}

@MainActor
private final class FailingClear: LocationInjector {
    func open() async throws {}
    func set(lat: Double, lon: Double) async throws {}
    func clear() async throws { throw Unreachable() }
    func close() async throws {}
}

// MARK: - The backgrounding case

@Suite("A suspended app resumes at the right place")
@MainActor
struct SuspensionTests {

    @Test("A drive skips forward by the real gap, not by one tick")
    func longGapAdvancesByTheClock() async throws {
        let plan = try longDrive()
        let clock = TestClock()
        let injector = MockInjector()
        let session = DriveSession(injector: injector, clock: clock, tickInterval: 1.0)

        try await session.drive(plan)
        await session.tick()

        // The phone locks; iOS suspends the app for twenty minutes.
        clock.advance(1200)
        let state = await session.tick()

        // The position asked for is where the driver would be by now, not one tick on.
        let expected = plan.state(at: 1200)
        #expect(abs(state.elapsed - 1200) < 0.001)
        #expect(abs(state.progress - 1200 / plan.totalTime) < 0.001)

        // Within drift distance of the planned point — the fix carries OU noise on top.
        let delivered = LatLon(injector.fixes.last!.lat, injector.fixes.last!.lon)
        #expect(haversine(delivered, expected.point) < 50)
    }

    @Test("No gap is replayed — one fix per tick, however long the gap")
    func noCatchUpBurst() async throws {
        let plan = try longDrive()
        let clock = TestClock()
        let injector = MockInjector()
        let session = DriveSession(injector: injector, clock: clock)

        try await session.drive(plan)
        await session.tick()
        clock.advance(900)
        await session.tick()

        #expect(injector.fixes.count == 2)
    }

    @Test("Arriving during a suspension lands on the destination, holding")
    func arrivalDuringSuspension() async throws {
        let plan = try longDrive()
        let clock = TestClock()
        let session = DriveSession(injector: MockInjector(), clock: clock)

        try await session.drive(plan)
        await session.tick()
        clock.advance(plan.totalTime + 600)
        let state = await session.tick()

        // Arrived. Holds the destination with stationary drift rather than stopping dead.
        #expect(state.mode == .pinned)
        #expect(state.speed == 0)
        #expect(abs(state.progress - 1.0) < 0.001)
        #expect(state.etaRemaining == 0)
        #expect(state.profileName == "stationary")
    }
}

// MARK: - Session state machine

@Suite("Session behaviour")
@MainActor
struct SessionTests {

    @Test("A held pin keeps drifting rather than sitting perfectly still")
    func pinDrifts() async throws {
        let injector = MockInjector()
        let clock = TestClock()
        let session = DriveSession(injector: injector, clock: clock)

        try await session.pin(lat: 51.4545, lon: -2.5879)
        for _ in 0..<5 { clock.advance(1); await session.tick() }

        #expect(injector.fixes.count == 5)
        let distinct = Set(injector.fixes.map { "\($0.lat),\($0.lon)" })
        #expect(distinct.count == 5, "a static coordinate is the loudest tell there is")

        // But it stays near the anchor rather than wandering off.
        for f in injector.fixes {
            #expect(haversine(LatLon(f.lat, f.lon), LatLon(51.4545, -2.5879)) < 40)
        }
    }

    @Test("The session limit holds the position and restores nothing")
    func limitHoldsButDoesNotRestore() async throws {
        let plan = try longDrive()
        let clock = TestClock()
        let injector = MockInjector()
        let session = DriveSession(injector: injector, clock: clock, maxDuration: 60)

        try await session.drive(plan)
        await session.tick()
        clock.advance(120)
        let state = await session.tick()

        #expect(state.limitReached)
        #expect(state.mode == .pinned)
        #expect(state.speed == 0)
        // The device is emphatically not put back — that is the user's decision.
        #expect(injector.clears == 0)
        #expect(state.deviceDirty)
    }

    @Test("A drive continues while the phone is unreachable, then resumes in place")
    func journeyOutlivesDisconnection() async throws {
        let plan = try longDrive()
        let clock = TestClock()
        let injector = MockInjector()
        let session = DriveSession(injector: injector, clock: clock)

        try await session.drive(plan)
        await session.tick()
        let deliveredBefore = injector.fixes.count

        injector.failure = Unreachable()
        clock.advance(300)
        var state = await session.tick()
        #expect(state.deviceConnected == false)
        #expect(injector.fixes.count == deliveredBefore, "nothing was delivered")
        #expect(abs(state.elapsed - 300) < 0.001, "but the journey kept its clock")

        injector.failure = nil
        clock.advance(300)
        state = await session.tick()
        #expect(state.deviceConnected)
        #expect(state.unreachableFor == 0)
        // No rewind: the first fix after reconnecting is where the driver is now.
        #expect(abs(state.elapsed - 600) < 0.001)
    }

    @Test("Restore clears the device and the durable record together")
    func restoreClearsBoth() async throws {
        let url = tempURL()
        let marker = SimulationMarker(url: url, protectedAtRest: false)
        let injector = MockInjector()
        let session = DriveSession(injector: injector, clock: TestClock(), marker: marker)

        try await session.pin(lat: 51.4545, lon: -2.5879)
        await session.tick()
        #expect(marker.isActive)

        try await session.restore()
        #expect(injector.clears >= 1)
        #expect(marker.isActive == false)
        #expect(session.state.mode == .idle)
        #expect(session.state.deviceDirty == false)
    }

    @Test("A restore that cannot reach the phone is remembered, not forgotten")
    func failedRestoreIsRemembered() async throws {
        let url = tempURL()
        let marker = SimulationMarker(url: url, protectedAtRest: false)
        let session = DriveSession(injector: FailingClear(), clock: TestClock(), marker: marker)

        await #expect(throws: DeviceUnreachable.self) {
            try await session.restore()
        }
        #expect(marker.isRestorePending, "the user's request outlives the failed attempt")
        #expect(session.state.restorePending)
    }
}

// MARK: - The durable marker

@Suite("The simulation marker")
struct MarkerTests {

    @Test("Nothing is recorded until a fix is actually delivered")
    @MainActor
    func writtenOnFirstDeliveredFix() async throws {
        let url = tempURL()
        let marker = SimulationMarker(url: url, protectedAtRest: false)
        let injector = MockInjector()
        injector.failure = Unreachable()
        let session = DriveSession(injector: injector, clock: TestClock(), marker: marker)

        try await session.pin(lat: 51.4545, lon: -2.5879)
        await session.tick()
        #expect(marker.isActive == false, "a session that never reached the phone left nothing to undo")

        injector.failure = nil
        await session.tick()
        #expect(marker.isActive)
    }

    @Test("It survives the process going away")
    func survivesRestart() {
        let url = tempURL()
        SimulationMarker(url: url, protectedAtRest: false)
            .markActive(lat: 51.4545, lon: -2.5879, udid: "test-udid")

        let reopened = SimulationMarker(url: url, protectedAtRest: false)
        #expect(reopened.isActive)
        #expect(reopened.current.lat == 51.4545)
    }

    @Test("An unreadable marker is treated as active, not absent")
    func corruptMeansActive() throws {
        let url = tempURL()
        try Data("{ this is not json".utf8).write(to: url)

        // Forgetting that the device may be simulating is the one failure with no
        // recovery, so a file we cannot parse errs toward telling the user.
        #expect(SimulationMarker(url: url, protectedAtRest: false).isActive)
    }

    @Test("A missing marker is simply inactive")
    func missingIsInactive() {
        #expect(SimulationMarker(url: tempURL(), protectedAtRest: false).isActive == false)
    }

    @Test("The raw device identifier is never written to disk")
    func udidIsFingerprinted() throws {
        let url = tempURL()
        let marker = SimulationMarker(url: url, protectedAtRest: false)
        marker.markActive(lat: 51.4545, lon: -2.5879, udid: "EXAMPLE0-000000000000DEAD")

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("EXAMPLE0-000000000000DEAD"))
        #expect(marker.current.device != nil)
    }

    @Test("Coordinates are blurred in anything human-readable")
    func describeIsCoarse() {
        let marker = SimulationMarker(url: tempURL(), protectedAtRest: false)
        marker.markActive(lat: 51.454567, lon: -2.587891, udid: "u")
        let text = marker.describe()
        #expect(!text.contains("51.454567"))
        #expect(text.contains("51.5"))
    }

    @Test("No temporary file is left behind")
    func noTempLeftBehind() {
        let url = tempURL()
        SimulationMarker(url: url, protectedAtRest: false)
            .markActive(lat: 1, lon: 2, udid: nil)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        #expect(FileManager.default.fileExists(atPath: tmp.path) == false)
    }
}

// MARK: - Live Activity content

@Suite("What the Live Activity says")
struct LiveActivityTests {

    @Test("Driving shows speed and time remaining")
    func drivingContent() {
        var s = SessionState()
        s.mode = .driving
        s.speed = 13.4
        s.progress = 0.62
        s.etaRemaining = 720

        let c = LiveActivityContent(state: s, units: .metric,
                                    destination: "Temple Meads", nextStop: "Vale Park")
        #expect(c.kind == .driving)
        #expect(c.title == "Driving to Temple Meads")
        #expect(c.subtitle == "48 km/h · next stop Vale Park")
        #expect(c.compactLabel == "12 min")
        #expect(c.showsProgress)
    }

    @Test("A disconnected phone is never described as restored")
    func disconnectedIsHonest() {
        var s = SessionState()
        s.mode = .driving
        s.deviceConnected = false
        s.unreachableFor = 120

        let c = LiveActivityContent(state: s)
        #expect(c.kind == .disconnected)
        #expect(c.subtitle.contains("Still simulating"))
    }

    @Test("Reaching the session limit says nothing was restored")
    func limitIsHonest() {
        var s = SessionState()
        s.mode = .pinned
        s.limitReached = true

        let c = LiveActivityContent(state: s)
        #expect(c.kind == .held)
        #expect(c.subtitle.contains("nothing has been restored"))
    }

    @Test("The same drive reads in the viewer's own units")
    func unitsFollowThePreference() {
        var s = SessionState()
        s.mode = .driving
        s.speed = 30 * 1609.344 / 3600   // exactly 30 mph

        #expect(LiveActivityContent(state: s, units: .imperial).subtitle == "30 mph")
        #expect(LiveActivityContent(state: s, units: .metric).subtitle == "48 km/h")
    }

    @Test("Restore is offered in every state, including when we think nothing is running")
    func restoreAlwaysOffered() {
        for kind: LiveActivityContent.Kind in [.driving, .holding, .held, .disconnected] {
            #expect(LiveActivityContent(kind: kind).showsRestore)
        }
    }

    @Test("Durations read the way a person would say them")
    func durationFormatting() {
        #expect(LiveActivityContent.shortDuration(0) == "0s")
        #expect(LiveActivityContent.shortDuration(45) == "45s")
        #expect(LiveActivityContent.shortDuration(720) == "12 min")
        #expect(LiveActivityContent.shortDuration(3600) == "1 h")
        #expect(LiveActivityContent.shortDuration(5400) == "1 h 30 min")
        #expect(LiveActivityContent.shortDuration(-5) == "0s")
    }
}
