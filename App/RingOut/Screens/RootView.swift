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
            if app.phase == .live && app.locked { LockOverlay().ignoresSafeArea() }
            if let d = app.disconnect { DisconnectedOverlay(disconnect: d).ignoresSafeArea().transition(.opacity) }
            if app.reconnectedFlash { ReconnectedFlash().ignoresSafeArea().transition(.opacity) }
            if app.show.dimBooth {
                Color.black.opacity(0.6).allowsHitTesting(false).ignoresSafeArea()
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.disconnect)
        .animation(.easeOut(duration: 0.25), value: app.reconnectedFlash)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sheet(isPresented: $app.showSettings) { SettingsView().presentationSizing(.page) }
        .sheet(isPresented: $app.showDiagnostics) { DiagnosticsView().presentationSizing(.page) }
        .sheet(isPresented: $app.showCalibration) { CalibrationSheet().presentationSizing(.page) }
        .sheet(item: Binding(get: { app.notchDetailChannel.map { ChannelRef(id: $0) } }, set: { app.notchDetailChannel = $0?.id })) { ref in
            NotchDetailSheet(channel: ref.id).presentationSizing(.page)
        }
    }
}

private struct ChannelRef: Identifiable { let id: Int }
