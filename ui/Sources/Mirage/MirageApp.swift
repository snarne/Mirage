import SwiftUI

@main
struct MirageApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .task { await model.startUp() }
                .onDisappear { model.shutDown() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Restore Real Location") {
                    Task { await model.restore() }
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("Reset to Real Location and Clear Trip") {
                    Task { await model.resetToRealLocation() }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Review Permissions…") {
                    Task { await model.revokeConsent() }
                }
            }
        }
    }
}
