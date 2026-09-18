import Foundation
import MapKit
import MirageKit
import MirageDevice

/// Does to the real stack what `scripts/check-device.sh` does to the Python engine: proves
/// it works on *this* device, rather than proving it compiles.
///
///     swift run mirage-device-check                        # hold a pin, then restore
///     swift run mirage-device-check --drive                # route and drive it
///     swift run mirage-device-check --drive --from "Ferry Building, San Francisco" \
///                                           --to "Oakland Museum"
///     swift run mirage-device-check --restore-only         # clear whatever is set
///
/// The route comes from `MKDirections` with `departureDate` set, exactly as
/// `RouteService.swift` does it in the app. That matters twice over: the polyline follows
/// real roads instead of cutting across blocks, and `expectedTravelTime` is **traffic
/// aware**, so the trajectory is scaled to how long the drive actually takes right now
/// rather than to a number someone made up.

let defaultFrom = "Ferry Building, San Francisco"
let defaultTo = "Golden Gate Park, San Francisco"

enum Mode { case pin, drive, restoreOnly }

var mode = Mode.pin
var holdSeconds: Int = 30
var fromQuery = defaultFrom
var toQuery = defaultTo
/// Only ever an override. Left nil, Apple's traffic-aware estimate is used, which is the
/// entire point.
var etaOverride: Double?
/// Skips the OSM lookup, for comparing against the old behaviour.
var noLimits = false
/// What the numbers below are printed in. Follows the Mac's region unless overridden,
/// the same rule the apps use.
var units = UnitSystem.deviceDefault

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func value(_ name: String) -> String {
        guard let v = args.first else {
            FileHandle.standardError.write(Data("\(name) needs a value\n".utf8)); exit(2)
        }
        args.removeFirst(); return v
    }
    switch arg {
    case "--drive": mode = .drive
    case "--restore-only": mode = .restoreOnly
    case "--no-limits": noLimits = true
    case "--from": fromQuery = value("--from")
    case "--to": toQuery = value("--to")
    case "--hold": holdSeconds = Int(value("--hold")) ?? 30
    case "--eta": etaOverride = Double(value("--eta"))
    case "--units":
        let raw = value("--units").lowercased()
        guard let chosen = UnitSystem(rawValue: raw) else {
            FileHandle.standardError.write(Data("--units takes metric or imperial\n".utf8)); exit(2)
        }
        units = chosen
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8)); exit(2)
    }
}

func note(_ s: String) { print(s); fflush(stdout) }

func fail(_ message: String, remedy: String? = nil) -> Never {
    FileHandle.standardError.write(Data("\n[x] \(message)\n".utf8))
    if let remedy { FileHandle.standardError.write(Data("  \(remedy)\n".utf8)) }
    FileHandle.standardError.write(Data(
        "\n  If a location was set, clear it with:  swift run mirage-device-check --restore-only\n".utf8))
    exit(1)
}

let markerURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mirage", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("device-check.json")
}()

nonisolated(unsafe) var activeSession: DriveSession?
nonisolated(unsafe) var interruptSource: DispatchSourceSignal?

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

/// Same shape as `RouteService.route(through:)`, trimmed to two points.
func planRoute(from: String, to: String) async throws -> (route: [LatLon], seconds: Double,
                                                          metres: Double, fromName: String,
                                                          toName: String) {
    func find(_ query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NSError(domain: "mirage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "nothing found for \"\(query)\""])
        }
        return item
    }

    let source = try await find(from)
    let destination = try await find(to)

    let request = MKDirections.Request()
    request.source = source
    request.destination = destination
    request.transportType = .automobile
    // Without this, expectedTravelTime is free-flow and traffic is invisible.
    request.departureDate = Date()

    let response = try await MKDirections(request: request).calculate()
    guard let leg = response.routes.first else {
        throw NSError(domain: "mirage", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "no driving route between those places"])
    }

    let coords = leg.polyline.coordinates
        .filter { CLLocationCoordinate2DIsValid($0) }
        .map { LatLon($0.latitude, $0.longitude) }

    return (coords, leg.expectedTravelTime, leg.distance,
            source.name ?? from, destination.name ?? to)
}

@MainActor
func connect() -> DriveSession {
    let marker = SimulationMarker(url: markerURL)
    if marker.isActive {
        note("! a previous run left a location set - \(marker.describe())")
        note("  it will be cleared when this run restores.\n")
    }
    let session = DriveSession(injector: IdeviceInjector(), marker: marker, tickInterval: 1.0)
    activeSession = session
    return session
}

func installInterruptHandler() {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            FileHandle.standardError.write(Data("\n\ninterrupted - restoring before exit\n".utf8))
            guard let session = activeSession else { exit(130) }
            do {
                try await session.restore()
                FileHandle.standardError.write(Data("restored.\n".utf8))
                exit(130)
            } catch {
                FileHandle.standardError.write(Data("""
                    [x] could not restore: \(error)

                      Your iPhone is STILL reporting a simulated location.
                      Run:  swift run mirage-device-check --restore-only
                      Or reboot the phone, which clears it unconditionally.

                    """.utf8))
                exit(1)
            }
        }
    }
    source.resume()
    interruptSource = source
}

@MainActor
func restore(_ session: DriveSession) async {
    note("-> restoring")
    do {
        try await session.restore()
        note("   restored. Confirm Find My shows your real location before walking away.")
    } catch {
        fail("could not clear the location: \(error)",
             remedy: "Your iPhone is still reporting a simulated position. Reconnect it and run with --restore-only, or reboot the phone.")
    }
    try? await session.close()
}

@MainActor
func runPin(_ session: DriveSession) async {
    let here = LatLon(64.1466, -21.9426)   // Reykjavík: obviously not where you are
    note("-> holding \(here.lat), \(here.lon) for \(holdSeconds)s")
    do {
        try await session.pin(lat: here.lat, lon: here.lon)
    } catch {
        fail("could not set the location: \(error)")
    }
    for _ in 0..<holdSeconds {
        await session.tick()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    note("   held. Drift kept it moving - a perfectly static coordinate is the loudest tell there is.")
    await restore(session)
}

@MainActor
func runDrive(_ session: DriveSession) async {
    note("-> routing \"\(fromQuery)\" to \"\(toQuery)\" via MapKit")

    let planned: (route: [LatLon], seconds: Double, metres: Double,
                  fromName: String, toName: String)
    do {
        planned = try await planRoute(from: fromQuery, to: toQuery)
    } catch {
        fail("could not plan a route: \(error.localizedDescription)",
             remedy: "Try different place names, or check this Mac's network connection.")
    }

    let poly: Polyline
    do {
        poly = try Polyline(planned.route)
    } catch {
        fail("MapKit returned a route Mirage cannot use: \(error)")
    }

    // Free, no key, ODbL. A failure here is not fatal: nil means the drive falls back to
    // the vehicle ceiling, exactly as it behaved before speed limits existed.
    note("-> fetching speed limits from OpenStreetMap")
    let roadLimits = noLimits ? nil : await OverpassClient.speedLimits(for: poly)
    if let roadLimits {
        let known = roadLimits.filter { $0 > 0 }
        let coverage = Int(Double(known.count) / Double(roadLimits.count) * 100)
        let slowest = String(format: "%.0f", units.speedValue(metresPerSecond: known.min() ?? 0))
        let fastest = units.speed(known.max() ?? 0)
        note("   \(coverage)% of the route has a known limit, \(slowest)-\(fastest)")
    } else {
        note("   none available - falling back to the vehicle ceiling")
    }

    let eta = etaOverride ?? planned.seconds
    let plan = buildPlan(poly, expectedTravelTime: eta, roadLimits: roadLimits)

    let distance = units.distance(plan.distance)
    let avg = units.speed(plan.distance / max(plan.totalTime, 1))
    note("""
       \(planned.fromName) -> \(planned.toName)
       \(distance) over \(poly.count) road points, \(Int(plan.totalTime))s, averaging \(avg)
       \(etaOverride == nil ? "Apple's estimate, traffic-aware (departureDate set)" : "ETA overridden to \(Int(eta))s")
    """)
    if !plan.etaAchievable {
        note("   ! that estimate is faster than this route can physically be driven;")
        note("     clamped to the speed ceiling and re-solved.")
    }

    do {
        try await session.drive(plan)
    } catch {
        fail("could not start the drive: \(error)")
    }

    note("\n-> driving. Watch Find My move.\n")

    var lastReport = -5.0
    var maxSpeed = 0.0
    while true {
        let state = await session.tick()
        maxSpeed = max(maxSpeed, state.speed)

        if state.elapsed - lastReport >= 5 || state.mode == .pinned {
            lastReport = state.elapsed
            let pos = state.lat.map { String(format: "%.4f, %.4f", $0, state.lon ?? 0) } ?? "-"
            let offline = state.deviceConnected ? "" : "   [phone unreachable - drive continues]"
            // %@ with a width is unreliable across Foundation versions, so the speed
            // column is padded here rather than by the format string.
            let speed = units.speed(state.speed, decimals: 1)
            let column = String(repeating: " ", count: max(0, 9 - speed.count)) + speed
            note(String(format: "   %4ds  %3d%%  ", Int(state.elapsed), Int(state.progress * 100))
                 + "\(column)  \(pos)\(offline)")
        }

        if state.mode == .pinned && state.progress >= 1.0 { break }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    note("""

       arrived. Peak \(units.speed(maxSpeed)), average \(avg).
       Holding the destination with stationary drift rather than stopping dead.

       The speed column should have varied - slowing into turns, picking up on straights.
       A flat number means the corner and acceleration limits are not engaging.
    """)
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    await restore(session)
}

@MainActor
func main() async {
    installInterruptHandler()

    note("-> connecting")
    let session = connect()
    do {
        try await session.restore()   // opens the channel, and clears anything stale
    } catch {
        fail("could not reach the iPhone: \(error)",
             remedy: """
             Check, in this order:
               1. The iPhone is plugged in and unlocked, and you have tapped Trust.
               2. Developer Mode is on: Settings > Privacy & Security > Developer Mode.
               3. A Developer Disk Image is mounted. Opening the device once in Xcode
                  mounts one.
             """)
    }
    note("   connected")

    switch mode {
    case .restoreOnly:
        note("-> cleared. The iPhone is back on real GPS.")
        try? await session.close()
    case .pin:
        await runPin(session)
    case .drive:
        await runDrive(session)
    }
}

await main()
