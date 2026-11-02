import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            switch app.phase {
            case .welcome: WelcomeView()
            case .wizard: SetupWizardView()
            case .live: LiveView()
            }
            if app.phase == .live && app.locked { LockOverlay() }
            if let d = app.disconnect { DisconnectedOverlay(disconnect: d).transition(.opacity) }
            if app.reconnectedFlash { ReconnectedFlash().transition(.opacity) }
            if app.show.dimBooth {
                Color.black.opacity(0.6).allowsHitTesting(false).ignoresSafeArea()
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.disconnect)
        .animation(.easeOut(duration: 0.25), value: app.reconnectedFlash)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .sheet(isPresented: $app.showDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $app.showCalibration) { CalibrationSheet() }
        .sheet(item: Binding(get: { app.notchDetailChannel.map { ChannelRef(id: $0) } }, set: { app.notchDetailChannel = $0?.id })) { ref in
            NotchDetailSheet(channel: ref.id)
        }
    }
}

private struct ChannelRef: Identifiable { let id: Int }
