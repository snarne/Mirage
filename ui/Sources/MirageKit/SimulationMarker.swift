import Foundation

/// Durable record of what we did to the device. A port of `core/mirage/marker.py`.
///
/// The DVT channel is write-only: `simulateLocationWithLatitude:longitude:` sets a
/// location and `stopLocationSimulation` clears it, and nothing reads the current state
/// back. Mirage can therefore never ask a phone whether it is simulating — it can only
/// remember that it made it so.
///
/// That memory is the only thing standing between a user and a device stuck on a false
/// location, so it is treated accordingly:
///
/// - written the moment the *first fix is actually delivered*, not when a session is
///   requested, because a session that never reached the device left nothing to undo;
/// - cleared **only** when a stop is confirmed — never when a notice is dismissed or a
///   session object goes away;
/// - written atomically and fsynced, so a crash between write and flush cannot lose it;
/// - survives the app and the device restarting.
///
/// On iPhone this matters more than on the Mac, not less: the app is suspended and killed
/// routinely, and the user is not sitting in front of a window that could remind them.
public struct MarkerState: Codable, Equatable, Sendable {
    public var active: Bool = false
    public var lat: Double?
    public var lon: Double?
    /// Salted fingerprint, never a raw identifier.
    public var device: String?
    public var since: Date?
    public var restorePending: Bool = false

    public init() {}
}

public final class SimulationMarker {
    public let url: URL
    private var state: MarkerState

    /// `fileProtection` is deliberately *not* `.complete`.
    ///
    /// Complete protection makes a file unreadable while the device is locked — which is
    /// exactly when a background drive is still running and still needs to record that it
    /// delivered a fix. `.completeUntilFirstUserAuthentication` keeps the file encrypted
    /// at rest while remaining readable on a booted, locked phone. The same reasoning
    /// applies to the pairing record.
    private let fileProtection: Data.WritingOptions

    public init(url: URL, protectedAtRest: Bool = true) {
        self.url = url
        #if os(iOS)
        self.fileProtection = protectedAtRest ? [.completeFileProtectionUntilFirstUserAuthentication] : []
        #else
        self.fileProtection = []
        #endif
        self.state = Self.read(url)
    }

    // MARK: - Reading

    public var current: MarkerState { state }
    public var isActive: Bool { state.active }
    public var isRestorePending: Bool { state.restorePending }

    private static func read(_ url: URL) -> MarkerState {
        guard FileManager.default.fileExists(atPath: url.path) else { return MarkerState() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MarkerState.self, from: Data(contentsOf: url))
        } catch {
            // A marker we cannot parse is treated as *active*, not absent. Forgetting
            // that the device may be simulating is the one failure with no recovery, so
            // an unreadable file errs toward telling the user rather than staying quiet.
            var s = MarkerState()
            s.active = true
            return s
        }
    }

    // MARK: - Writing

    /// `udid` is fingerprinted on the way in; the raw value is never persisted.
    ///
    /// Nothing reads it back — the marker only needs to say *that* a device is
    /// simulating, and the fingerprint is enough to tell devices apart if that is ever
    /// needed. Keeping the real identifier would be a permanent, unique device ID sitting
    /// in a file for no functional gain.
    public func markActive(lat: Double, lon: Double, udid: String?) {
        if state.active, state.lat == lat, state.lon == lon {
            return  // unchanged; do not rewrite on every tick
        }
        state.active = true
        state.lat = lat
        state.lon = lon
        state.device = Self.fingerprint(udid)
        if state.since == nil { state.since = Date() }
        write()
    }

    /// Only ever called after a stop the device actually accepted.
    public func markRestored() {
        guard state.active || state.restorePending else { return }
        state = MarkerState()
        write()
    }

    public func requestRestore() {
        guard !state.restorePending else { return }
        state.restorePending = true
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let payload = try? encoder.encode(state) else { return }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: tmp, options: fileProtection)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)

            // fsync before the rename: the whole point of this file is to survive a
            // crash, and an unflushed write would not.
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: - Fingerprint

    /// Stable per-install, non-reversible. Enough to tell two devices apart, useless as an
    /// identifier anywhere else.
    static func fingerprint(_ udid: String?) -> String? {
        guard let udid, !udid.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in Array("mirage-marker/\(udid)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016lx", hash)
    }

    public func describe() -> String {
        guard state.active else { return "no simulated location recorded" }
        let place: String
        if let lat = state.lat, let lon = state.lon {
            // One decimal place is roughly 11 km — enough to say where, not enough to
            // reconstruct where.
            place = String(format: "%.1f, %.1f", lat, lon)
        } else {
            place = "unknown"
        }
        let device = state.device.map { String($0.prefix(8)) } ?? "?"
        return "simulating near \(place) on device \(device)"
    }
}
