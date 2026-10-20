import SwiftUI

enum DiffKind: String, CaseIterable, Identifiable {
    case onlyA, onlyB, newerA, newerB, conflict, likelySame, identical
    var id: String { rawValue }

    func label(_ a: String, _ b: String) -> String {
        switch self {
        case .onlyA: return "Only on \(a)"
        case .onlyB: return "Only on \(b)"
        case .newerA: return "Newer on \(a)"
        case .newerB: return "Newer on \(b)"
        case .conflict: return "Conflict"
        case .likelySame: return "Same size, dates differ"
        case .identical: return "Identical"
        }
    }
    var color: Color {
        switch self {
        case .onlyA, .onlyB: return .green
        case .newerA, .newerB: return .blue
        case .conflict: return .red
        case .likelySame: return .orange
        case .identical: return .secondary
        }
    }
    var help: String {
        switch self {
        case .conflict: return "Both copies were modified at the same time but differ. Pick which one wins."
        case .likelySame: return "Probably the same file with a different timestamp. Use “Check contents” to be sure."
        default: return ""
        }
    }
    var defaultAction: UnifyAction {
        switch self {
        case .onlyA, .newerA: return .copyToB
        case .onlyB, .newerB: return .copyToA
        default: return .skip
        }
    }
    var allowed: [UnifyAction] {
        switch self {
        case .onlyA: return [.copyToB, .recycleA, .skip]
        case .onlyB: return [.copyToA, .recycleB, .skip]
        case .newerA, .newerB, .conflict, .likelySame: return [.copyToB, .copyToA, .skip]
        case .identical: return [.skip]
        }
    }
}

enum UnifyAction: String, CaseIterable, Identifiable {
    case copyToB, copyToA, recycleA, recycleB, skip
    var id: String { rawValue }
    func label(_ a: String, _ b: String) -> String {
        switch self {
        case .copyToB: return "Copy \(a) → \(b)"
        case .copyToA: return "Copy \(b) → \(a)"
        case .recycleA: return "Recycle on \(a)"
        case .recycleB: return "Recycle on \(b)"
        case .skip: return "Leave as is"
        }
    }
}

struct DiffItem: Identifiable, Hashable {
    var path: String
    var a: FileEntry?
    var b: FileEntry?
    var kind: DiffKind
    var action: UnifyAction
    var id: String { path }
    var top: String { path.split(separator: "/").count > 1 ? String(path.split(separator: "/")[0]) : "(top level)" }
    var size: Int64 { max(a?.size ?? 0, b?.size ?? 0) }

    static func == (l: DiffItem, r: DiffItem) -> Bool { l.path == r.path && l.action == r.action && l.kind == r.kind }
    func hash(into h: inout Hasher) { h.combine(path) }
}

extension FileEntry: Hashable {
    static func == (l: FileEntry, r: FileEntry) -> Bool { l.size == r.size && l.mtime == r.mtime }
    func hash(into h: inout Hasher) { h.combine(size); h.combine(mtime) }
}

@MainActor
final class UnifyModel: ObservableObject {
    @Published var a: Location?
    @Published var b: Location?
    @Published var items: [DiffItem] = []
    @Published var identicalCount = 0
    @Published var status: String?
    @Published var busy = false
    @Published var error: String?
    @Published var compared: (Location, Location)?

    /// Timestamps within this many seconds count as equal (FAT/exFAT cards round to 2 s).
    let tolerance: Int64 = 2

    var nameA: String { label(a, other: b) }
    var nameB: String { label(b, other: a) }

    private func label(_ l: Location?, other: Location?) -> String {
        guard let l else { return "?" }
        if let o = other, o.host == l.host { return l.host.name + " (" + l.displayName + ")" }
        return l.host.name
    }

    func compare() async {
        guard let a, let b else { return }
        busy = true
        error = nil
        status = "Indexing both sides…"
        do {
            async let ia = NAS.index(a)
            async let ib = NAS.index(b)
            let (ma, mb) = try await (ia, ib)
            status = "Comparing \(ma.count.formatted()) and \(mb.count.formatted()) files…"
            var out: [DiffItem] = []
            var same = 0
            for (path, ea) in ma {
                guard let eb = mb[path] else {
                    out.append(DiffItem(path: path, a: ea, b: nil, kind: .onlyA, action: .copyToB)); continue
                }
                let dt = ea.mtime - eb.mtime
                let kind: DiffKind
                if ea.size == eb.size {
                    if abs(dt) <= tolerance { same += 1; continue }
                    kind = .likelySame
                } else if abs(dt) <= tolerance {
                    kind = .conflict
                } else {
                    kind = dt > 0 ? .newerA : .newerB
                }
                out.append(DiffItem(path: path, a: ea, b: eb, kind: kind, action: kind.defaultAction))
            }
            for (path, eb) in mb where ma[path] == nil {
                out.append(DiffItem(path: path, a: nil, b: eb, kind: .onlyB, action: .copyToA))
            }
            items = out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            identicalCount = same
            compared = (a, b)
            status = nil
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        busy = false
    }

    /// Checksums the "same size, dates differ" files and reclassifies them.
    func checkContents() async {
        guard let (a, b) = compared else { return }
        let paths = items.filter { $0.kind == .likelySame }.map(\.path)
        guard !paths.isEmpty else { return }
        busy = true
        status = "Checksumming \(paths.count.formatted()) files on both NASes…"
        do {
            let differs = try await NAS.contentDiffers(a: a, b: b, paths: paths)
            var keep: [DiffItem] = []
            var nowSame = 0
            for var i in items {
                if i.kind == .likelySame {
                    if differs.contains(i.path) {
                        let dt = (i.a?.mtime ?? 0) - (i.b?.mtime ?? 0)
                        i.kind = dt > 0 ? .newerA : .newerB
                        i.action = i.kind.defaultAction
                    } else {
                        nowSame += 1
                        continue
                    }
                }
                keep.append(i)
            }
            items = keep
            identicalCount += nowSame
        } catch {
            self.error = error.localizedDescription
        }
        status = nil
        busy = false
    }

    func setAction(_ action: UnifyAction, for ids: Set<String>) {
        for idx in items.indices where ids.contains(items[idx].path) && items[idx].kind.allowed.contains(action) {
            items[idx].action = action
        }
    }

    func count(_ k: DiffKind) -> Int { items.lazy.filter { $0.kind == k }.count }

    struct Plan {
        var toB: [DiffItem] = [], toA: [DiffItem] = [], recycleA: [DiffItem] = [], recycleB: [DiffItem] = []
        var isEmpty: Bool { toB.isEmpty && toA.isEmpty && recycleA.isEmpty && recycleB.isEmpty }
    }

    var plan: Plan {
        var p = Plan()
        for i in items {
            switch i.action {
            case .copyToB: p.toB.append(i)
            case .copyToA: p.toA.append(i)
            case .recycleA: p.recycleA.append(i)
            case .recycleB: p.recycleB.append(i)
            case .skip: break
            }
        }
        return p
    }

    func start() async throws {
        guard let (a, b) = compared else { return }
        let p = plan
        let id = NAS.newJobID("unify")
        var job = JobSpec(id: id, title: "Unify: \(a.breadcrumb)  ⇄  \(b.breadcrumb)", runner: NAS.runner(a.host, b.host))
        if !p.toB.isEmpty {
            job.lists["a_to_b.list"] = p.toB.map(\.path)
            job.copies.append(CopyStep(from: a, to: b.fullPath, toHost: b.host, list: "a_to_b.list", backup: b.recycleDir(job: id), update: false))
        }
        if !p.toA.isEmpty {
            job.lists["b_to_a.list"] = p.toA.map(\.path)
            job.copies.append(CopyStep(from: b, to: a.fullPath, toHost: a.host, list: "b_to_a.list", backup: a.recycleDir(job: id), update: false))
        }
        if !p.recycleA.isEmpty {
            job.lists["recycle_a.list"] = p.recycleA.map(\.path)
            job.recycles.append(RecycleStep(host: a.host, root: a.fullPath, dest: a.recycleDir(job: id), list: "recycle_a.list"))
        }
        if !p.recycleB.isEmpty {
            job.lists["recycle_b.list"] = p.recycleB.map(\.path)
            job.recycles.append(RecycleStep(host: b.host, root: b.fullPath, dest: b.recycleDir(job: id), list: "recycle_b.list"))
        }
        let copies = p.toA + p.toB
        job.totalFiles = copies.count
        job.totalBytes = copies.reduce(0) { $0 + $1.size }
        job.verify = true
        try await NAS.start(job)
        items = []
        compared = nil
    }
}

struct UnifyView: View {
    var showJobs: () -> Void
    @StateObject private var model = UnifyModel()
    @EnvironmentObject var shares: ShareStore
    @EnvironmentObject var jobs: JobStore

    var body: some View {
        Group {
            if model.compared == nil { setup } else { review }
        }
        .padding(20)
        .navigationTitle("Unify")
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare two copies of the same folder, review every difference, then make both sides match. Nothing changes until you approve the plan, and anything replaced or removed goes to that NAS's recycle bin.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    LocationPicker(title: "Side A", location: $model.a, defaultHost: .qnap)
                    Button("Find the matching folder on the other NAS →") { Task { await matchOther() } }
                        .disabled(model.a == nil)
                }
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 120)
                LocationPicker(title: "Side B", location: $model.b, defaultHost: .unas)
            }
            Divider()
            HStack {
                if let s = model.status { ProgressView().controlSize(.small); Text(s) }
                if let e = model.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                Spacer()
                Button("Compare") { Task { await model.compare() } }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.a == nil || model.b == nil || model.busy || model.a == model.b)
            }
        }
    }

    private func matchOther() async {
        guard let a = model.a else { return }
        let other = a.host.other
        guard let share = shares.list(other).first(where: { $0.matchKey == a.share.matchKey }) else {
            model.error = "No share named like “\(a.share.name)” on the \(other.name)."
            return
        }
        model.error = nil
        // Walk down the same path as far as it exists.
        var loc = Location(share: share)
        for part in a.rel.split(separator: "/") {
            let next = loc.child(String(part))
            if (try? await NAS.exists(other, next.fullPath)) == true { loc = next } else {
                model.error = "Matched down to “\(loc.displayName)”; “\(part)” doesn't exist on the \(other.name)."
                break
            }
        }
        model.b = loc
    }

    // MARK: Review

    @State private var kindFilter: DiffKind?
    @State private var folderFilter: String = ""
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var confirm = false
    @State private var startError: String?

    private var visible: [DiffItem] {
        model.items.filter { i in
            (kindFilter == nil || i.kind == kindFilter) &&
            (folderFilter.isEmpty || i.top == folderFilter) &&
            (search.isEmpty || i.path.localizedCaseInsensitiveContains(search))
        }
    }

    private var folders: [(String, Int)] {
        Dictionary(grouping: model.items, by: \.top).map { ($0.key, $0.value.count) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private var review: some View {
        let A = model.nameA, B = model.nameB
        let plan = model.plan
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("A: " + (model.compared?.0.breadcrumb ?? "")).font(.callout)
                    Text("B: " + (model.compared?.1.breadcrumb ?? "")).font(.callout)
                }
                .textSelection(.enabled)
                Spacer()
                Button("Start Over") { model.compared = nil; model.items = []; selection = [] }
                Button("Re-compare") { Task { await model.compare() } }.disabled(model.busy)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip(nil, "All differences", model.items.count, .primary)
                    ForEach(DiffKind.allCases.filter { $0 != .identical }) { k in
                        let c = model.count(k)
                        if c > 0 { chip(k, k.label(A, B), c, k.color) }
                    }
                    Text("\(model.identicalCount.formatted()) identical (hidden)").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Picker("Folder", selection: $folderFilter) {
                    Text("All folders").tag("")
                    ForEach(folders, id: \.0) { f in Text("\(f.0)  (\(f.1))").tag(f.0) }
                }
                .frame(maxWidth: 320)
                TextField("Search paths", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                if model.count(.likelySame) > 0 {
                    Button("Check contents of \(model.count(.likelySame)) same-size files") { Task { await model.checkContents() } }
                        .disabled(model.busy)
                        .help("Checksums them on both NASes. Identical ones drop off the list.")
                }
                Menu("Set action for \(selection.isEmpty ? "all shown" : "\(selection.count) selected")") {
                    ForEach(UnifyAction.allCases) { act in
                        Button(act.label(A, B)) {
                            model.setAction(act, for: selection.isEmpty ? Set(visible.map(\.path)) : selection)
                        }
                    }
                }
                .frame(width: 230)
            }

            Table(visible, selection: $selection) {
                TableColumn("Path") { i in
                    Text(i.path).lineLimit(1).truncationMode(.middle).help(i.path)
                }
                .width(min: 240, ideal: 420)
                TableColumn(A) { i in sideCell(i.a) }.width(min: 140, ideal: 170)
                TableColumn(B) { i in sideCell(i.b) }.width(min: 140, ideal: 170)
                TableColumn("Difference") { i in
                    Text(i.kind.label(A, B)).foregroundStyle(i.kind.color).help(i.kind.help)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Action") { i in
                    Picker("", selection: actionBinding(i)) {
                        ForEach(i.kind.allowed) { Text($0.label(A, B)).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 170, ideal: 190)
            }

            HStack(alignment: .center) {
                if let s = model.status { ProgressView().controlSize(.small); Text(s) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan").font(.caption).foregroundStyle(.secondary)
                    Text(planSummary(plan, A, B)).font(.callout.weight(.medium))
                }
                Spacer()
                if let e = startError ?? model.error { Text(e).foregroundStyle(.red) }
                Button("Unify…") { confirm = true }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty || model.busy)
            }
        }
        .confirmationDialog("Run this plan?", isPresented: $confirm) {
            Button("Unify") {
                Task {
                    do { try await model.start(); await jobs.refresh(); showJobs() } catch { startError = error.localizedDescription }
                }
            }
        } message: {
            Text(planSummary(plan, A, B) + "\n\nEvery copied file is verified. Anything overwritten or recycled goes to that NAS's recycle bin under “NAS Mover”.")
        }
    }

    private func planSummary(_ p: UnifyModel.Plan, _ A: String, _ B: String) -> String {
        if p.isEmpty { return "Nothing to do. Choose actions above." }
        var parts: [String] = []
        func size(_ x: [DiffItem]) -> String { fmtBytes(x.reduce(0) { $0 + $1.size }) }
        if !p.toB.isEmpty { parts.append("copy \(p.toB.count.formatted()) to \(B) (\(size(p.toB)))") }
        if !p.toA.isEmpty { parts.append("copy \(p.toA.count.formatted()) to \(A) (\(size(p.toA)))") }
        if !p.recycleA.isEmpty { parts.append("recycle \(p.recycleA.count.formatted()) on \(A)") }
        if !p.recycleB.isEmpty { parts.append("recycle \(p.recycleB.count.formatted()) on \(B)") }
        let s = parts.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func chip(_ k: DiffKind?, _ label: String, _ count: Int, _ color: Color) -> some View {
        Button { kindFilter = k; selection = [] } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(kindFilter == k ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func sideCell(_ e: FileEntry?) -> some View {
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

    private func actionBinding(_ item: DiffItem) -> Binding<UnifyAction> {
        Binding(
            get: { item.action },
            set: { model.setAction($0, for: [item.path]) }
        )
    }
}
