import SwiftUI

/// A file browser for either NAS: tick files and folders, see their sizes, and delete them
/// (into the share's _NAS Mover Recycle, which you empty later from Recycle Folders).
struct BrowseView: View {
    var showJobs: () -> Void

    @EnvironmentObject var shares: ShareStore
    @State private var host: HostID = .qnap
    @State private var location: Location?
    @State private var entries: [Entry] = []
    @State private var selection = Set<String>()
    @State private var filter = ""
    @State private var loading = false
    @State private var sizing = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmDelete = false
    @State private var showRecycle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("NAS", selection: $host) {
                    ForEach(HostID.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                Picker("Share", selection: shareBinding) {
                    Text("Choose a share…").tag(Share?.none)
                    ForEach(shares.list(host)) { s in Text(s.name).tag(Share?.some(s)) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                Button { showRecycle = true } label: { Label("Recycle Folders…", systemImage: "trash") }
            }

            if let loc = location {
                HStack(spacing: 6) {
                    Button { open(loc.parent) } label: { Image(systemName: "chevron.left") }
                        .disabled(loc.parent == nil)
                        .help("Up one folder")
                    Text(loc.breadcrumb).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Spacer()
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }

                Table(visible, selection: $selection) {
                    TableColumn("") { e in
                        Toggle("", isOn: checked(e.name)).toggleStyle(.checkbox).labelsHidden()
                    }
                    .width(22)
                    TableColumn("Name") { e in
                        HStack(spacing: 6) {
                            Image(systemName: e.isDir ? "folder.fill" : "doc").foregroundStyle(e.isDir ? .blue : .secondary)
                            Text(e.name).lineLimit(1).truncationMode(.middle)
                        }
                        .help(e.isDir ? "Double-click to open" : e.name)
                    }
                    .width(min: 260, ideal: 480)
                    TableColumn("Size") { e in
                        Text(e.size.map(fmtBytes) ?? (e.isDir ? "—" : "")).monospacedDigit().foregroundStyle(e.size == nil ? .secondary : .primary)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Modified") { e in
                        Text(e.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 160)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let e = entries.first(where: { $0.name == ids.first }), e.isDir {
                        Button("Open") { open(loc.child(e.name)) }
                    }
                    Button("Calculate Size") { Task { await measure(Array(ids)) } }
                    if !inRecycle {
                        Divider()
                        Button("Delete…", role: .destructive) { selection = ids; confirmDelete = true }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let e = entries.first(where: { $0.name == ids.first }), e.isDir { open(loc.child(e.name)) }
                }
                .onDeleteCommand { if !selection.isEmpty && !inRecycle { confirmDelete = true } }
                .overlay {
                    if loading { ProgressView() }
                    else if entries.isEmpty && error == nil { Text("Empty folder").foregroundStyle(.secondary) }
                }

                HStack(spacing: 12) {
                    if let error { Text(error).foregroundStyle(.red).lineLimit(2) }
                    else if let notice {
                        Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green).lineLimit(2)
                        Button("Recycle Folders…") { showRecycle = true }.buttonStyle(.link)
                    } else {
                        Text(selectionSummary).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if sizing || working { ProgressView().controlSize(.small) }
                    Button("Calculate Sizes") { Task { await measure(selection.isEmpty ? entries.filter(\.isDir).map(\.name) : Array(selection)) } }
                        .disabled(sizing || entries.isEmpty)
                        .help(selection.isEmpty ? "Measure every folder here" : "Measure the selected items")
                    if inRecycle {
                        Button("Empty in Recycle Folders…") { showRecycle = true }
                    } else {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty || working)
                    }
                }
            } else {
                ContentUnavailableView("Choose a share", systemImage: "externaldrive.connected.to.line.below",
                                       description: Text("Browse either NAS, tick files and folders, and delete them. Deleted items go to that share's “_NAS Mover Recycle” folder until you empty it."))
            }
        }
        .padding(20)
        .navigationTitle("Browse")
        .onChange(of: host) { _, h in if location?.host != h { location = nil; entries = []; selection = [] } }
        .task(id: location) { await load() }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Move to _NAS Mover Recycle", role: .destructive) { Task { await delete() } }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showRecycle) { RecycleSheet(showJobs: showJobs, browse: { loc in showRecycle = false; open(loc) }) }
    }

    /// Inside a recycle folder, items are emptied (permanently) from Recycle Folders, not deleted again.
    private var inRecycle: Bool { location?.rel.split(separator: "/").first.map(String.init) == Share.recycleFolder }

    private var visible: [Entry] {
        filter.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var shareBinding: Binding<Share?> {
        Binding(
            get: { location?.host == host ? location?.share : nil },
            set: { s in open(s.map { Location(share: $0) }) }
        )
    }

    private func checked(_ name: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(name) },
            set: { on in if on { selection.insert(name) } else { selection.remove(name) } }
        )
    }

    private var selected: [Entry] { entries.filter { selection.contains($0.name) } }

    private var selectionSummary: String {
        if selection.isEmpty { return "\(entries.filter(\.isDir).count) folders · \(entries.filter { !$0.isDir }.count) files" }
        let known = selected.compactMap(\.size).reduce(0, +)
        let unmeasured = selected.filter { $0.size == nil }.count
        var s = "\(selection.count) selected · \(fmtBytes(known))"
        if unmeasured > 0 { s += " + \(unmeasured) folder\(unmeasured == 1 ? "" : "s") not measured" }
        return s
    }

    private var deleteTitle: String {
        "Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?"
    }

    private var deleteMessage: String {
        let names = selected.prefix(6).map(\.name).joined(separator: "\n")
        let more = selected.count > 6 ? "\n…and \(selected.count - 6) more" : ""
        let size = selected.contains { $0.size == nil } ? "" : " (\(fmtBytes(selected.compactMap(\.size).reduce(0, +))))"
        let share = location?.share.name ?? "the share"
        return "\(names)\(more)\n\nThey move instantly into “\(share) › _NAS Mover Recycle”\(size). The space is freed when you empty it from Recycle Folders."
    }

    private func open(_ loc: Location?) {
        filter = ""
        selection = []
        notice = nil
        location = loc
        if let loc { host = loc.host }
    }

    private func load() async {
        guard let loc = location else { entries = []; return }
        loading = true
        error = nil
        do {
            let fresh = try await NAS.entries(loc)
            let known = Dictionary(entries.compactMap { e in e.isDir ? e.size.map { (e.name, $0) } : nil }, uniquingKeysWith: { a, _ in a })
            entries = fresh.map { e in var e = e; if e.isDir, let s = known[e.name] { e.size = s }; return e }
            selection = selection.filter { n in entries.contains { $0.name == n } }
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func measure(_ names: [String]) async {
        guard let loc = location, !names.isEmpty else { return }
        sizing = true
        do {
            let sizes = try await NAS.sizes(loc, names)
            for i in entries.indices { if let s = sizes[entries[i].name] { entries[i].size = s } }
        } catch { self.error = error.localizedDescription }
        sizing = false
    }

    private func delete() async {
        guard let loc = location, !selection.isEmpty else { return }
        working = true
        error = nil
        let names = selected.map(\.name)
        do {
            try await NAS.moveToRecycle(loc, names)
            notice = "Moved \(names.count) item\(names.count == 1 ? "" : "s") to _NAS Mover Recycle."
            selection = []
            entries.removeAll { names.contains($0.name) }
            await load()
        } catch {
            self.error = "Couldn't delete everything: \(error.localizedDescription)"
            await load()
        }
        working = false
    }
}

/// Each share's _NAS Mover Recycle: what's in it, how big, and a way to empty it for good.
struct RecycleSheet: View {
    var showJobs: () -> Void
    var browse: (Location) -> Void

    @EnvironmentObject var shares: ShareStore
    @EnvironmentObject var jobs: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var bins: [RecycleBin] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pending: (RecycleBin, [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recycle Folders").font(.title2.bold())
            Text("Everything NAS Mover has moved aside: Move originals, replaced files and deleted items. Nothing here is removed until you empty it.")
                .foregroundStyle(.secondary)

            if loading {
                HStack { ProgressView().controlSize(.small); Text("Measuring recycle folders on both NASes…") }
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if bins.isEmpty {
                ContentUnavailableView("Nothing to empty", systemImage: "trash.slash", description: Text(error ?? "No share has anything in _NAS Mover Recycle."))
                    .frame(minHeight: 200)
            } else {
                List {
                    ForEach(bins) { bin in
                        Section {
                            ForEach(bin.items, id: \.name) { item in
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(fmtBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button("Empty…") { pending = (bin, [item.name]) }.controlSize(.small)
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(bin.share.host.name) › \(bin.share.name)").font(.headline)
                                Text(fmtBytes(bin.total)).monospacedDigit().foregroundStyle(.secondary)
                                Spacer()
                                Button("Show") { browse(Location(share: bin.share, rel: Share.recycleFolder)) }.controlSize(.small)
                                Button("Empty All…") { pending = (bin, bin.items.map(\.name)) }.controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minHeight: 300)
            }
            HStack {
                if let error, !bins.isEmpty { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(loading)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Delete Permanently", role: .destructive) { Task { await empty() } }
        } message: {
            Text("This permanently deletes it from the \(pending?.0.share.host.name ?? "NAS"). It can't be undone.")
        }
    }

    private var confirmTitle: String {
        guard let (bin, names) = pending else { return "" }
        let size = bin.items.filter { names.contains($0.name) }.reduce(Int64(0)) { $0 + $1.size }
        let what = names.count == bin.items.count ? "everything in \(bin.share.name) › _NAS Mover Recycle" : "“\(names[0])”"
        return "Permanently delete \(what) (\(fmtBytes(size)))?"
    }

    private func load() async {
        loading = true
        error = nil
        var all: [RecycleBin] = []
        for h in HostID.allCases {
            do { all += try await NAS.recycleBins(h, shares: shares.list(h)) } catch { self.error = error.localizedDescription }
        }
        bins = all
        loading = false
    }

    private func empty() async {
        guard let (bin, names) = pending else { return }
        pending = nil
        do {
            try await NAS.emptyRecycle(bin, names: names)
            await jobs.refresh()
            dismiss()
            showJobs()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
