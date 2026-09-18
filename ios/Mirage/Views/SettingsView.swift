import MirageKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingErase = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speed and distance", selection: unitsBinding) {
                        Text("Follow my region — \(UnitSystem.deviceDefault.speedAbbreviation)")
                            .tag(UnitSystem?.none)
                        ForEach(UnitSystem.allCases) { system in
                            Text(system.displayName).tag(UnitSystem?.some(system))
                        }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("""
                    The engine works in metres per second whatever this says; only what you \
                    read changes. Following your region gets the United Kingdom right, which \
                    is metric but posts speed limits in mph.
                    """)
                }

                Section {
                    Picker("Session length", selection: capBinding) {
                        Text("No limit").tag(0)
                        ForEach([15, 30, 60, 120, 240, 480], id: \.self) { minutes in
                            Text(minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min").tag(minutes)
                        }
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("""
                    When the time is up Mirage stops the journey where it is and says so. It \
                    does not restore your real location on its own — undoing something you \
                    chose is your decision, and you may not be holding the phone.
                    """)
                }

                Section {
                    LabeledContent("VPN address") {
                        TextField("10.7.0.1", text: addressBinding)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Pairing file", value: model.setup.hasPairingFile ? "Imported" : "Missing")
                    LabeledContent("Developer disk image", value: model.setup.hasDeveloperImage ? "Imported" : "Missing")
                } header: {
                    Text("Connection")
                } footer: {
                    Text("""
                    The address is the one your loopback VPN shows. A wrong value here looks \
                    exactly like a broken pairing file, which is why it is worth checking first.
                    """)
                }

                Section {
                    Button("Remove everything Mirage has stored", role: .destructive) {
                        confirmingErase = true
                    }
                } footer: {
                    Text("""
                    Mirage keeps your pairing file, the developer disk image, your saved trips \
                    and your settings inside its own container. Nothing is sent anywhere, none \
                    of it is included in iCloud backups, and all of it goes when you delete the \
                    app. This removes it now without waiting for that.
                    """)
                }

                Section {
                    LabeledContent("Version", value: version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Mirage is MIT-licensed. It has no account, no analytics and no server.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Remove everything?", isPresented: $confirmingErase) {
                Button("Remove", role: .destructive) {
                    model.setup.eraseEverything()
                    model.preferences.forgetEverything()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need to run the setup script on the Mac and import the folder again before Mirage can do anything.")
            }
        }
    }

    private var unitsBinding: Binding<UnitSystem?> {
        Binding(get: { model.preferences.unitPreference.explicit },
                set: { model.preferences.setUnits($0) })
    }

    private var capBinding: Binding<Int> {
        Binding(get: { model.preferences.sessionCapMinutes },
                set: { model.preferences.setSessionCap(minutes: $0) })
    }

    private var addressBinding: Binding<String> {
        Binding(get: { model.preferences.vpnAddress },
                set: { model.preferences.setVPNAddress($0) })
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
