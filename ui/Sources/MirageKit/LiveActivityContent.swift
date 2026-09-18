import Foundation

/// What the Live Activity shows, derived from `SessionState`.
///
/// Deliberately free of ActivityKit so it can be tested on any platform — the widget is a
/// thin renderer over this. It also does a second job beyond keeping a drive alive: a Live
/// Activity is visible on the Lock Screen whether or not Mirage is open, with Restore
/// right there. On the Mac the equivalent is a banner you have to open the app to see.
/// This is the stronger version of the same invariant `SimulationMarker` protects.
public struct LiveActivityContent: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        case driving
        case holding
        /// Session length elapsed. Still simulating; nothing has been restored.
        case held
        /// The journey continues but fixes are not reaching the phone.
        case disconnected
    }

    public var kind: Kind
    public var destination: String?
    public var nextStop: String?
    /// Metres per second, as the engine produces it. Converted only at the point of
    /// display, so the trajectory maths never sees a unit preference.
    public var speed: Double
    public var units: UnitSystem
    public var progress: Double
    public var etaRemaining: TimeInterval
    public var unreachableFor: TimeInterval

    public init(kind: Kind, destination: String? = nil, nextStop: String? = nil,
                speed: Double = 0, units: UnitSystem = .deviceDefault,
                progress: Double = 0,
                etaRemaining: TimeInterval = 0, unreachableFor: TimeInterval = 0) {
        self.kind = kind
        self.destination = destination
        self.nextStop = nextStop
        self.speed = speed
        self.units = units
        self.progress = progress
        self.etaRemaining = etaRemaining
        self.unreachableFor = unreachableFor
    }

    public init(state: SessionState, units: UnitSystem = .deviceDefault,
                destination: String? = nil, nextStop: String? = nil) {
        let kind: Kind
        if !state.deviceConnected {
            kind = .disconnected
        } else if state.limitReached {
            kind = .held
        } else if state.mode == .driving {
            kind = .driving
        } else {
            kind = .holding
        }
        self.init(kind: kind,
                  destination: destination,
                  nextStop: nextStop,
                  speed: state.speed,
                  units: units,
                  progress: state.progress,
                  etaRemaining: state.etaRemaining,
                  unreachableFor: state.unreachableFor)
    }

    // MARK: - Display

    /// The bold line.
    public var title: String {
        switch kind {
        case .driving:
            if let destination { return "Driving to \(destination)" }
            return "Driving"
        case .holding:
            if let destination { return "Location held · \(destination)" }
            return "Location held"
        case .held:
            return "Session length reached"
        case .disconnected:
            return "iPhone not reachable"
        }
    }

    /// The quieter line under it. Never claims something was restored.
    public var subtitle: String {
        switch kind {
        case .driving:
            var parts = [units.speed(speed)]
            if let nextStop { parts.append("next stop \(nextStop)") }
            return parts.joined(separator: " · ")
        case .holding:
            return "Find My shows the simulated location"
        case .held:
            return "Still simulating — nothing has been restored"
        case .disconnected:
            return "Still simulating. The drive continues on the clock."
        }
    }

    /// Compact Dynamic Island label: short enough for the pill.
    public var compactLabel: String {
        switch kind {
        case .driving: return Self.shortDuration(etaRemaining)
        case .holding: return "Held"
        case .held: return "Held"
        case .disconnected: return "Offline"
        }
    }

    public var showsProgress: Bool { kind == .driving }

    /// Restore is offered in every state, including the ones where Mirage believes nothing
    /// is running — that belief is exactly what can be wrong.
    public var showsRestore: Bool { true }

    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
