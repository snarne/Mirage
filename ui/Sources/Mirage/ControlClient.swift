import Foundation

/// Client for the engine's newline-delimited JSON protocol over a Unix domain socket.
///
/// Deliberately a raw POSIX socket rather than Network.framework: the control channel is
/// local-only by design (see the engine's `security.py`), and AF_UNIX keeps the kernel —
/// not us — responsible for deciding who may connect.
actor ControlClient {
    enum Failure: LocalizedError {
        case notConnected
        case socket(String)
        case engine(String, remedy: String?)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the Mirage engine."
            case .socket(let m): m
            case .engine(let m, _): m
            }
        }

        var recoverySuggestion: String? {
            if case .engine(_, let remedy) = self { return remedy }
            return nil
        }
    }

    private var fd: Int32 = -1
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var buffer = Data()

    /// Async stream of unsolicited `state` events from the engine. `nonisolated` so the
    /// UI can start iterating without first hopping onto this actor.
    nonisolated let states: AsyncStream<JSON>
    private let stateContinuation: AsyncStream<JSON>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<JSON>.makeStream(of: JSON.self)
        states = stream
        stateContinuation = continuation
    }

    /// Must agree with the engine's `security.state_dir()`, including its
    /// `MIRAGE_STATE_DIR` override — otherwise the app and the engine it just launched
    /// disagree about where the socket is.
    static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["MIRAGE_STATE_DIR"] {
            return URL(fileURLWithPath: override)
                .appendingPathComponent("control.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mirage/control.sock").path
    }

    var isConnected: Bool { fd >= 0 }

    func connect(path: String = ControlClient.defaultSocketPath) throws {
        guard fd < 0 else { return }

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw Failure.socket("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // sun_path is 104 bytes on Darwin and the kernel will not truncate for us.
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s)
            throw Failure.socket("Socket path is too long for AF_UNIX: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, size) }
        }
        guard ok == 0 else {
            close(s)
            throw Failure.socket(
                "Could not reach the Mirage engine at \(path). Is it running? (`mirage serve`)")
        }
        fd = s
        startReader()
    }

    func disconnect() {
        readerTask?.cancel()
        readerTask = nil
        if fd >= 0 { close(fd); fd = -1 }
        for (_, c) in pending { c.resume(throwing: Failure.notConnected) }
        pending.removeAll()
    }

    // MARK: - Calls

    @discardableResult
    func call(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        guard fd >= 0 else { throw Failure.notConnected }
        nextID += 1
        let id = nextID
        var payload: JSON = ["id": .int(id), "method": .string(method)]
        payload["params"] = .object(params.objectValue ?? [:])

        let line = try payload.serialized() + "\n"
        try write(line)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    private func write(_ s: String) throws {
        var bytes = Array(s.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
            guard n > 0 else { throw Failure.socket("write failed") }
            sent += n
        }
    }

    // MARK: - Reader

    private func startReader() {
        let handle = fd
        readerTask = Task.detached(priority: .utility) { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 16384)
            while !Task.isCancelled {
                let n = chunk.withUnsafeMutableBytes { Darwin.read(handle, $0.baseAddress!, 16384) }
                if n <= 0 { break }
                let data = Data(chunk[0..<n])
                await self?.ingest(data)
            }
            await self?.handleDisconnect()
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = buffer[buffer.index(after: idx)...]
            guard let json = try? JSON(data: Data(line)) else { continue }
            route(json)
        }
    }

    private func route(_ json: JSON) {
        if json["event"]?.stringValue == "state", let data = json["data"] {
            stateContinuation.yield(data)
            return
        }
        guard let id = json["id"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if json["ok"]?.boolValue == true {
            cont.resume(returning: json["result"] ?? .null)
        } else {
            cont.resume(throwing: Failure.engine(
                json["error"]?.stringValue ?? "unknown engine error",
                remedy: json["remedy"]?.stringValue))
        }
    }

    private func handleDisconnect() {
        if fd >= 0 { close(fd); fd = -1 }
        for (_, c) in pending { c.resume(throwing: Failure.notConnected) }
        pending.removeAll()
    }
}
