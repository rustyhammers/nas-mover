import SwiftUI

/// Pick a NAS and a share, then browse folders.
/// - Single mode (`checked == nil`): the folder you're looking at is the selection.
/// - Checkbox mode: tick any folders (across different places); clicking a name opens it.
struct LocationPicker: View {
    let title: String
    @Binding var location: Location?
    var checked: Binding<[Location]>? = nil
    var defaultHost: HostID = .qnap

    @EnvironmentObject var shares: ShareStore
    @State private var host: HostID = .qnap
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""

    private var multi: Bool { checked != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Picker("NAS", selection: $host) {
                ForEach(HostID.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Share", selection: shareBinding) {
                Text("Choose a share…").tag(Share?.none)
                ForEach(shares.list(host)) { s in Text(s.name).tag(Share?.some(s)) }
            }
            .labelsHidden()

            if let loc = location, loc.host == host {
                HStack(spacing: 6) {
                    Button { location = loc.parent } label: { Image(systemName: "chevron.left") }
                        .disabled(loc.parent == nil)
                        .help("Up one folder")
                    if multi && !loc.rel.isEmpty {
                        Toggle("", isOn: isChecked(loc)).toggleStyle(.checkbox).labelsHidden()
                            .help("Select this folder")
                    }
                    Text(loc.breadcrumb)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(multi ? 0.06 : 0.12)))

                HStack {
                    TextField("Filter folders", text: $filter).textFieldStyle(.roundedBorder)
                    if multi && !filteredFolders.isEmpty {
                        Button(allShownChecked(loc) ? "Clear All" : "Select All") { toggleAll(loc) }
                            .controlSize(.small)
                    }
                }

                ZStack {
                    List(filteredFolders, id: \.self) { name in
                        HStack(spacing: 8) {
                            if multi {
                                Toggle("", isOn: isChecked(loc.child(name))).toggleStyle(.checkbox).labelsHidden()
                            }
                            Button { location = loc.child(name); filter = "" } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                                    Text(name)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(name)")
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    if loading { ProgressView() }
                    else if let error { Text(error).foregroundStyle(.red).padding() }
                    else if folders.isEmpty { Text("No subfolders").foregroundStyle(.secondary) }
                }

                if let checked, !checked.wrappedValue.isEmpty {
                    SelectedChips(items: checked)
                }
            } else {
                Spacer()
                Text("Choose a share to browse.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onAppear { host = location?.host ?? defaultHost }
        .onChange(of: host) { _, h in if location != nil && location?.host != h { location = nil } }
        .onChange(of: location) { _, l in if let l, l.host != host { host = l.host } }
        .task(id: location) { await load() }
    }

    private var filteredFolders: [String] {
        filter.isEmpty ? folders : folders.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var shareBinding: Binding<Share?> {
        Binding(
            get: { location?.host == host ? location?.share : nil },
            set: { s in location = s.map { Location(share: $0) } }
        )
    }

    private func isChecked(_ l: Location) -> Binding<Bool> {
        Binding(
            get: { checked?.wrappedValue.contains(l) ?? false },
            set: { on in
                guard let checked else { return }
                if on {
                    if !checked.wrappedValue.contains(l) { checked.wrappedValue.append(l) }
                } else {
                    checked.wrappedValue.removeAll { $0 == l }
                }
            }
        )
    }

    private func allShownChecked(_ loc: Location) -> Bool {
        guard let checked else { return false }
        return filteredFolders.allSatisfy { checked.wrappedValue.contains(loc.child($0)) }
    }

    private func toggleAll(_ loc: Location) {
        guard let checked else { return }
        let items = filteredFolders.map { loc.child($0) }
        if allShownChecked(loc) {
            checked.wrappedValue.removeAll { items.contains($0) }
        } else {
            for i in items where !checked.wrappedValue.contains(i) { checked.wrappedValue.append(i) }
        }
    }

    private func load() async {
        guard let loc = location else { folders = []; return }
        loading = true
        error = nil
        do { folders = try await NAS.folders(loc) } catch {
            folders = []
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The ticked folders, each removable.
struct SelectedChips: View {
    @Binding var items: [Location]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(items.count) selected").font(.caption.weight(.semibold))
                Spacer()
                Button("Clear") { items.removeAll() }.controlSize(.small).buttonStyle(.link)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items, id: \.self) { l in
                        HStack(spacing: 6) {
                            Button { items.removeAll { $0 == l } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(l.breadcrumb).font(.caption).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            .frame(maxHeight: 90)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
    }
}
