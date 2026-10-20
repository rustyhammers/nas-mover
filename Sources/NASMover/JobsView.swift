import SwiftUI

struct JobsView: View {
    @EnvironmentObject var store: JobStore
    @State private var logJob: JobInfo?

    var body: some View {
        Group {
            if store.jobs.isEmpty {
                ContentUnavailableView("No jobs yet", systemImage: "tray",
                                       description: Text("Jobs run on the NAS, so they keep going if this Mac sleeps or the app is closed."))
            } else {
                List(store.jobs) { job in
                    JobRow(job: job, showLog: { logJob = job })
                        .padding(.vertical, 6)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let e = store.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .sheet(item: $logJob) { LogSheet(job: $0) }
    }
}

struct JobRow: View {
    let job: JobInfo
    var showLog: () -> Void
    @EnvironmentObject var store: JobStore
    @State private var confirmCancel = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                stateBadge
                Text(job.title).font(.headline).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text(job.host.name).font(.caption).foregroundStyle(.secondary)
            }
            if (job.isRunning || job.state == "starting") && job.isHashing && job.hashTotal > 0 {
                ProgressView(value: Double(job.hashedFiles), total: Double(job.hashTotal))
                HStack {
                    Text(job.phase)
                    Spacer()
                    Text("\(job.hashedFiles.formatted()) of \(job.hashTotal.formatted()) files checksummed").monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if job.isRunning || job.state == "starting" {
                ProgressView(value: job.fraction)
                HStack {
                    Text(job.phase.isEmpty ? "Starting…" : job.phase)
                    Spacer()
                    Text(progressText).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(job.result.isEmpty ? job.state : job.result)
                        .foregroundStyle(job.state == "done" ? Color.green : job.state == "failed" ? .red : .secondary)
                    Spacer()
                    Text(summaryText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Button("Log", action: showLog)
                if job.isRunning || job.state == "starting" {
                    Button("Cancel", role: .destructive) { confirmCancel = true }
                } else {
                    Button("Remove from list") { confirmRemove = true }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .confirmationDialog("Cancel this job?", isPresented: $confirmCancel) {
            Button("Cancel Job", role: .destructive) { Task { try? await NAS.cancel(job); await store.refresh() } }
        } message: {
            Text("Files already copied stay where they are. Nothing at the source is touched, and running it again picks up where it stopped.")
        }
        .confirmationDialog("Remove this job from the list?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { try? await NAS.deleteRecord(job); await store.refresh() } }
        } message: {
            Text("This only deletes the job record and log. Your files and recycle-bin copies aren't touched.")
        }
    }

    private var stateBadge: some View {
        let (icon, color): (String, Color) = {
            switch job.state {
            case "running", "starting": return ("arrow.triangle.2.circlepath", .blue)
            case "done": return ("checkmark.circle.fill", .green)
            case "failed": return ("xmark.octagon.fill", .red)
            case "cancelled": return ("stop.circle.fill", .orange)
            default: return ("questionmark.circle", .secondary)
            }
        }()
        return Image(systemName: icon).foregroundStyle(color)
    }

    private var progressText: String {
        var parts = ["\(job.doneFiles.formatted()) of \(job.totalFiles.formatted()) files",
                     "\(fmtBytes(job.doneBytes)) of \(fmtBytes(job.totalBytes))"]
        if let r = job.rate {
            parts.append("\(fmtBytes(Int64(r)))/s")
            let remaining = Double(max(0, job.totalBytes - job.doneBytes)) / r
            if job.totalBytes > job.doneBytes { parts.append("about \(fmtDuration(remaining)) left") }
        }
        return parts.joined(separator: " · ")
    }

    private var summaryText: String {
        var parts = ["\(job.doneFiles.formatted()) files · \(fmtBytes(job.doneBytes))"]
        if let s = job.started, let f = job.finished { parts.append(fmtDuration(f.timeIntervalSince(s))) }
        if let s = job.started { parts.append(s.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

struct LogSheet: View {
    let job: JobInfo
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"

    var body: some View {
        VStack(alignment: .leading) {
            Text(job.title).font(.headline)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Text("Stored on the \(job.host.name) in ~/.nasmover/jobs/\(job.id)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 760, height: 520)
        .task {
            do { text = try await NAS.log(job) } catch { text = error.localizedDescription }
        }
    }
}
