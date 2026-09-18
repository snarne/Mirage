import MapKit
import Observation

/// As-you-type address and place suggestions.
///
/// `MKLocalSearchCompleter` is Apple's own autocomplete — the same source the Maps
/// search field uses. It needs no API key, no account, and no third-party service, which
/// also means no query text leaves the machine for anyone but Apple.
///
/// Completions are lightweight: a title and subtitle, with no coordinate. Resolving one
/// to an actual place is a second request, made only when the user picks a suggestion,
/// rather than geocoding every keystroke.
@MainActor
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion

        static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
    }

    private(set) var suggestions: [Suggestion] = []
    private(set) var isSearching = false
    private(set) var failure: String?

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Bias results toward what the user is looking at, so "high street" means the one
    /// on screen rather than one on the other side of the world.
    func update(query: String, near region: MKCoordinateRegion) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            failure = nil
            isSearching = false
            if completer.isSearching { completer.cancel() }
            return
        }
        isSearching = true
        failure = nil
        completer.region = region
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        failure = nil
        isSearching = false
        if completer.isSearching { completer.cancel() }
    }

    /// Turn a chosen suggestion into a real place with coordinates.
    func resolve(_ suggestion: Suggestion) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw CompleterError.noMatch(suggestion.title)
        }
        return item
    }

    enum CompleterError: LocalizedError {
        case noMatch(String)
        var errorDescription: String? {
            switch self {
            case .noMatch(let title): "Could not find a location for \"\(title)\"."
            }
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate
    //
    // MapKit delivers these on the main thread, which is what `assumeIsolated` asserts
    // rather than assumes blindly — it traps if that ever stops being true.

    // The completer argument is not Sendable, so these read `self.completer` from inside
    // the isolated block rather than capturing the parameter. It is the same object.

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.suggestions = self.completer.results.prefix(8).map {
                Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Reduce the error to Sendable values before hopping.
        let ns = error as NSError
        let throttled = ns.domain == MKErrorDomain && ns.code == MKError.loadingThrottled.rawValue
        let message = ns.localizedDescription

        MainActor.assumeIsolated {
            self.isSearching = false
            // A query cancelled by the next keystroke is normal, not a failure.
            guard !throttled else { return }
            self.suggestions = []
            self.failure = message
        }
    }
}
