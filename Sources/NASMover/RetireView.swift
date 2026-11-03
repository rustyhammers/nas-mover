import SwiftUI

/// What Retire does with a file from the stale copy.
enum RetireAction: String, CaseIterable, Identifiable {
    case copy, beside, replace, leave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .copy: return "Copy to live"
        case .beside: return "Copy beside live file"
        case .replace: return "Replace live file"
        case .leave: return "Leave (retired with it)"
        }
    }
    var help: String {
        switch self {
        case .copy: return "Copies it to the same path on the live side."
        case .beside: return "Keeps both: the stale version lands next to the live file with “(from …)” added to its name."
        case .replace: return "The stale version replaces the live file; the live version goes to _NAS Mover Recycle."
        case .leave: return "Not copied. It goes to _NAS Mover Recycle along with the rest of the stale copy."
        }
    }
}

extension DiffKind {
    /// How Retire describes a difference (A = stale, B = live).
    var retireLabel: String {
        switch self {
        case .onlyA: return "Missing from live"
        case .newerA: return "Stale copy is newer"
        case .newerB: return "Live copy is newer"
        case .conflict: return "Differs (same date)"
        case .damaged: return "Contents differ"
        case .likelySame: return "Not checked"
        case .moved: return "Moved, not checked"
        case .onlyB, .identical: return ""
        }
    }
    var retireDefault: RetireAction {
        switch self {
        case .onlyA: return .copy
        case .newerB: return .leave
        default: return .beside
        }
    }
    var retireAllowed: [RetireAction] {
        switch self {
        case .onlyA: return [.copy, .leave]
        case .newerB: return [.leave, .beside, .replace]
        default: return [.beside, .replace, .leave]
        }
    }
}

@MainActor
final class RetireModel: ObservableObject {
    @Published var stale: Location?
    @Published var live: Location?
    @Published var scanned: (stale: Location, live: Location)?
    @Published var items: [DiffItem] = []
    @Published var actions: [String: RetireAction] = [:]
    @Published var identical = 0
    @Published var movedOK = 0
    @Published var newOnLive = 0
    @Published var newestStale: Date?
    @Published var checked: Comparison.Checked?
    @Published var retireWhenDone = true
    @Published var status: String?
    @Published var busy = false
    @Published var error: String?
    let checksum = ChecksumTracker()

    private var ma: [String: FileEntry] = [:]
    private var mb: [String: FileEntry] = [:]
    private var result = Comparison.Result(items: [], identical: [])
    let tolerance: Int64 = 2

    /// The files that need a decision (everything else is already safely on the live side, or only on it).
    var needsAction: [DiffItem] { items.filter { !($0.kind == .onlyB || ($0.kind == .moved && $0.verified)) } }

    var suffix: String {
        guard let s = scanned else { return " (from old copy)" }
        return s.stale.host == s.live.host ? " (from old copy)" : " (from \(s.stale.host.name))"
    }

    /// Why the stale copy can't be retired yet, if it can't.
    var retireBlocker: String? {
        guard let c = checked else { return "Checksum both sides first." }
        if c.unreadable > 0 { return "\(c.unreadable) file(s) couldn't be checksummed (unreadable, or changed since). Run the checksum again." }
        return nil
    }

    func scan() async {
        guard let a = stale, let b = live else { return }
        busy = true
        error = nil
        status = "Indexing both sides…"
        checksum.reset()
        checked = nil
        do {
            async let ia = NAS.index(a)
            async let ib = NAS.index(b)
            (ma, mb) = try await (ia, ib)
            result = Comparison.build(ma, mb, tolerance: tolerance)
            let now = Date().timeIntervalSince1970
            newestStale = ma.values.map(\.mtime).filter { Double($0) < now }.max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
            scanned = (a, b)
            publish()
            status = nil
            // The checksum is the point of Retire: start it straight away, unless a run for this pair is already on file.
            if ChecksumTracker.previous(a, b) == nil { await startChecksum() }
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        busy = false
    }

    func startChecksum() async {
        guard let s = scanned else { return }
        await checksum.start(s.stale, s.live, title: "Checksum (Retire): \(s.stale.breadcrumb)  →  \(s.live.breadcrumb)") { [weak self] in self?.use($0) }
    }

    func usePrevious() {
        guard let s = scanned, let j = ChecksumTracker.previous(s.stale, s.live) else { return }
        checksum.follow(j) { [weak self] in self?.use($0) }
    }

    private func use(_ sums: ChecksumResults) {
        checked = Comparison.apply(&result, ma: ma, mb: mb, sums: sums)
        publish()
    }

    private func publish() {
        items = result.items
        identical = result.identical.count
        movedOK = items.filter { $0.kind == .moved && $0.verified }.count
        newOnLive = items.filter { $0.kind == .onlyB }.count
        var keep: [String: RetireAction] = [:]
        for i in needsAction { keep[i.id] = actions[i.id].flatMap { i.kind.retireAllowed.contains($0) ? $0 : nil } ?? i.kind.retireDefault }
        actions = keep
    }

    func set(_ a: RetireAction, for ids: Set<String>) {
        for i in needsAction where ids.contains(i.id) && i.kind.retireAllowed.contains(a) { actions[i.id] = a }
    }

    struct Plan {
        var copy: [DiffItem] = [], beside: [DiffItem] = [], replace: [DiffItem] = [], leave: [DiffItem] = []
        var bytes: Int64 { (copy + beside + replace).reduce(0) { $0 + ($1.a?.size ?? 0) } }
    }

    var plan: Plan {
        var p = Plan()
        for i in needsAction {
            switch actions[i.id] ?? i.kind.retireDefault {
            case .copy: p.copy.append(i)
            case .beside: p.beside.append(i)
            case .replace: p.replace.append(i)
            case .leave: p.leave.append(i)
            }
        }
        return p
    }

    func start() async throws {
        guard let (a, b) = scanned else { return }
        let p = plan
        let id = NAS.newJobID("retire")
        var job = JobSpec(id: id, title: "Retire: \(a.breadcrumb)  →  \(b.breadcrumb)", runner: NAS.runner(a.host, b.host))
        let straight = p.copy + p.replace
        if !straight.isEmpty {
            job.lists["copy.list"] = straight.map(\.path)
            job.copies.append(CopyStep(from: a, to: b.fullPath, toHost: b.host, list: "copy.list", backup: b.recycleDir(job: id), update: false))
        }
        if !p.beside.isEmpty {
            let staging = b.fullPath + "/.nasmover-staging-" + id
            job.lists["beside.list"] = p.beside.map(\.path)
            job.copies.append(CopyStep(from: a, to: staging, toHost: b.host, list: "beside.list", backup: b.recycleDir(job: id), update: false))
            job.beside = BesideStep(host: b.host, staging: staging, dest: b.fullPath, suffix: suffix, list: "beside.list")
        }
        if retireWhenDone {
            guard retireBlocker == nil else { throw SSHError(message: retireBlocker!) }
            job.retireCheck = RetireCheck(host: a.host, root: a.fullPath, expected: ma)
            if a.rel.isEmpty {
                job.recycles.append(RecycleStep(host: a.host, root: a.fullPath, dest: a.recycleDir(job: id), list: nil, contents: true))
            } else if let parent = a.parent {
                job.recycles.append(RecycleStep(host: a.host, root: a.fullPath, dest: parent.recycleDir(job: id), list: nil))
            }
        }
        job.totalFiles = straight.count + p.beside.count
        job.totalBytes = p.bytes
        job.verify = true
        try await NAS.start(job)
        reset()
    }

    func reset() {
        scanned = nil
        items = []
        actions = [:]
        checked = nil
        checksum.reset()
    }
}

struct RetireView: View {
    var showJobs: () -> Void
    @ObservedObject var model: RetireModel
    @EnvironmentObject var shares: ShareStore
    @EnvironmentObject var jobs: JobStore

    var body: some View {
        Group {
            if model.scanned == nil { setup } else { review }
        }
        .padding(20)
        .navigationTitle("Retire")
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For a copy you've stopped using. Retire checksums both sides, brings over anything from the stale copy that the live copy is missing or that differs, verifies it, and then moves the stale copy to “_NAS Mover Recycle”. Nothing on the live side is ever overwritten unless you choose to.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    LocationPicker(title: "Stale copy (to retire)", location: $model.stale, defaultHost: .qnap)
                    Button("Find the matching folder on the other NAS →") { Task { await matchOther() } }
                        .disabled(model.stale == nil)
                }
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 120)
                LocationPicker(title: "Live copy (keep)", location: $model.live, defaultHost: .unas)
            }
            Divider()
            HStack {
                if let s = model.status { ProgressView().controlSize(.small); Text(s) }
                if let e = model.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                Spacer()
                Button("Scan & Checksum") { Task { await model.scan() } }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.stale == nil || model.live == nil || model.busy || model.stale == model.live || overlaps)
            }
            if overlaps {
                Label("One folder is inside the other. Pick two separate copies.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private var overlaps: Bool {
        guard let a = model.stale, let b = model.live, a.host == b.host, a != b else { return false }
        return a.fullPath.hasPrefix(b.fullPath + "/") || b.fullPath.hasPrefix(a.fullPath + "/")
    }

    private func matchOther() async {
        guard let a = model.stale else { return }
        let other = a.host.other
        guard let share = shares.list(other).first(where: { $0.matchKey == a.share.matchKey }) else {
            model.error = "No share named like “\(a.share.name)” on the \(other.name)."
            return
        }
        model.error = nil
        var loc = Location(share: share)
        for part in a.rel.split(separator: "/") {
            let next = loc.child(String(part))
            if (try? await NAS.exists(other, next.fullPath)) == true { loc = next } else {
                model.error = "Matched down to “\(loc.displayName)”; “\(part)” doesn't exist on the \(other.name)."
                break
            }
        }
        model.live = loc
    }

    // MARK: Review

    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var confirm = false
    @State private var startError: String?

    private var visible: [DiffItem] {
        let all = model.needsAction
        return search.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    private var review: some View {
        let p = model.plan
        let stale = model.scanned?.stale.host.name ?? "Stale"
        let live = model.scanned?.live.host.name ?? "Live"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stale: " + (model.scanned?.stale.breadcrumb ?? "")).font(.callout)
                    Text("Live: " + (model.scanned?.live.breadcrumb ?? "")).font(.callout)
                    if let d = model.newestStale {
                        Text("Newest file in the stale copy: \(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                Spacer()
                Button("Start Over") { model.reset(); selection = [] }
                Button("Re-scan") { Task { await model.scan() } }.disabled(model.busy || model.checksum.isRunning)
            }

            HStack(spacing: 10) {
                stat("Already on live", model.identical, model.checked == nil ? "same size and date" : "checked", .green)
                stat("Moved / renamed on live", model.movedOK, "checked", .purple)
                stat("Needs a decision", model.needsAction.count, nil, model.needsAction.isEmpty ? .secondary : .orange)
                stat("New on live", model.newOnLive, "not touched", .secondary)
            }

            HStack {
                ChecksumControls(tracker: model.checksum, checked: model.checked,
                                 hasPrevious: model.scanned.map { ChecksumTracker.previous($0.stale, $0.live) != nil } ?? false,
                                 start: { Task { await model.startChecksum() } },
                                 usePrevious: { model.usePrevious() })
                Spacer()
                TextField("Search paths", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Menu("Set action for \(selection.isEmpty ? "all shown" : "\(selection.count) selected")") {
                    ForEach(RetireAction.allCases) { act in
                        Button(act.label) { model.set(act, for: selection.isEmpty ? Set(visible.map(\.id)) : selection) }
                    }
                }
                .frame(width: 230)
            }

            if model.needsAction.isEmpty {
                ContentUnavailableView(model.checked == nil ? "Nothing missing so far" : "Everything is already on the live copy",
                                       systemImage: "checkmark.circle",
                                       description: Text(model.checked == nil
                                                         ? "Every file matches by name, size and date. The checksum confirms the contents."
                                                         : "Every file in the stale copy is on the live side with identical contents."))
            } else {
                Table(visible, selection: $selection) {
                    TableColumn("Path") { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.path).lineLimit(1).truncationMode(.middle).help(i.path)
                            if let bp = i.bPath {
                                Text("\(live): \(bp)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn(stale) { i in side(i.a) }.width(min: 140, ideal: 170)
                    TableColumn(live) { i in side(i.b) }.width(min: 140, ideal: 170)
                    TableColumn("Status") { i in Text(i.kind.retireLabel).foregroundStyle(i.kind.color).help(i.kind.help) }
                        .width(min: 130, ideal: 150)
                    TableColumn("Action") { i in
                        Picker("", selection: Binding(get: { model.actions[i.id] ?? i.kind.retireDefault },
                                                      set: { model.set($0, for: [i.id]) })) {
                            ForEach(i.kind.retireAllowed) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .help((model.actions[i.id] ?? i.kind.retireDefault).help)
                    }
                    .width(min: 180, ideal: 200)
                }
            }

            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Retire the stale copy when done (moves it to _NAS Mover Recycle)", isOn: $model.retireWhenDone)
                    if model.retireWhenDone, let why = model.retireBlocker {
                        Label(why, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary(p)).font(.callout.weight(.medium))
                }
                Spacer()
                if let e = startError ?? model.error { Text(e).foregroundStyle(.red).lineLimit(3) }
                Button(model.retireWhenDone ? "Retire…" : "Copy…") { confirm = true }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.checksum.isRunning
                              || (model.retireWhenDone ? model.retireBlocker != nil : (p.copy.isEmpty && p.beside.isEmpty && p.replace.isEmpty)))
            }
        }
        .confirmationDialog(model.retireWhenDone ? "Retire the stale copy?" : "Copy these files?", isPresented: $confirm) {
            Button(model.retireWhenDone ? "Retire" : "Copy", role: model.retireWhenDone ? .destructive : nil) {
                Task {
                    do { try await model.start(); await jobs.refresh(); showJobs() } catch { startError = error.localizedDescription }
                }
            }
        } message: {
            Text(summary(p) + "\n\nEvery copied file is verified by checksum."
                 + (model.retireWhenDone
                    ? " Then, only if nothing in the stale copy changed since it was checked, it moves to that share's “_NAS Mover Recycle” folder. Nothing is permanently deleted until you empty it."
                    : ""))
        }
    }

    private func summary(_ p: RetireModel.Plan) -> String {
        var parts: [String] = []
        if !p.copy.isEmpty { parts.append("copy \(p.copy.count.formatted()) missing") }
        if !p.beside.isEmpty { parts.append("place \(p.beside.count.formatted()) beside the live files as “…\(model.suffix)”") }
        if !p.replace.isEmpty { parts.append("replace \(p.replace.count.formatted()) live files") }
        if !p.leave.isEmpty { parts.append("leave \(p.leave.count.formatted())") }
        var s = parts.isEmpty ? "Nothing to copy" : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        if p.bytes > 0 { s += " (\(fmtBytes(p.bytes)))" }
        if model.retireWhenDone { s += ", then retire the stale copy." } else { s += "." }
        return s
    }

    private func stat(_ title: String, _ n: Int, _ note: String?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n.formatted()).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(minWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func side(_ e: FileEntry?) -> some View {
        Group {
            if let e {
                Text("\(fmtBytes(e.size)) · \(Date(timeIntervalSince1970: TimeInterval(e.mtime)).formatted(date: .numeric, time: .shortened))")
                    .monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
