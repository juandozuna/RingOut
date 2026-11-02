import SwiftUI
import UniformTypeIdentifiers

/// S1 — Welcome / first run.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            SetupRing(state: .searching) {
                RigIllustration()
            }
            VStack(spacing: 12) {
                Text("Let’s get you to passing audio in 5 minutes")
                    .font(Tokens.Font.title)
                    .foregroundStyle(Tokens.Color.textPrimary)
                    .multilineTextAlignment(.center)
                Text("RingOut turns this iPad and a USB audio interface into a two-channel feedback-suppression insert for vocal mics.")
                    .font(Tokens.Font.body(17))
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            PrimaryButton(title: "Start setup", systemImage: "arrow.right") { app.beginSetup() }
                .accessibilityIdentifier("startSetup")
            Button("I have a show file") { importing = true }
                .font(Tokens.Font.label(17))
                .foregroundStyle(Tokens.Color.accent)
                .frame(minHeight: Tokens.Size.target)
            ChecklistChips(done: 0)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.bgBase)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let show = try app.store.importShow(from: url)
                app.finishSetup(with: show, saveAs: nil)
            } catch {
                importError = "That file isn’t a RingOut show file. (\(error.localizedDescription))"
            }
        }
        .alert("Couldn’t import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }
}

struct ChecklistChips: View {
    var done: Int  // number of completed items: Interface · Wiring · Calibration
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(["Interface", "Wiring", "Calibration"].enumerated()), id: \.offset) { i, title in
                HStack(spacing: 8) {
                    Image(systemName: i < done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(i < done ? Tokens.Color.safe : Tokens.Color.textSecondary)
                    Text(title).font(Tokens.Font.label(15)).foregroundStyle(i < done ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(Capsule().fill(Tokens.Color.bgElevated))
            }
        }
    }
}
