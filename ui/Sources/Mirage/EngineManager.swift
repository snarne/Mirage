import Foundation

/// Owns the engine and tunnel processes so the user never opens a terminal.
///
/// Both are supervised child processes. Shutdown is deliberately `SIGTERM`, never
/// `SIGKILL`: the engine installs a signal handler that clears the simulated location
/// before exiting, and killing it outright would leave the device still simulating —
/// the one failure this project treats as unacceptable.
@MainActor
@Observable
final class EngineManager {
    enum Phase: Equatable {
        case notConfigured(String)       // no Python environment found
        case starting
        case running
        case failed(String)
        case stopped

        var isRunning: Bool { self == .running }
    }

    private(set) var phase: Phase = .stopped
    private(set) var log: [String] = []

    private var engineProcess: Process?
    private var restartAttempts = 0
    private var intentionalStop = false

    struct Environment {
        let python: String
        let cli: String
        let root: URL
    }

    /// Where the engine lives. Checked in priority order so a development checkout and
    /// an installed app both work without configuration.
    ///
    /// Returns every path tried alongside the result: "no environment found" is useless
    /// on its own, and the list of places searched is what makes it actionable.
    static func locateEnvironment() -> (environment: Environment?, tried: [String]) {
        let fm = FileManager.default

        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MIRAGE_ROOT"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        // Bundled alongside the app: Mirage.app/Contents/Resources/engine
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("engine"))
        }
        // Development checkout: walk up from the executable to the repo root.
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            candidates.append(dir)
        }

        var tried: [String] = []
        for root in candidates {
            let python = root.appendingPathComponent(".venv/bin/python")
            let pkg = root.appendingPathComponent("core/mirage/cli.py")
            tried.append(root.path)
            if fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: pkg.path) {
                return (Environment(python: python.path,
                                    cli: root.appendingPathComponent("core").path,
                                    root: root), tried)
            }
        }
        return (nil, tried)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !phase.isRunning else { return }
        intentionalStop = false

        let located = Self.locateEnvironment()
        guard let env = located.environment else {
            for path in located.tried { append("looked in \(path)") }
            phase = .notConfigured(
                "No Python environment found. Run scripts/bootstrap.sh in the Mirage "
                + "folder, or set MIRAGE_ROOT to the checkout.\n\nLooked in:\n"
                + located.tried.map { "  \($0)" }.joined(separator: "\n"))
            return
        }

        phase = .starting
        append("Using engine at \(env.cli)")

        // No tunnel process to manage: the engine opens Apple's native remotepairingd
        // tunnel in-process, which needs no elevated privileges. The only daemon that
        // would have needed root — pymobiledevice3's `tunneld` — is not used.
        do {
            try startEngine(python: env.python, workingDirectory: env.cli)
        } catch {
            phase = .failed("Could not start the engine: \(error.localizedDescription)")
        }
    }

    private func startEngine(python: String, workingDirectory: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        // MIRAGE_MOCK=1 runs the engine without a device: it records fixes instead of
        // sending them, so the interface can be exercised without changing the location
        // the phone actually reports.
        let mock = ProcessInfo.processInfo.environment["MIRAGE_MOCK"] == "1"
        p.arguments = mock
            ? ["-m", "mirage.cli", "--mock", "serve"]
            : ["-m", "mirage.cli", "serve"]
        if mock { append("MIRAGE_MOCK=1 — no device will be driven") }
        p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleEngineOutput(text) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.engineDidExit(status: proc.terminationStatus) }
        }

        try p.run()
        engineProcess = p
    }

    private func handleEngineOutput(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            append(String(line), tag: "engine")
            if line.hasPrefix("MIRAGE_READY") {
                restartAttempts = 0
                phase = .running
            }
        }
    }

    private func engineDidExit(status: Int32) {
        engineProcess = nil
        guard !intentionalStop else { phase = .stopped; return }

        append("engine exited with status \(status)")
        // Bounded restart. An engine that cannot start is a configuration problem, and
        // looping on it would bury the real error under restart noise.
        guard restartAttempts < 3 else {
            phase = .failed("The engine stopped repeatedly. See the log below.")
            return
        }
        restartAttempts += 1
        Task {
            try? await Task.sleep(for: .seconds(Double(restartAttempts)))
            await start()
        }
    }

    func stop() {
        intentionalStop = true
        // SIGTERM, so the engine's handler restores the real location before exiting.
        engineProcess?.terminate()
        engineProcess = nil
        phase = .stopped
        append("stopped")
    }


    private func append(_ line: String, tag: String = "mirage") {
        let entry = "[\(tag)] \(line)"
        log.append(entry)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        Self.writeToLogFile(entry)
    }

    /// The app is usually launched from Finder, where stdout goes nowhere. Without a
    /// log file, a startup failure is invisible.
    static var logFileURL: URL {
        // Honour the same override the engine and the control socket use, so an
        // isolated run does not write into the real installation's log.
        if let override = ProcessInfo.processInfo.environment["MIRAGE_STATE_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("engine.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mirage/engine.log")
    }

    private static func writeToLogFile(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let url = logFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // Created owner-only. The log carries device and routing detail, and every
            // other file in this directory is 0600 — a world-readable log was the odd
            // one out, and on a shared Mac that is a real difference.
            FileManager.default.createFile(
                atPath: url.path, contents: data,
                attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
