import SwiftUI

/// Re-check a folder against its ASC MHL checksum history, or create the first manifest for it.
struct VerifyView: View {
    var showJobs: () -> Void

    @EnvironmentObject var jobs: JobStore
    @State private var folder: Location?
    @State private var history: (generations: Int, latest: String?)?
    @State private var checking = false
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-reads every file in a folder, computes its MD5, and compares it with the folder's ASC MHL history (the ascmhl folder that Copy, Move and tools like Hedge or Silverstack write). Each check is recorded as a new generation in that history.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LocationPicker(title: "Folder to verify", location: $folder, defaultHost: .unas)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if folder == nil {
                        Text("Choose a folder.").foregroundStyle(.secondary)
                    } else if checking {
                        HStack { ProgressView().controlSize(.small); Text("Looking for a checksum history…") }
                    } else if let h = history {
                        if h.generations > 0 {
                            Label("Has a checksum history: \(h.generations) generation\(h.generations == 1 ? "" : "s")\(h.latest.map { ", latest \($0)" } ?? "")", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("Flags files that changed without their date changing (possible corruption), files that are missing, edited and new.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("No checksum history yet", systemImage: "seal")
                            Text("This will hash every file and save the first manifest, so you can check this folder for damage later.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Spacer()
                Button {
                    Task { await start() }
                } label: {
                    Text((history?.generations ?? 0) > 0 ? "Verify Folder" : "Create Manifest").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil || checking || starting || history == nil)
            }
        }
        .padding(20)
        .navigationTitle("Verify")
        .task(id: folder) { await lookUp() }
    }

    private func lookUp() async {
        history = nil
        error = nil
        guard let folder else { return }
        checking = true
        do { history = try await NAS.mhlHistory(folder) } catch { self.error = error.localizedDescription }
        checking = false
    }

    private func start() async {
        guard let folder else { return }
        starting = true
        error = nil
        let isFirst = (history?.generations ?? 0) == 0
        var job = JobSpec(id: NAS.newJobID("verify"),
                          title: "\(isFirst ? "Create manifest" : "Verify"): \(folder.breadcrumb)",
                          runner: folder.host)
        job.verifyFolder = folder.fullPath
        do {
            try await NAS.start(job)
            await jobs.refresh()
            showJobs()
        } catch {
            self.error = error.localizedDescription
        }
        starting = false
    }
}
