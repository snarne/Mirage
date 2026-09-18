import Foundation
import MapKit
import MirageKit

/// A place on the trip. The first is where the drive starts, the last where it ends,
/// and anything between is a stop.
struct Waypoint: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// How long to wait here. Only meaningful for intermediate waypoints.
    var stopMinutes: Int = 5

    static func == (a: Waypoint, b: Waypoint) -> Bool { a.id == b.id }

    /// Persistable form. Identity is deliberately not carried across: a reloaded trip is
    /// a new set of waypoints, not the same objects resurrected.
    var saved: SavedWaypoint {
        SavedWaypoint(name: name,
                      latitude: coordinate.latitude,
                      longitude: coordinate.longitude,
                      stopMinutes: stopMinutes)
    }
}

/// A route through every waypoint, with the stops located on the combined polyline.
struct PlannedRoute {
    let coordinates: [CLLocationCoordinate2D]
    /// Sum of the legs' traffic-aware estimates. Driving only — it excludes the time
    /// the user chose to spend at stops.
    let drivingTime: TimeInterval
    let distance: CLLocationDistance
    /// Vertex index into `coordinates` → seconds to wait there.
    let stops: [(index: Int, seconds: Double)]
    let legCount: Int

    var polyline: MKPolyline { MKPolyline(coordinates: coordinates, count: coordinates.count) }

    var stopTime: TimeInterval { stops.reduce(0) { $0 + $1.seconds } }
    var totalTime: TimeInterval { drivingTime + stopTime }

    var averageSpeedKPH: Double {
        drivingTime > 0 ? (distance / drivingTime) * 3.6 : 0
    }
}

enum RouteService {

    /// Route through every waypoint in order.
    ///
    /// `MKDirections` handles one origin and one destination, so a multi-stop trip is a
    /// chain of legs stitched together. Each leg's `expectedTravelTime` is traffic-aware
    /// because `departureDate` is set, and summing them gives a traffic-aware total.
    static func route(through waypoints: [Waypoint]) async throws -> PlannedRoute {
        guard waypoints.count >= 2 else { throw RouteError.notEnoughWaypoints }

        var coordinates: [CLLocationCoordinate2D] = []
        var stops: [(index: Int, seconds: Double)] = []
        var drivingTime: TimeInterval = 0
        var distance: CLLocationDistance = 0

        for (i, pair) in zip(waypoints, waypoints.dropFirst()).enumerated() {
            let (from, to) = pair

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
            request.transportType = .automobile
            // Without this, expectedTravelTime is free-flow and traffic is invisible.
            request.departureDate = Date()

            let response = try await MKDirections(request: request).calculate()
            guard let leg = response.routes.first else {
                throw RouteError.noRoute(from: from.name, to: to.name)
            }

            let legCoords = leg.polyline.coordinates
            // The first point of each subsequent leg repeats the previous leg's last.
            coordinates.append(contentsOf: i == 0 ? legCoords : Array(legCoords.dropFirst()))
            drivingTime += leg.expectedTravelTime
            distance += leg.distance

            // `to` is an intermediate waypoint unless it is the final destination.
            let isIntermediate = (i + 2) < waypoints.count
            if isIntermediate, to.stopMinutes > 0, !coordinates.isEmpty {
                stops.append((index: coordinates.count - 1, seconds: Double(to.stopMinutes) * 60))
            }
        }

        guard coordinates.count >= 2 else { throw RouteError.notEnoughWaypoints }

        return PlannedRoute(
            coordinates: coordinates,
            drivingTime: drivingTime,
            distance: distance,
            stops: stops,
            legCount: waypoints.count - 1)
    }

    /// Reverse-geocode a dropped pin so it gets a readable name rather than raw numbers.
    static func describe(_ coordinate: CLLocationCoordinate2D) async -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let parts = [placemark.name, placemark.locality].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    enum RouteError: LocalizedError {
        case notEnoughWaypoints
        case noRoute(from: String, to: String)

        var errorDescription: String? {
            switch self {
            case .notEnoughWaypoints:
                "Add at least two places to plan a drive."
            case .noRoute(let from, let to):
                "No driving route from \(from) to \(to)."
            }
        }
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
