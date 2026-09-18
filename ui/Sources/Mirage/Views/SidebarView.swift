import MapKit
import MirageKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List {
            Section { ConnectionRow() }

            if model.deviceDirty {
                Section { SimulatedLocationBanner() }
            }

            if model.limitReached && !model.limitAcknowledged {
                Section { SessionLimitNotice() }
            }

            if !model.deviceConnected && model.mode != .idle {
                Section { DisconnectedNotice() }
            }

            Section("Add a place") {
                TextField("Search an address or place", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchQuery) { model.updateSuggestions() }

                if model.completer.isSearching && model.completer.suggestions.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                ForEach(model.completer.suggestions) { suggestion in
                    Button {
                        Task { await model.choose(suggestion) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.circle")
                                .foregroundStyle(.tint)
                                .font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

                if let failure = model.completer.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
                }

                Text("Or click anywhere on the map to drop a pin.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !model.waypoints.isEmpty {
                Section {
                    ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        WaypointRow(
                            waypoint: waypoint,
                            position: index,
                            total: model.waypoints.count)
                    }
                    .onMove { model.moveWaypoints(from: $0, to: $1) }
                    .onDelete { offsets in
                        for i in offsets { model.removeWaypoint(model.waypoints[i].id) }
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text("Trip")
                        Spacer()
                        Button("Save") { model.saveCurrentTrip() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        Button("Clear") { model.clearWaypoints() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }

            if let route = model.plannedRoute {
                Section("Route") { RouteSummary(route: route) }
            } else if model.isPlanning {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Planning route…").font(.system(size: 12))
                    }
                }
            }

            if let error = model.planError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            if model.etaUnachievable {
                Section {
                    Label("This route can't be driven in the estimated time. Mirage is using the fastest plausible drive instead.",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !model.savedTrips.isEmpty {
                Section("Saved") {
                    ForEach(model.savedTrips) { trip in
                        SavedTripRow(trip: trip)
                    }
                }
            }

            Section { ActionButtons() }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "location.viewfinder").foregroundStyle(.tint)
                Text("Mirage").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

struct ConnectionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.connected ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(model.connected ? "Engine connected" : "Engine not running")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if !model.connected {
                Button("Retry") { Task { await model.startUp() } }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }
}

/// One place on the trip. Intermediate waypoints get a dwell control; the start and end
/// do not, because waiting at them is just starting later or arriving earlier.
struct WaypointRow: View {
    @Environment(AppModel.self) private var model
    let waypoint: Waypoint
    let position: Int
    let total: Int

    private var isStart: Bool { position == 0 }
    private var isEnd: Bool { position == total - 1 }
    private var isStop: Bool { !isStart && !isEnd }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(waypoint.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if isStop {
                    HStack(spacing: 6) {
                        Text("Stop for").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { waypoint.stopMinutes },
                            set: { model.setStopMinutes($0, for: waypoint.id) })) {
                            Text("no stop").tag(0)
                            Text("2 min").tag(2)
                            Text("5 min").tag(5)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        .controlSize(.small)
                    }
                } else {
                    Text(isStart ? "Start" : "Destination")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(isEnd ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.18))
                .frame(width: 22, height: 22)
            if isEnd && total > 1 {
                Image(systemName: "flag.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
            } else {
                Text("\(position + 1)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct RouteSummary: View {
    let route: PlannedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill").font(.system(size: 11)).foregroundStyle(.tint)
                Text(format(route.drivingTime) + " driving")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            if route.stopTime > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(format(route.stopTime) + " stopped")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Divider().padding(.vertical, 2)
                Text(format(route.totalTime) + " total")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            Text(String(format: "%.1f km · %d leg%@ · avg %d km/h",
                        route.distance / 1000, route.legCount,
                        route.legCount == 1 ? "" : "s", Int(route.averageSpeedKPH)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t.rounded()) / 60
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}

struct ActionButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.startDrive() }
            } label: {
                busyLabel("Start Drive", systemImage: "play.fill", whileDoing: "Starting drive")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canDrive || model.busy != nil)

            if let reason = model.driveBlockedReason, !model.waypoints.isEmpty {
                blockedReason(reason)
            }

            Button {
                Task { await model.pinFirstWaypoint() }
            } label: {
                busyLabel("Hold This Location", systemImage: "mappin", whileDoing: "Setting location")
            }
            .controlSize(.large)
            .disabled(!model.canPin || model.busy != nil)

            if let reason = model.pinBlockedReason, !model.waypoints.isEmpty {
                blockedReason(reason)
            }

            // Never disabled on `mode`. If a previous run died while simulating, this
            // app believes it is idle while the device is not — and that is precisely
            // when someone needs this button most.
            Button(role: .destructive) {
                Task { await model.restore() }
            } label: {
                Label("Restore Real Location", systemImage: "location.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.connected || model.busy != nil)

            Text("Safe to press at any time, even if Mirage shows nothing running.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.waypoints.count == 1 {
                Text("Add another place to plan a drive, or hold this one as a static location.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func busyLabel(_ title: String, systemImage: String, whileDoing: String) -> some View {
        if model.busy == whileDoing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(whileDoing + "…")
            }
            .frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }

    /// A disabled control should never be a mystery.
    private func blockedReason(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}


/// Persistent statement that the phone is reporting a simulated location.
///
/// Driven by the engine's durable marker, which is written when a fix is actually
/// delivered and cleared **only** when a stop is confirmed. Deliberately **not
/// dismissible**: the previous version cleared its flag when the user dismissed it, so
/// Mirage forgot the device was simulating and could never offer to undo it again. This
/// disappears when the location is genuinely restored, and not before.
struct SimulatedLocationBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.accentColor, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your iPhone is reporting a simulated location")
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await model.restore() }
            } label: {
                if model.busy == "Restoring real location" {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Restoring…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Restore Real Location", systemImage: "location.slash.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.connected || model.busy != nil)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if model.restorePending {
            return "A restore is queued. Mirage will complete it as soon as the iPhone reconnects."
        }
        if !model.deviceConnected {
            return "The iPhone is not reachable. Reconnect it to restore, or restart the phone."
        }
        return model.mode == .idle
            ? "This continues until you restore it, or the iPhone restarts."
            : "A session is running."
    }
}

struct SavedTripRow: View {
    @Environment(AppModel.self) private var model
    let trip: SavedTrip
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: trip.isDrive ? "car.fill" : "mappin")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        model.renameTrip(trip.id, to: draftName)
                        isRenaming = false
                    }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(trip.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(.rect)
        .onTapGesture { model.loadTrip(trip) }
        .contextMenu {
            Button("Load") { model.loadTrip(trip) }
            Button("Rename…") { draftName = trip.name; isRenaming = true }
            Divider()
            Button("Delete", role: .destructive) { model.deleteTrip(trip.id) }
        }
    }

    private var subtitle: String {
        let places = trip.waypoints.count
        let stops = max(0, places - 2)
        let base = trip.isDrive ? "\(places) places" : "single location"
        return stops > 0 ? "\(base) · \(stops) stop\(stops == 1 ? "" : "s")" : base
    }
}


/// The consented session length elapsed. Mirage has stopped advancing the journey and is
/// holding the position — it has not restored anything, and will not without being asked.
struct SessionLimitNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "timer")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Session length reached")
                    .font(.system(size: 12, weight: .medium))
                Text("Mirage is holding the current position. Nothing has been restored — your iPhone still reports this location until you decide.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Restore Real Location") {
                        Task {
                            await model.restore()
                            model.acknowledgeLimit()
                        }
                    }
                    .controlSize(.small)
                    Button("Keep Holding") { model.acknowledgeLimit() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
    }
}

/// The phone is unreachable mid-journey. This is explicitly not an error state: the
/// trajectory is driven by the clock, so the drive continues and the first fix after
/// reconnecting is wherever the driver would be by then.
struct DisconnectedNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("iPhone not reachable")
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String {
        let away = Int(model.unreachableFor)
        let elapsed = away > 60 ? "\(away / 60) min" : "\(away)s"
        return model.mode == .driving
            ? "The drive is still running (\(elapsed) without a connection). When the iPhone reconnects it picks up wherever you would be by then."
            : "Your iPhone keeps reporting its last position (\(elapsed) without a connection). Reconnect it to change or restore the location."
    }
}
