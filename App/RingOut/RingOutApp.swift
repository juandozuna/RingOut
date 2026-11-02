import SwiftUI

@main
struct RingOutApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { app.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { app.saveNow() }
                }
        }
    }
}
