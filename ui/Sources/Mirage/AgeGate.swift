import SwiftUI
#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif

/// Age and parental-control verification.
///
/// On macOS 26+ this uses Apple's `DeclaredAgeRange`, which answers from the user's
/// Apple Account rather than from a checkbox, and — critically for this app — reports
/// whether **parental controls are active on the account**. That single signal is the
/// one that matters: it identifies a supervised account directly, instead of asking a
/// minor to self-report.
///
/// Below macOS 26 the framework does not exist. Rather than silently degrade, the
/// fallback records `source: "unavailable"` and the UI says plainly that verification
/// was not Apple-attested.
struct AgeVerification: Sendable, Equatable {
    var meetsThreshold: Bool
    var threshold: Int = 18
    var lowerBound: Int?
    var upperBound: Int?
    var declaration: String = "unknown"
    var parentalControlsActive: Bool = false
    var source: String = "unavailable"

    /// Nil when the user may proceed.
    var blockingReason: String? {
        if parentalControlsActive {
            return "Parental controls are active on this Apple Account. "
                 + "Mirage does not run on supervised accounts."
        }
        if !meetsThreshold {
            return "This Apple Account is not declared as \(threshold) or older."
        }
        return nil
    }

    var isAppleAttested: Bool { source == "DeclaredAgeRange" }

    /// Self-attested fallback, used when Apple's age service is unavailable.
    ///
    /// Weaker than the Apple path and labelled as such everywhere it is shown. It is
    /// not the control that carries weight — the device eligibility check is — but it
    /// keeps the app usable for anyone building from source, and records honestly which
    /// method was used.
    static func selfAttested(birthDate: Date, threshold: Int = 18) -> AgeVerification {
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
        return AgeVerification(
            meetsThreshold: years >= threshold,
            threshold: threshold,
            lowerBound: years >= threshold ? threshold : nil,
            upperBound: years >= threshold ? nil : threshold,
            declaration: "selfDeclared",
            parentalControlsActive: false,
            source: "self-attested")
    }

    var summary: String {
        guard isAppleAttested else { return "Not verified by Apple" }
        let bounds: String
        switch (lowerBound, upperBound) {
        case let (l?, u?): bounds = "\(l)–\(u)"
        case let (l?, nil): bounds = "\(l)+"
        case let (nil, u?): bounds = "under \(u)"
        default: bounds = "unknown"
        }
        return "Apple Account age range \(bounds), \(declaration)"
    }
}

enum AgeGate {
    static var isSupported: Bool {
        #if canImport(DeclaredAgeRange)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Ask the platform, with a bound on how long we will wait.
    ///
    /// The service can hang rather than fail when it is not available to the calling
    /// binary, so this races it against a timeout. Blocking setup forever is worse than
    /// falling back to the date-of-birth path.
    static func verify(
        threshold: Int = 18,
        timeout: Duration = .seconds(20)
    ) async throws -> AgeVerification {
        enum Outcome: Sendable {
            case answered(AgeVerification)
            case timedOut
        }

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { .answered(try await requestFromApple(threshold: threshold)) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else { throw AgeGateError.unsupported }
            switch first {
            case .answered(let verification):
                return verification
            case .timedOut:
                throw AgeGateError.unavailable(
                    "Apple's age service did not respond. This usually means the app is "
                    + "not signed with an Apple Developer ID.")
            }
        }
    }

    @MainActor
    private static func requestFromApple(threshold: Int) async throws -> AgeVerification {
        #if canImport(DeclaredAgeRange)
        if #available(macOS 26.0, *) {
            let response = try await AgeRangeService.shared.requestAgeRange(
                ageGates: threshold, in: keyWindow())
            switch response {
            case .declinedSharing:
                return AgeVerification(
                    meetsThreshold: false, threshold: threshold,
                    declaration: "declinedSharing", source: "DeclaredAgeRange")
            case .sharing(let range):
                // lowerBound is the floor of the bracket the account falls in, so
                // "18 or older" is exactly lowerBound >= threshold.
                let meets = (range.lowerBound ?? 0) >= threshold
                return AgeVerification(
                    meetsThreshold: meets,
                    threshold: threshold,
                    lowerBound: range.lowerBound,
                    upperBound: range.upperBound,
                    declaration: range.ageRangeDeclaration.map { String(describing: $0) }
                        ?? "unspecified",
                    parentalControlsActive: !range.activeParentalControls.isEmpty,
                    source: "DeclaredAgeRange")
            @unknown default:
                return AgeVerification(meetsThreshold: false, threshold: threshold,
                                       declaration: "unknown", source: "DeclaredAgeRange")
            }
        }
        #endif
        throw AgeGateError.unsupported
    }

    @MainActor
    private static func keyWindow() -> NSWindow {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }

    enum AgeGateError: LocalizedError {
        case unsupported
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "Apple's age verification requires macOS 26 or later."
            case .unavailable(let detail):
                detail
            }
        }
    }

    /// Turn the framework's opaque errors into something a person can act on.
    /// `AgeRangeService.Error` is a two-case enum whose raw codes reach us as 0 and 1.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain.contains("DeclaredAgeRange") {
            switch ns.code {
            case 0:
                return "Apple's age verification is not available to this build of Mirage. "
                     + "The service requires an app signed with an Apple Developer ID; this "
                     + "one is ad-hoc signed. Use the date-of-birth option below instead."
            case 1:
                return "Apple rejected the age verification request."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
