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
            if job.isRunning || job.state == "starting" {
                LiveProgress(job: job, stats: store.stats(job))
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

/// Sent / left, elapsed / remaining, speed and file count for a running job.
struct LiveProgress: View {
    let job: JobInfo
    let stats: LiveStats
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.phase.isEmpty ? "Starting…" : job.phase).font(.callout.weight(.medium))
                Spacer()
                Text(stats.fraction.formatted(.percent.precision(.fractionLength(0)))).font(.callout.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: stats.fraction).progressViewStyle(.linear)
            if compact {
                Text(compactLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                    if stats.hashing {
                        GridRow {
                            cell("Checksummed (both NASes)", "\(Int(stats.done).formatted()) of \(Int(stats.total).formatted()) files")
                            cell("Left", "\(Int(max(0, stats.total - stats.done)).formatted()) files")
                            cell("Speed", stats.rate.map { "\(Int($0).formatted()) files/s" } ?? "measuring…")
                        }
                    } else {
                        GridRow {
                            cell("Sent", "\(fmtBytes(Int64(stats.done))) of \(fmtBytes(Int64(stats.total)))")
                            cell("Left", fmtBytes(Int64(max(0, stats.total - stats.done))))
                            cell("Speed", stats.rate.map { "\(fmtBytes(Int64($0)))/s" } ?? "measuring…")
                        }
                    }
                    GridRow {
                        cell("Elapsed", fmtDuration(stats.elapsed))
                        cell("Remaining", stats.remaining.map { "about " + fmtDuration($0) } ?? "—")
                        cell("Files copied", "\(job.doneFiles.formatted()) of \(job.totalFiles.formatted())")
                    }
                }
                if job.phase.hasPrefix("Copying"), job.verifyPending {
                    Text("After copying, every file is checksummed on both NASes (roughly as long again).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var compactLine: String {
        var parts: [String] = []
        if stats.hashing {
            parts.append("\(Int(stats.done).formatted()) of \(Int(stats.total).formatted()) files checksummed")
            if let r = stats.rate { parts.append("\(Int(r)) files/s") }
        } else {
            parts.append("\(fmtBytes(Int64(stats.done))) of \(fmtBytes(Int64(stats.total)))")
            if let r = stats.rate { parts.append("\(fmtBytes(Int64(r)))/s") }
        }
        parts.append(fmtDuration(stats.elapsed) + " elapsed")
        if let rem = stats.remaining { parts.append("about \(fmtDuration(rem)) left") }
        return parts.joined(separator: " · ")
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

/// Running jobs, pinned to the bottom of every screen.
struct ActiveJobsBar: View {
    @EnvironmentObject var store: JobStore
    var showJobs: () -> Void

    var body: some View {
        let running = store.jobs.filter { $0.isRunning || $0.state == "starting" }
        if !running.isEmpty {
            VStack(spacing: 8) {
                ForEach(running) { job in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            LiveProgress(job: job, stats: store.stats(job), compact: true)
                        }
                        Button("Details", action: showJobs).controlSize(.small)
                    }
                }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
