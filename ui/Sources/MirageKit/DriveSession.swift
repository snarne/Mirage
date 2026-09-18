import Foundation

/// Session orchestration: what is being simulated right now, and the tick.
/// A port of the state machine in `core/mirage/session.py`.
///
/// Safety invariant: **the device must never be left simulating a location after Mirage
/// stops.** A user who thinks they are back to their real position when they are not is
/// strictly worse off than one who was never spoofing.
///
/// The property that makes an iPhone build possible at all: the trajectory is driven by
/// the **clock**, not by what got delivered. `elapsed` is read from the clock on every
/// tick, so a suspended app that resumes ten minutes later simply asks the plan where the
/// driver would be by now. There is no catch-up loop and no replay of the gap — which is
/// exactly what a backgrounded app needs, and exactly what already happens on the Mac
/// when a phone is unplugged mid-drive.

/// Monotonic time source. Injectable so tests can advance an hour without waiting one.
public protocol MonotonicClock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemClock: MonotonicClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The location override itself. The same four calls as the Python `Injector` Protocol,
/// so a DVT-over-loopback backend drops in beside the mock without touching this file.
@MainActor
public protocol LocationInjector: AnyObject {
    func open() async throws
    func set(lat: Double, lon: Double) async throws
    func clear() async throws
    func close() async throws
}

/// Records fixes instead of sending them, so the whole session can be exercised with no
/// iPhone and no tunnel.
@MainActor
public final class MockInjector: LocationInjector {
    public private(set) var fixes: [(lat: Double, lon: Double)] = []
    public private(set) var clears = 0
    public private(set) var isOpen = false
    /// When set, `set` throws — the phone-went-away case.
    public var failure: Error?

    public init() {}

    public func open() async throws { isOpen = true }
    public func set(lat: Double, lon: Double) async throws {
        if let failure { throw failure }
        fixes.append((lat, lon))
    }
    public func clear() async throws { clears += 1 }
    public func close() async throws { isOpen = false }
}

public enum SessionMode: String, Codable, Sendable {
    case idle, pinned, driving
}

public struct SessionState: Equatable, Sendable {
    public var mode: SessionMode = .idle
    public var lat: Double?
    public var lon: Double?
    public var heading: Double = 0
    public var speed: Double = 0            // m/s
    public var elapsed: TimeInterval = 0
    public var totalTime: TimeInterval = 0
    public var distance: Double = 0         // m
    public var progress: Double = 0         // 0...1
    public var etaRemaining: TimeInterval = 0
    public var profileName: String = "stationary"

    /// A drive keeps running while the phone is away, so the UI must distinguish
    /// "nothing is happening" from "the journey continues, we just cannot deliver it yet".
    public var deviceConnected: Bool = true
    public var deviceError: String?
    public var unreachableFor: TimeInterval = 0

    /// Session length hit: holding, not restored.
    public var limitReached: Bool = false

    /// Mirage's durable belief about the device, independent of whether a session is
    /// running in this process.
    public var deviceDirty: Bool = false
    public var restorePending: Bool = false

    public init() {}
}

@MainActor
public final class DriveSession {
    public private(set) var state = SessionState()

    private var injector: any LocationInjector
    private let clock: any MonotonicClock
    private let marker: SimulationMarker?
    private let udid: String?

    /// A cap the owner set during consent. Enforced here rather than in the UI so it holds
    /// however the session is driven.
    public var maxDuration: TimeInterval?

    /// Nominal tick interval, used as the `dt` handed to the drift process when ticks
    /// arrive on schedule.
    public let tickInterval: TimeInterval

    private var plan: DrivePlan?
    private var anchor: LatLon?
    private var jitter: OrnsteinUhlenbeck2D
    private var startedAt: TimeInterval = 0
    private var lastTickAt: TimeInterval?
    private var lostAt: TimeInterval?

    public init(
        injector: any LocationInjector,
        clock: any MonotonicClock = SystemClock(),
        marker: SimulationMarker? = nil,
        udid: String? = nil,
        maxDuration: TimeInterval? = nil,
        tickInterval: TimeInterval = 1.0
    ) {
        self.injector = injector
        self.clock = clock
        self.marker = marker
        self.udid = udid
        self.maxDuration = maxDuration
        self.tickInterval = tickInterval
        self.jitter = OrnsteinUhlenbeck2D(profile: .stationary)
        self.state.deviceDirty = marker?.isActive ?? false
        self.state.restorePending = marker?.isRestorePending ?? false
    }

    // MARK: - Lifecycle

    /// Hold a fixed position, with drift so it does not look frozen.
    public func pin(lat: Double, lon: Double, profile: JitterProfile = .stationary,
                    profileName: String = "stationary") async throws {
        try await restart(mode: .pinned, anchor: LatLon(lat, lon), plan: nil,
                          profile: profile, profileName: profileName)
    }

    /// Play a planned route.
    public func drive(_ plan: DrivePlan) async throws {
        try await restart(mode: .driving, anchor: nil, plan: plan,
                          profile: .driving, profileName: "driving")
    }

    private func restart(mode: SessionMode, anchor: LatLon?, plan: DrivePlan?,
                         profile: JitterProfile, profileName: String) async throws {
        self.anchor = anchor
        self.plan = plan
        self.jitter = OrnsteinUhlenbeck2D(profile: profile)
        self.startedAt = clock.now
        self.lastTickAt = nil
        self.lostAt = nil

        var fresh = SessionState()
        fresh.mode = mode
        fresh.profileName = profileName
        fresh.totalTime = plan?.totalTime ?? 0
        fresh.distance = plan?.distance ?? 0
        fresh.etaRemaining = plan?.totalTime ?? 0
        fresh.deviceDirty = marker?.isActive ?? false
        fresh.restorePending = marker?.isRestorePending ?? false
        self.state = fresh

        try await injector.open()
    }

    /// Clear any simulation on the device, whatever this session believes.
    ///
    /// Does not care what mode it is in: it opens the channel and clears unconditionally,
    /// because the failure this guards against is a previous run dying without its
    /// shutdown path. Clearing when nothing is simulated is a no-op on the device, so this
    /// is always safe to call.
    public func restore() async throws {
        do {
            try await injector.open()
            try await injector.clear()
        } catch {
            // The intent outlives the failed attempt. Completing a restore the user
            // already asked for, once the device is reachable again, is finishing their
            // request — not changing things behind their back.
            marker?.requestRestore()
            state.restorePending = true
            state.deviceError = String(describing: error)
            throw DeviceUnreachable(underlyingDescription: String(describing: error))
        }
        marker?.markRestored()
        plan = nil
        anchor = nil
        var cleared = SessionState()
        cleared.deviceDirty = false
        cleared.restorePending = false
        state = cleared
    }

    public func close() async throws {
        try await injector.close()
    }

    // MARK: - Tick

    /// Advance the session and deliver one fix.
    ///
    /// Safe to call at any interval, including after a long suspension: `elapsed` comes
    /// from the clock, and the drift `dt` is the real gap since the previous tick, which
    /// the exact OU solution handles correctly for any value.
    @discardableResult
    public func tick() async -> SessionState {
        let now = clock.now
        let elapsed = now - startedAt
        let dt = lastTickAt.map { now - $0 } ?? tickInterval
        lastTickAt = now

        if let cap = maxDuration, !state.limitReached, elapsed >= cap {
            holdHere()
        }

        let base: LatLon
        if let plan {
            let s = plan.state(at: elapsed)
            state.elapsed = min(elapsed, plan.totalTime)
            state.heading = s.heading
            state.speed = s.speed
            state.progress = plan.totalTime > 0 ? min(1.0, elapsed / plan.totalTime) : 1.0
            state.etaRemaining = max(0, plan.totalTime - elapsed)
            base = s.point

            if elapsed >= plan.totalTime {
                // Arrived. Hold the destination with stationary drift rather than stopping
                // dead, which would look like the phone switched off.
                anchor = s.point
                self.plan = nil
                state.mode = .pinned
                state.profileName = "stationary"
                state.speed = 0
                jitter = OrnsteinUhlenbeck2D(profile: .stationary)
            }
        } else if let anchor {
            base = anchor
            state.speed = 0
        } else {
            return state
        }

        let fix = jitter.apply(to: base, dt: max(0, dt))
        await deliver(fix, at: now)
        state.lat = fix.lat
        state.lon = fix.lon
        return state
    }

    /// Freeze the journey where it is and keep reporting that position.
    ///
    /// The session length is a reminder, not a kill switch: it stops the drive advancing
    /// and raises a flag, but never restores the device. Undoing a location someone chose
    /// is their decision, and they may not be looking at the phone to make it.
    private func holdHere() {
        if let lat = state.lat, let lon = state.lon {
            anchor = LatLon(lat, lon)
        }
        plan = nil
        state.mode = .pinned
        state.speed = 0
        state.profileName = "stationary"
        state.limitReached = true
        jitter = OrnsteinUhlenbeck2D(profile: .stationary)
    }

    /// Send one fix, tolerating a phone that is not currently reachable.
    ///
    /// A failure here must not end the journey. The trajectory is driven by the clock, not
    /// by what got delivered, so a drive continues through a disconnection and the first
    /// fix after reconnecting is wherever the driver would actually be by then — no
    /// rewind, no replay of the gap.
    private func deliver(_ fix: LatLon, at now: TimeInterval) async {
        do {
            try await injector.set(lat: fix.lat, lon: fix.lon)
        } catch {
            if state.deviceConnected { lostAt = now }
            state.deviceConnected = false
            state.deviceError = String(describing: error)
            state.unreachableFor = lostAt.map { now - $0 } ?? 0
            return
        }
        // Recorded only once the device has actually accepted a fix: a session that never
        // reached the phone left nothing to undo.
        marker?.markActive(lat: fix.lat, lon: fix.lon, udid: udid)
        state.deviceDirty = true
        state.deviceConnected = true
        state.deviceError = nil
        state.unreachableFor = 0
        lostAt = nil
    }
}

/// The device could not be reached to clear the simulation.
///
/// Distinct from an ordinary failure because the consequence is specific and needs saying
/// plainly: the phone is still reporting a false location.
public struct DeviceUnreachable: Error, Sendable {
    public let underlyingDescription: String

    public var remedy: String {
        "Your iPhone is still reporting the simulated location. Reconnect it to the "
        + "network, then press Restore Real Location again. Restarting the iPhone also "
        + "clears it."
    }
}
