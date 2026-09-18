import Foundation

/// Fetches drivable ways from OpenStreetMap via the Overpass API.
///
/// Free, no key, no billing, and ODbL-licensed — none of the "display only on our own map"
/// restrictions that make the commercial traffic APIs awkward to build a location simulator
/// on. The trade is that Overpass is a volunteer-run service: one query per planned route is
/// courteous, one per tick would not be.
///
/// Failure is never fatal. A route with no speed data falls back to the vehicle ceiling,
/// which is exactly how the engine behaved before this existed.
public enum OverpassClient {

    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Drivable road classes only. Footpaths and cycleways would snap a car onto a pavement.
    static let drivable = """
        motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|\
        service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link
        """

    public enum Failure: Error, CustomStringConvertible {
        case badResponse(Int)
        case transport(String)

        public var description: String {
            switch self {
            case .badResponse(let code):
                "Overpass returned HTTP \(code). It is a shared, volunteer-run service and "
                + "rate-limits under load; the drive will use default speeds instead."
            case .transport(let message):
                "Could not reach Overpass: \(message)"
            }
        }
    }

    /// Every drivable way within `margin` metres of the route's bounding box.
    public static func ways(
        around polyline: Polyline,
        margin: Double = 150,
        endpoint: URL = defaultEndpoint,
        timeout: TimeInterval = 30
    ) async throws -> [OSMWay] {
        let lats = polyline.points.map(\.lat)
        let lons = polyline.points.map(\.lon)
        let latMargin = margin / 111_132.0
        let midLat = ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2
        let lonMargin = margin / max(1, 111_320.0 * cos(midLat * .pi / 180))

        let bbox = String(
            format: "%.6f,%.6f,%.6f,%.6f",
            (lats.min() ?? 0) - latMargin, (lons.min() ?? 0) - lonMargin,
            (lats.max() ?? 0) + latMargin, (lons.max() ?? 0) + lonMargin)

        let query = """
            [out:json][timeout:\(Int(timeout))];
            way["highway"~"^(\(drivable))$"](\(bbox));
            out geom tags;
            """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Overpass asks that clients identify themselves.
        request.setValue("Mirage/1.0 (location simulator; github.com/snarne/Mirage)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }

        return try decode(data)
    }

    /// Split out so it can be tested against a recorded payload with no network.
    public static func decode(_ data: Data) throws -> [OSMWay] {
        struct Response: Decodable {
            struct Element: Decodable {
                struct Point: Decodable { let lat: Double; let lon: Double }
                let geometry: [Point]?
                let tags: [String: String]?
            }
            let elements: [Element]
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.elements.compactMap { element in
            guard let geometry = element.geometry, geometry.count >= 2 else { return nil }
            return OSMWay(
                geometry: geometry.map { LatLon($0.lat, $0.lon) },
                maxspeed: element.tags?["maxspeed"],
                highway: element.tags?["highway"])
        }
    }

    /// Speed ceilings for a route, or nil when OSM cannot be reached.
    ///
    /// Callers pass the result straight to `buildPlan(roadLimits:)`, and nil simply means
    /// the drive runs on the vehicle ceiling as it always did.
    public static func speedLimits(for polyline: Polyline) async -> [Double]? {
        do {
            let ways = try await ways(around: polyline)
            guard !ways.isEmpty else { return nil }
            return SpeedLimits.limits(for: polyline, ways: ways)
        } catch {
            return nil
        }
    }
}
