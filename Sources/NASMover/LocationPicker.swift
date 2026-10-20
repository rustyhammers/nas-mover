import SwiftUI

/// Pick a NAS, a share, then click into folders. The folder you're looking at is the selection.
struct LocationPicker: View {
    let title: String
    @Binding var location: Location?
    var defaultHost: HostID = .qnap

    @EnvironmentObject var shares: ShareStore
    @State private var host: HostID = .qnap
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var filter = ""

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
                    Text(loc.breadcrumb)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))

                TextField("Filter folders", text: $filter).textFieldStyle(.roundedBorder)

                ZStack {
                    List(filteredFolders, id: \.self) { name in
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
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    if loading { ProgressView() }
                    else if let error { Text(error).foregroundStyle(.red).padding() }
                    else if folders.isEmpty { Text("No subfolders").foregroundStyle(.secondary) }
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
