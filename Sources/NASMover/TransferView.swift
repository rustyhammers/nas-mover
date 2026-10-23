import SwiftUI

struct TransferView: View {
    var showJobs: () -> Void

    @State private var mode: TransferMode = .copy
    @State private var browse: Location?
    @State private var sources: [Location] = []
    @State private var destination: Location?
    @State private var verify = true
    @State private var previewing = false
    @State private var previews: [(Location, TransferPreview)]?
    @State private var progressNote: String?
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
                LocationPicker(title: mode == .copy ? "Tick the folders to copy" : "Tick the folders to move",
                               location: $browse, checked: $sources, defaultHost: .qnap)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .padding(.top, 120)
                LocationPicker(title: "Into this folder (open it)", location: $destination, defaultHost: .unas)
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = validationProblem {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if let dst = destination {
                        Text(sources.count == 1 ? "Result" : "Results").font(.caption).foregroundStyle(.secondary)
                        ForEach(sources.prefix(3), id: \.self) { src in
                            Text(dst.child(src.displayName).breadcrumb).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.head)
                        }
                        if sources.count > 3 { Text("…and \(sources.count - 3) more").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let progressNote { HStack { ProgressView().controlSize(.small); Text(progressNote) } }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Spacer()
                if mode == .copy {
                    Toggle("Verify (MD5) and write ASC MHL manifest", isOn: $verify)
                        .help("Re-reads every file on both sides and compares MD5 checksums, then saves them in an ascmhl folder inside the copy. Recommended; roughly doubles the time.")
                } else {
                    Label("Always MD5-verified before originals are recycled", systemImage: "checkmark.shield").foregroundStyle(.secondary)
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
        .sheet(isPresented: Binding(get: { previews != nil }, set: { if !$0 { previews = nil } })) {
            if let previews, let destination {
                PreviewSheet(mode: mode, items: previews, destination: destination, verify: mode == .move || verify) {
                    self.previews = nil
                    sources = []
                    showJobs()
                }
            }
        }
    }

    private var modeExplanation: String {
        switch mode {
        case .copy: return "Copies the ticked folders. Nothing at the source is touched. Newer files at the destination are never overwritten."
        case .move: return "Copies, verifies every file with MD5, then moves the originals into the share's “_NAS Mover Recycle” folder for you to delete when you're happy."
        }
    }

    private var validationProblem: String? {
        guard !sources.isEmpty else { return "Tick the folder(s) to \(mode == .copy ? "copy" : "move")." }
        guard let dst = destination else { return "Open the folder they should go into." }
        if Set(sources.map(\.host)).count > 1 { return "Pick folders from one NAS at a time." }
        let names = sources.map(\.displayName)
        if Set(names).count != names.count { return "Two ticked folders have the same name; they'd land in the same place." }
        for src in sources {
            if mode == .move && src.rel.isEmpty { return "Whole shares can't be moved. Pick folders inside “\(src.share.name)”." }
            if src.host == dst.host {
                let s = src.fullPath, d = dst.fullPath
                if d == s || d.hasPrefix(s + "/") { return "The destination is inside “\(src.displayName)”." }
                if (s as NSString).deletingLastPathComponent == d { return "“\(src.displayName)” is already in that folder." }
            }
        }
        return nil
    }

    private func runPreview() async {
        guard let destination else { return }
        previewing = true
        error = nil
        var results: [(Location, TransferPreview)] = []
        do {
            for (i, src) in sources.enumerated() {
                progressNote = sources.count > 1 ? "Checking \(i + 1) of \(sources.count): \(src.displayName)…" : "Checking \(src.displayName)…"
                results.append((src, try await NAS.preview(src: src, dstParent: destination)))
            }
            previews = results
        } catch {
            self.error = error.localizedDescription
        }
        progressNote = nil
        previewing = false
    }
}

struct PreviewSheet: View {
    let mode: TransferMode
    let items: [(Location, TransferPreview)]
    let destination: Location
    let verify: Bool
    var started: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var jobs: JobStore
    @State private var starting = false
    @State private var error: String?

    /// All folders' previews combined; paths are prefixed with the folder name when there are several.
    private var preview: TransferPreview {
        var p = TransferPreview()
        let prefix = items.count > 1
        for (src, pv) in items {
            func pre(_ list: [PreviewItem]) -> [PreviewItem] {
                prefix ? list.map { PreviewItem(path: src.displayName + "/" + $0.path, size: $0.size) } : list
            }
            p.newFiles += pre(pv.newFiles)
            p.updatedFiles += pre(pv.updatedFiles)
            p.skippedNewer += pre(pv.skippedNewer)
            p.totalItems += pv.totalItems
            p.totalBytes += pv.totalBytes
            p.freeBytes = pv.freeBytes
        }
        return p
    }
    private var sources: [Location] { items.map(\.0) }
    private var sourceHost: HostID { sources[0].host }

    private var notEnoughSpace: Bool {
        guard let free = preview.freeBytes else { return false }
        return preview.bytesToCopy > free - 50_000_000_000 // keep a 50 GB cushion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(mode.rawValue) preview").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                if sources.count == 1 {
                    Text("From  " + sources[0].breadcrumb)
                    Text("To      " + destination.child(sources[0].displayName).breadcrumb)
                } else {
                    Text("From  \(sources.count) folders on the \(sourceHost.name): " + sources.map(\.displayName).joined(separator: ", ")).lineLimit(3)
                    Text("To      " + destination.breadcrumb)
                }
            }
            .font(.callout).textSelection(.enabled)

            Form {
                row("New files", preview.newFiles, color: .green)
                row("Will be updated (source is newer)", preview.updatedFiles, color: .blue,
                    note: "The older destination copies are kept in the destination share's “_NAS Mover Recycle” folder.")
                row("Skipped (destination is newer)", preview.skippedNewer, color: .orange,
                    note: mode == .move ? "These stay as they are at the destination. The source versions go to “_NAS Mover Recycle” with the rest of the folder." : "These are left alone.")
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
                Label("Checksums are saved as an ASC MHL manifest in each copied folder's “ascmhl” folder. Use Verify to re-check a copy any time.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            if mode == .move {
                Label("After every file is verified, the original folder\(sources.count == 1 ? "" : "s") move\(sources.count == 1 ? "s" : "") into “\(sources[0].share.name) › _NAS Mover Recycle”. Nothing is deleted: empty that folder yourself once you've checked the copy.", systemImage: "trash")
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
        let what = sources.count == 1 ? sources[0].breadcrumb : "\(sources.count) folders from \(sourceHost.name)"
        var job = JobSpec(id: id, title: "\(mode.rawValue): \(what)  →  \(destination.breadcrumb)",
                          runner: NAS.runner(sourceHost, destination.host))
        for src in sources {
            let dstLoc = destination.child(src.displayName)
            job.copies.append(CopyStep(from: src, to: dstLoc.fullPath, toHost: destination.host, list: nil,
                                       backup: dstLoc.recycleDir(job: id), update: true))
            if mode == .move, let parent = src.parent {
                job.recycles.append(RecycleStep(host: src.host, root: src.fullPath, dest: parent.recycleDir(job: id), list: nil))
            }
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
