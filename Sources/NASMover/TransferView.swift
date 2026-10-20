import SwiftUI

struct TransferView: View {
    var showJobs: () -> Void

    @State private var mode: TransferMode = .copy
    @State private var source: Location?
    @State private var destination: Location?
    @State private var verify = true
    @State private var previewing = false
    @State private var preview: TransferPreview?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Mode", selection: $mode) {
                    ForEach(TransferMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
                Text(modeExplanation).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                LocationPicker(title: mode == .copy ? "Copy this folder" : "Move this folder", location: $source, defaultHost: .qnap)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .padding(.top, 120)
                LocationPicker(title: "Into this folder", location: $destination, defaultHost: .unas)
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = validationProblem {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if let src = source, let dst = destination {
                        Text("Result").font(.caption).foregroundStyle(.secondary)
                        Text(dst.child(src.displayName).breadcrumb).font(.body.weight(.semibold)).textSelection(.enabled)
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Spacer()
                if mode == .copy {
                    Toggle("Verify (MD5) and write ASC MHL manifest", isOn: $verify)
                        .help("Re-reads every file on both sides and compares MD5 checksums, then saves them in an ascmhl folder inside the copy. Recommended; roughly doubles the time.")
                } else {
                    Label("Always MD5-verified (with an ASC MHL manifest) before originals are recycled", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                }
                Button {
                    Task { await runPreview() }
                } label: {
                    if previewing { ProgressView().controlSize(.small).padding(.horizontal, 20) } else { Text("Preview…").padding(.horizontal, 8) }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(validationProblem != nil || previewing)
            }
        }
        .padding(20)
        .navigationTitle("Copy / Move")
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview, let source, let destination {
                PreviewSheet(mode: mode, source: source, destination: destination, preview: preview, verify: mode == .move || verify) {
                    self.preview = nil
                    showJobs()
                }
            }
        }
    }

    private var modeExplanation: String {
        switch mode {
        case .copy: return "Copies the folder. Nothing at the source is touched. Newer files at the destination are never overwritten."
        case .move: return "Copies, verifies every file with MD5, then moves the originals to the source NAS's recycle bin."
        }
    }

    private var validationProblem: String? {
        guard let src = source else { return "Choose the folder to \(mode == .copy ? "copy" : "move")." }
        guard let dst = destination else { return "Choose where it should go." }
        if mode == .move && src.rel.isEmpty { return "Pick a folder inside the share. Whole shares can't be moved." }
        if src.host == dst.host {
            let s = src.fullPath, d = dst.fullPath
            if d == s || d.hasPrefix(s + "/") { return "The destination is inside the source folder." }
            if (s as NSString).deletingLastPathComponent == d { return "That's the folder it's already in." }
        }
        return nil
    }

    private func runPreview() async {
        guard let source, let destination else { return }
        previewing = true
        error = nil
        do { preview = try await NAS.preview(src: source, dstParent: destination) } catch { self.error = error.localizedDescription }
        previewing = false
    }
}

struct PreviewSheet: View {
    let mode: TransferMode
    let source: Location
    let destination: Location
    let preview: TransferPreview
    let verify: Bool
    var started: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var jobs: JobStore
    @State private var starting = false
    @State private var error: String?

    private var notEnoughSpace: Bool {
        guard let free = preview.freeBytes else { return false }
        return preview.bytesToCopy > free - 50_000_000_000 // keep a 50 GB cushion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(mode.rawValue) preview").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text("From  " + source.breadcrumb)
                Text("To      " + destination.child(source.displayName).breadcrumb)
            }
            .font(.callout).textSelection(.enabled)

            Form {
                row("New files", preview.newFiles, color: .green)
                row("Will be updated (source is newer)", preview.updatedFiles, color: .blue,
                    note: "The older destination copies are kept in the destination's recycle bin.")
                row("Skipped (destination is newer)", preview.skippedNewer, color: .orange,
                    note: mode == .move ? "These stay as they are at the destination. The source versions go to the recycle bin with the rest of the folder." : "These are left alone.")
                LabeledContent("To copy") {
                    Text("\(preview.filesToCopy.formatted()) files · \(fmtBytes(preview.bytesToCopy))")
                }
                LabeledContent("Estimated time") {
                    Text(fmtDuration(estimateSeconds(files: preview.filesToCopy, bytes: preview.bytesToCopy) * (verify ? 1.8 : 1)))
                }
                if let free = preview.freeBytes {
                    LabeledContent("Free space at destination") {
                        Text(fmtBytes(free)).foregroundStyle(notEnoughSpace ? .red : .primary)
                    }
                }
            }
            .formStyle(.grouped)

            if notEnoughSpace {
                Label("Not enough free space on \(destination.host.name) (keeping a 50 GB cushion).", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if verify {
                Label("Checksums are saved as an ASC MHL manifest in “\(source.displayName)/ascmhl”. Use Verify to re-check the copy any time.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            if mode == .move {
                Label("After every file is verified, the original folder moves to \(source.host.name)'s recycle bin (\(source.share.name) › NAS Mover). Nothing is permanently deleted.", systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
            if preview.filesToCopy == 0 && mode == .copy {
                Label("Everything is already there. Nothing to copy.", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let error { Text(error).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .move ? "Start Move" : "Start Copy") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(notEnoughSpace || starting || (preview.filesToCopy == 0 && mode == .copy))
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    @ViewBuilder
    private func row(_ label: String, _ items: [PreviewItem], color: Color, note: String? = nil) -> some View {
        DisclosureGroup {
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            ForEach(items.prefix(300)) { i in
                HStack {
                    Text(i.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(fmtBytes(i.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
            if items.count > 300 { Text("…and \(items.count - 300) more").font(.caption).foregroundStyle(.secondary) }
        } label: {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                Spacer()
                Text("\(items.count.formatted()) · \(fmtBytes(items.reduce(0) { $0 + $1.size }))").monospacedDigit()
            }
        }
        .disabled(items.isEmpty)
    }

    private func start() async {
        starting = true
        let id = NAS.newJobID(mode.rawValue.lowercased())
        let dstLoc = destination.child(source.displayName)
        var job = JobSpec(id: id, title: "\(mode.rawValue): \(source.breadcrumb)  →  \(destination.host.name) › \(destination.share.name)\(destination.rel.isEmpty ? "" : " › " + destination.rel)",
                          runner: NAS.runner(source.host, destination.host))
        job.copies = [CopyStep(from: source, to: dstLoc.fullPath, toHost: destination.host, list: nil,
                               backup: dstLoc.recycleDir(job: id), update: true)]
        if mode == .move, let parent = source.parent {
            job.recycles = [RecycleStep(host: source.host, root: source.fullPath, dest: parent.recycleDir(job: id), list: nil)]
        }
        job.verify = verify
        job.totalFiles = preview.filesToCopy
        job.totalBytes = preview.bytesToCopy
        do {
            try await NAS.start(job)
            await jobs.refresh()
            dismiss()
            started()
        } catch {
            self.error = error.localizedDescription
        }
        starting = false
    }
}
