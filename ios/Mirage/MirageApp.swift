import SwiftUI

@main
struct MirageApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.blue)
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the normal case for a drive, not an interruption. All this
            // does is make sure the Lock Screen is showing the current state before the
            // app stops being asked anything.
            if phase != .active { model.willResignActive() }
        }
    }
}
