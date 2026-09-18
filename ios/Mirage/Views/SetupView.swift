import SwiftUI
import UniformTypeIdentifiers

/// The one-time setup, and the honest version of what it costs.
///
/// Mirage does not pretend the Mac is unnecessary. A pairing file can only be issued by a
/// computer the phone has trusted, and that is the point of it — it is the thing standing
/// between an app and anyone's phone. What Mirage removes is the Mac being needed *every
/// time*, which is the part that actually made this unusable.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                intro

                Section("On this iPhone") {
                    Step(number: 1,
                         title: "Turn on Developer Mode",
                         detail: "Settings > Privacy & Security > Developer Mode. Switching it on restarts the iPhone.",
                         done: nil)

                    Step(number: 2,
                         title: "Turn on the loopback VPN",
                         detail: "LocalDevVPN, in its own app. Mirage reaches your iPhone's developer service the same way a computer would, and iOS refuses that connection unless it arrives through a network interface.",
                         done: nil)

                    Step(number: 3,
                         title: "Allow Local Network",
                         detail: "iOS asks the first time Mirage connects. If you have already said no, it will not ask again — Settings > Mirage > Local Network. Without it every connection fails in a way that looks identical to the VPN being off.",
                         done: nil)
                }

                Section("From the Mac, once") {
                    Step(number: 4,
                         title: "Run ./scripts/prepare-phone.sh",
                         detail: "It collects two things: the pairing file that lets Mirage talk to this iPhone, and Apple's developer disk image out of Xcode. AirDrop the folder it makes over here.",
                         done: nil)

                    Step(number: 5,
                         title: "Import the folder",
                         detail: importDetail,
                         done: importDone)

                    Button {
                        importing = true
                    } label: {
                        Label(model.setup.status == .missing ? "Choose the folder…" : "Import again…",
                              systemImage: "folder.badge.plus")
                    }

                    if let importError {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if let summary = model.setup.lastImportSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Toggle(isOn: acknowledgement) {
                        Text("I understand what this does")
                            .font(.body.weight(.medium))
                    }
                } header: {
                    Text("Before you start")
                } footer: {
                    Text("""
                    Mirage changes the location this iPhone reports to every app on it, and \
                    to Find My — including to people you share your location with. It does \
                    not change where you are.

                    Nothing you enter here leaves the phone. The pairing file and the disk \
                    image stay inside Mirage's own storage, are kept out of iCloud backups, \
                    and go when the app does.
                    """)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.large)
        }
        // Multiple selection on purpose. Picking the folder is the intended path, but
        // AirDrop delivers it as a zip, and once someone has uncompressed that in Files it
        // is just as natural to select the four files. Both work.
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .propertyList, .diskImage, .data],
                      allowsMultipleSelection: true) { result in
            handle(result)
        }
    }

    private var acknowledgement: Binding<Bool> {
        Binding(get: { model.preferences.acknowledged },
                set: { model.preferences.setAcknowledged($0) })
    }

    private var importDone: Bool? {
        switch model.setup.status {
        case .missing: return false
        case .pairingOnly, .ready: return true
        }
    }

    private var importDetail: String {
        switch model.setup.status {
        case .missing:
            return "Nothing imported yet. Pick the whole folder — or, if AirDrop left you a zip, uncompress it in Files first and pick the folder inside."
        case .pairingOnly:
            return "Pairing file imported. The developer disk image is missing, so you will need the Mac again after every restart — import the whole folder to avoid that."
        case .ready:
            return "Pairing file and developer disk image imported. Mirage re-mounts the image itself after a restart, so the Mac is not needed again until the pairing file expires."
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "location.viewfinder")
                .font(.system(size: 38))
                .foregroundStyle(.blue)
                .padding(.bottom, 2)

            Text("Mirage runs on the iPhone")
                .font(.title2.bold())

            Text("""
            Setting it up needs a Mac once. Using it does not — no cable, no computer \
            awake in another room, no second app driving it.
            """)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    private func handle(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            if !model.setup.importAny(urls) { importError = model.setup.lastError }
        }
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    /// nil when Mirage cannot tell — which is most of them, and saying so is better than
    /// a green tick that means nothing.
    let done: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var marker: some View {
        switch done {
        case .some(true):
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .some(false):
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        case .none:
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.secondary, in: Circle())
        }
    }
}
