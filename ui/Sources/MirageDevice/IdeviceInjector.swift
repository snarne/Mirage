import Foundation
import MirageKit
import CMirageIdevice

/// How Mirage reaches the device it is going to move.
///
/// The two cases differ only in their first hop. Past that both run the same chain —
/// CoreDeviceProxy, a software tunnel, the RSD handshake, then the developer-tools
/// channel — so everything above this file is identical on the Mac and on the phone.
public enum DeviceTransport: Sendable {
    /// usbmuxd. `udid` nil takes the only device present. The Mac app.
    case usb(udid: String?)

    /// A paired host over TCP. On the phone that host is the phone itself, reached
    /// through a loopback VPN.
    ///
    /// The VPN is not decoration. `lockdownd` refuses connections from `127.0.0.1`, so an
    /// app cannot dial its own device directly. Routed through the VPN's `tun` interface
    /// the packets arrive with an ordinary source address and the app is treated like any
    /// other paired computer — which, holding the pairing file, it is.
    ///
    /// - Parameters:
    ///   - address: the VPN's peer address. LocalDevVPN hands out `10.7.0.1`.
    ///   - pairingFile: the credential exported from the Mac during setup.
    ///   - developerImage: a folder holding `Image.dmg`, a `.trustcache` and
    ///     `BuildManifest.plist`. Mirage mounts it when the device has no image, which is
    ///     after every restart. Without it the phone needs the Mac again each time.
    case loopback(address: String, pairingFile: URL, developerImage: URL?)

    /// The usual Mac case: whichever device is plugged in.
    public static var anyDevice: DeviceTransport { .usb(udid: nil) }
}

/// `LocationInjector` backed by `idevice`.
///
/// This is the real counterpart to `MockInjector`. `DriveSession` knows only the four-call
/// protocol, so swapping this in changes nothing above it — the trajectory engine, the
/// marker, the Live Activity and all of their tests are untouched.
///
/// ## What it talks to
///
/// `com.apple.instruments.server.services.LocationSimulation`, the DTX channel, over
/// RemoteXPC. Not `com.apple.dt.simulatelocation`, which is the pre-iOS-17 lockdown
/// service; modern devices answer that one with `InvalidService`. The Python engine on
/// the Mac drives the same channel through `pymobiledevice3`, so the two implementations
/// agree on the transport and not merely on the arithmetic.
///
/// ## Threading
///
/// The C calls block. `LocationInjector` is `@MainActor`, so every call hops to a private
/// serial queue and suspends — the main thread is never blocked, and the device handle is
/// only ever touched from one thread, which the Rust side requires.
public final class IdeviceInjector: LocationInjector {

    /// Boxed so the pointer never crosses an actor boundary loose. Only touched on `queue`.
    private final class Handle: @unchecked Sendable {
        var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    }

    private let handle = Handle(nil)
    private let queue = DispatchQueue(label: "app.mirage.idevice", qos: .userInitiated)
    private let transport: DeviceTransport

    public init(transport: DeviceTransport = .usb(udid: nil)) {
        self.transport = transport
    }

    /// Convenience for the Mac, where the only question is which device.
    public convenience init(udid: String?) {
        self.init(transport: .usb(udid: udid))
    }

    deinit {
        // Closing does not clear the location — see the header. A position outliving the
        // process is documented behaviour, and undoing it here would hide it.
        if let pointer = handle.pointer {
            mirage_idevice_close(pointer)
        }
    }

    // MARK: - LocationInjector

    public func open() async throws {
        let transport = self.transport
        let handle = self.handle
        try await onQueue {
            guard handle.pointer == nil else { return }   // already open; opening twice is a no-op
            var error: UnsafeMutablePointer<CChar>?
            let opened = Self.connect(transport, &error)
            guard let opened else { throw Self.failure(error, fallback: "could not reach the iPhone") }
            handle.pointer = opened
        }
    }

    public func set(lat: Double, lon: Double) async throws {
        let handle = self.handle
        try await onQueue {
            guard let pointer = handle.pointer else { throw IdeviceError.notOpen }
            var error: UnsafeMutablePointer<CChar>?
            if mirage_idevice_set(pointer, lat, lon, &error) != MIRAGE_OK {
                throw Self.failure(error, fallback: "could not set the location")
            }
        }
    }

    public func clear() async throws {
        let handle = self.handle
        try await onQueue {
            // Never opens implicitly: restore() calls open() then clear(), and a clear on a
            // closed handle here would silently claim success.
            guard let pointer = handle.pointer else { throw IdeviceError.notOpen }
            var error: UnsafeMutablePointer<CChar>?
            if mirage_idevice_clear(pointer, &error) != MIRAGE_OK {
                throw Self.failure(error, fallback: "could not clear the location")
            }
        }
    }

    public func close() async throws {
        let handle = self.handle
        try await onQueue {
            if let pointer = handle.pointer {
                mirage_idevice_close(pointer)
                handle.pointer = nil
            }
        }
    }

    // MARK: - Plumbing

    /// `nonisolated` for the same reason `failure` is: this runs on the serial queue, and
    /// conforming to the `@MainActor` protocol would otherwise isolate it.
    private nonisolated static func connect(
        _ transport: DeviceTransport,
        _ error: inout UnsafeMutablePointer<CChar>?
    ) -> OpaquePointer? {
        switch transport {
        case .usb(let udid):
            return udid.withCStringOrNil { mirage_idevice_open($0, &error) }

        case .loopback(let address, let pairingFile, let developerImage):
            // Rust reads these as paths, so they must be file-system representations and
            // not URL strings — a `file://` prefix would simply not open.
            let pairingPath = pairingFile.path(percentEncoded: false)
            let imagePath = developerImage?.path(percentEncoded: false)
            return address.withCString { cAddress in
                pairingPath.withCString { cPairing in
                    imagePath.withCStringOrNil { cImage in
                        mirage_idevice_open_loopback(cAddress, cPairing, cImage, &error)
                    }
                }
            }
        }
    }

    private func onQueue(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Takes ownership of the Rust-allocated message and frees it.
    /// `nonisolated` because conforming to the @MainActor `LocationInjector` isolates the
    /// whole type, and this is called from the background queue. It touches no state.
    private nonisolated static func failure(_ raw: UnsafeMutablePointer<CChar>?, fallback: String) -> Error {
        guard let raw else { return IdeviceError.failed(fallback) }
        defer { mirage_idevice_string_free(raw) }
        return IdeviceError.failed(String(cString: raw))
    }
}

public enum IdeviceError: Error, CustomStringConvertible {
    case notOpen
    case failed(String)

    public var description: String {
        switch self {
        case .notOpen: return "the device connection is not open"
        case .failed(let message): return message
        }
    }
}

private extension Optional where Wrapped == String {
    /// Calls `body` with a C string, or NULL when nil — which the Rust side reads as
    /// "the only device present", or "no developer disk image to mount".
    func withCStringOrNil<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .none: return body(nil)
        case .some(let s): return s.withCString { body($0) }
        }
    }
}
