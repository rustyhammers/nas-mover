import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shares: ShareStore

    var body: some View {
        Form {
            Section("Connections (SSH, key-based)") {
                LabeledContent("QNAP", value: settings.qnapTarget.isEmpty ? "Not set up" : settings.qnapTarget)
                LabeledContent("UNAS", value: settings.unasTarget.isEmpty ? "Not set up" : settings.unasTarget)
                LabeledContent("UNAS as seen from the QNAP", value: settings.unasFromQnap.isEmpty ? "Not linked" : settings.unasFromQnap)
                Button("Run Setup Again…") {
                    NSApp.keyWindow?.close()
                    NotificationCenter.default.post(name: .showSetup, object: nil)
                }
            }
            Section("Transfers") {
                Stepper("Parallel streams: \(settings.streams)", value: $settings.streams, in: 1...8)
                Text("4 was fastest in testing. More streams don't help with small files.").font(.caption).foregroundStyle(.secondary)
                TextField("Owner for files written to the UNAS", text: $settings.unasOwner)
            }
            Button("Reconnect") { Task { await shares.reload() } }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
