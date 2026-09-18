import Foundation
import MirageKit

/// The two credentials the phone needs, and nothing else.
///
/// ## Where this lives, and why there
///
/// Inside the app's own container, under Application Support. iOS gives every app a
/// private container that no other app can read and that is destroyed with the app, which
/// is the whole of the storage design — there is no server, no account and no shared
/// group, so there is nowhere else for any of it to go.
///
/// Three things are done on top of that default:
///
/// * **Excluded from backup.** Otherwise a pairing file would ride an iCloud backup onto
///   Apple's servers and into any future restore. A credential for talking to this phone
///   should not travel.
/// * **Protected at rest** with `completeUntilFirstUserAuthentication` rather than
///   `complete`. `complete` sounds stronger and would be wrong: files become unreadable
///   while the phone is locked, which is precisely when a drive is running.
/// * **Wiped when the app version changes**, so an update never inherits credentials from
///   a build that is gone.
@MainActor
@Observable
final class SetupStore {

    enum Status: Equatable {
        case missing
        case pairingOnly
        case ready
    }

    private(set) var status: Status = .missing
    private(set) var lastError: String?

    /// Where the pairing file ends up once imported.
    let pairingFileURL: URL
    /// Folder holding Image.dmg, its trust cache and BuildManifest.plist.
    let developerImageURL: URL

    private let root: URL
    private let versionMarker: URL

    init(root: URL = SetupStore.defaultRoot()) {
        self.root = root
        self.pairingFileURL = root.appendingPathComponent("pairing.plist")
        self.developerImageURL = root.appendingPathComponent("DeveloperImage", isDirectory: true)
        self.versionMarker = root.appendingPathComponent("built-for.txt")
        prepare()
        discardIfBuiltForAnotherVersion()
        refresh()
    }

    /// `nonisolated` because it is a default argument to `init`, which Swift evaluates at
    /// the call site rather than inside the initialiser. It touches nothing but the file
    /// system, so there is no state to be isolated from.
    nonisolated static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mirage/Setup", isDirectory: true)
    }

    // MARK: - State

    var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingFileURL.path) }

    var hasDeveloperImage: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: developerImageURL.path)
        else { return false }
        let lower = names.map { $0.lowercased() }
        return lower.contains(where: { $0.hasSuffix(".dmg") })
            && lower.contains(where: { $0.hasSuffix(".trustcache") })
            && lower.contains("buildmanifest.plist")
    }

    /// nil when there is no image to offer, which the bridge reads as "do not try to
    /// mount one".
    var developerImageIfPresent: URL? { hasDeveloperImage ? developerImageURL : nil }

    func refresh() {
        if hasPairingFile {
            status = hasDeveloperImage ? .ready : .pairingOnly
        } else {
            status = .missing
        }
    }

    // MARK: - Import

    /// What the last import actually took, so the screen can say so rather than leaving
    /// someone to infer it from two status rows.
    private(set) var lastImportSummary: String?

    /// Take whatever is useful out of a folder, or out of a selection of files.
    ///
    /// Written to accept the folder `scripts/prepare-phone.sh` produces, but it is
    /// deliberately forgiving: AirDrop delivers a folder as a zip, people uncompress it
    /// and then select the four files rather than the folder, and any of those should
    /// work. Files are recognised by shape rather than by name — a stray `.DS_Store` is
    /// not a reason to make someone start over.
    @discardableResult
    func importAny(_ urls: [URL]) -> Bool {
        lastError = nil
        lastImportSummary = nil

        var files: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                    lastError = "That folder could not be read."
                    return false
                }
                files.append(contentsOf: names.map { url.appendingPathComponent($0) })
            } else {
                files.append(url)
            }
        }

        // A zip is the single most likely wrong pick, because it is what AirDrop hands
        // you. Saying so beats "not in the correct format".
        if files.count == 1, files[0].pathExtension.lowercased() == "zip" {
            lastError = "That is still a zip. Tap it in Files first to uncompress it, then choose the folder it makes."
            return false
        }

        var took: [String] = []
        for source in files {
            // Each file needs its own scoped access when it came from a multiple
            // selection; harmless when it came from a folder we already opened.
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            let lower = source.lastPathComponent.lowercased()
            do {
                if lower.hasSuffix(".dmg") {
                    try place(source, into: developerImageURL, as: "Image.dmg")
                    took.append("disk image")
                } else if lower.hasSuffix(".trustcache") {
                    try place(source, into: developerImageURL, as: "Image.dmg.trustcache")
                    took.append("trust cache")
                } else if lower == "buildmanifest.plist" {
                    try place(source, into: developerImageURL, as: "BuildManifest.plist")
                    took.append("build manifest")
                } else if lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") {
                    // Anything else plist-shaped is a pairing file candidate; validate
                    // before keeping it, so a wrong pick fails now rather than at the
                    // first drive.
                    if try isPairingFile(source) {
                        try place(source, into: root, as: "pairing.plist")
                        took.append("pairing file")
                    } else if isLockdownPairRecord(source) {
                        lastError = """
                            \(source.lastPathComponent) is a lockdown pair record, not the                             one Mirage needs. They are both called pairing files and they                             are not interchangeable. Re-run ./scripts/prepare-phone.sh —                             it makes the right one.
                            """
                        return false
                    }
                }
            } catch {
                lastError = "Could not copy \(source.lastPathComponent): \(error.localizedDescription)"
                return false
            }
        }

        guard !took.isEmpty else {
            lastError = files.count == 1
                ? "\(files[0].lastPathComponent) is not part of a Mirage setup folder. It needs pairing.plist, Image.dmg, Image.dmg.trustcache and BuildManifest.plist."
                : "Nothing in that selection was a pairing file or a developer disk image."
            return false
        }

        stampVersion()
        refresh()
        lastImportSummary = "Imported the " + took.sorted().joined(separator: ", the") + "."
        return true
    }

    /// A RemotePairing credential: an Ed25519 keypair and the identifier it was minted
    /// under. Checking for those is enough to tell it apart from every other plist
    /// someone might pick by mistake — including, importantly, a *lockdown* pair record,
    /// which looks like a pairing file, is called one everywhere, and will not work.
    private func isPairingFile(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return plist["public_key"] is Data
            && plist["private_key"] is Data
            && plist["identifier"] is String
    }

    /// True for the wrong kind of pairing file, so the screen can say which one it is
    /// rather than "not in the correct format".
    private func isLockdownPairRecord(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return plist["HostPrivateKey"] != nil || plist["HostCertificate"] != nil
    }

    private func place(_ source: URL, into directory: URL, as name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let destination = directory.appendingPathComponent(name)
        // Copy through a temporary name so a failure halfway cannot leave a half-written
        // credential that looks valid.
        let staging = directory.appendingPathComponent(".\(name).incoming")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                              .posixPermissions: 0o600],
                             ofItemAtPath: staging.path)
        _ = try? fm.replaceItemAt(destination, withItemAt: staging)
        if fm.fileExists(atPath: staging.path) {   // replaceItemAt did not consume it
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)
        }
        excludeFromBackup(directory)
    }

    // MARK: - Erasing

    /// Remove everything Mirage has stored about this device.
    ///
    /// Offered in Settings, not buried. Someone who wants their credentials off the phone
    /// should not have to delete the app to be sure, and should not have to trust that
    /// deleting the app did it.
    func eraseEverything() {
        try? FileManager.default.removeItem(at: root)
        lastImportSummary = nil
        lastError = nil
        prepare()
        refresh()
    }

    // MARK: - Housekeeping

    private func prepare() {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        excludeFromBackup(root)
    }

    /// Keeps the folder out of iCloud and iTunes backups.
    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func stampVersion() {
        try? Data(currentVersion.utf8).write(to: versionMarker, options: .atomic)
    }

    private func discardIfBuiltForAnotherVersion() {
        let stored = (try? String(contentsOf: versionMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            // Nothing imported yet, or a store from before this marker existed. Stamping
            // now rather than erasing avoids punishing an upgrade for the marker's own
            // absence.
            if hasPairingFile { stampVersion() }
            return
        }
        guard stored != currentVersion else { return }
        try? FileManager.default.removeItem(at: root)
        prepare()
    }
}
