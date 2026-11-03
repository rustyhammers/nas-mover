import SwiftUI

/// Offload cards (in the QNAP's readers) and audio (on this Mac) into a new shoot folder, verified,
/// with checks that catch a missing card before anything gets formatted.
struct IngestView: View {
    var showJobs: () -> Void
    @ObservedObject var model: IngestModel
    @ObservedObject var templates: TemplateStore
    @EnvironmentObject var shares: ShareStore
    @EnvironmentObject var jobs: JobStore
    @State private var showIngest = false
    @State private var showTemplates = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("Put cards in the QNAP's readers; plug audio recorders (or a camera on USB) into this Mac. Cards copy on the QNAP itself; every file is checked by MD5 before a card shows as safe to format.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
                Button("Templates…") { showTemplates = true }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if model.loading && model.cards.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Reading the card readers…") }.padding(8)
                    } else if model.cards.isEmpty {
                        Text("No cards in the QNAP's readers.").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(model.cards) { c in
                        CardRow(card: c, state: model.states[c.mount], previews: model.previews[c.id + "|\(c.bytes)"]) { Task { await check(c) } }
                            .task(id: c.id + "|\(c.bytes)") { await model.previews(for: c) }
                        Divider()
                    }
                }
            } label: { Label("Cards on the QNAP", systemImage: "sdcard") }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if model.audio.isEmpty {
                        Text("No recorders, cameras or cards with footage plugged into this Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(model.audio) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "waveform").foregroundStyle(.blue)
                                Text(a.name).font(.body.weight(.medium))
                                Text("\(a.files.count) files · \(fmtBytes(a.bytes))").foregroundStyle(.secondary)
                                Spacer()
                            }
                            PreviewStrip(previews: model.previews[a.id + "|\(a.bytes)"], height: 48)
                        }
                        .task(id: a.id + "|\(a.bytes)") { await model.previews(for: a) }
                    }
                }
                .padding(4)
            } label: { Label("Recorders and cameras on this Mac", systemImage: "mic") }

            if let s = model.audioStatus { HStack { ProgressView().controlSize(.small); Text(s) } }
            if let r = model.audioResult {
                Label(r, systemImage: r.contains("Safe to clear") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.contains("Safe to clear") ? .green : .red)
            }
            if let e = model.error ?? actionError { Text(e).foregroundStyle(.red).textSelection(.enabled) }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button { showIngest = true } label: { Text("Ingest Shoot…").padding(.horizontal, 8) }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.cards.allSatisfy { $0.media.isEmpty } && model.audio.isEmpty || model.audioStatus != nil)
            }
        }
        .padding(20)
        .navigationTitle("Ingest")
        .task { if model.cards.isEmpty { await model.refresh() } }
        .sheet(isPresented: $showIngest) {
            IngestSheet(model: model, templates: templates) { showIngest = false; showJobs() }
        }
        .sheet(isPresented: $showTemplates) { TemplatesSheet(store: templates) }
    }

    private func check(_ c: Card) async {
        actionError = nil
        guard let share = shares.list(.qnap).first(where: { $0.name == "Active Production" }) ?? shares.list(.qnap).first else { return }
        do {
            try await model.checkCard(c, in: Location(share: share))
            await jobs.refresh()
            showJobs()
        } catch { actionError = error.localizedDescription }
    }
}

struct CardRow: View {
    var card: Card
    var state: CardState?
    var previews: [Preview]?
    var check: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sdcard.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name).font(.body.weight(.medium))
                Text([card.summary, fmtBytes(card.bytes), card.dates.map { "\($0.0.formatted(date: .abbreviated, time: .shortened)) – \($0.1.formatted(date: .omitted, time: .shortened))" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                badge
                PreviewStrip(previews: previews, height: 64)
            }
            Spacer()
            switch state {
            case .safe, .empty: EmptyView()
            default:
                Button("Check Against Active Production") { check() }
                    .help("Checksums every file on the card and looks for an identical copy in Active Production. Green means safe to format.")
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .safe(let shoots, let when):
            Label("Safe to format: every file is verified in \(shoots.joined(separator: ", "))\(when.isEmpty ? "" : " (\(when))")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.callout.weight(.semibold))
        case .partial(let done, let total, let shoots):
            Label("NOT safe to format: \(total - done) of \(total) files aren't ingested yet (the rest are in \(shoots.joined(separator: ", ")))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout.weight(.semibold))
        case .missingOnNAS(let n):
            Label("NOT safe to format: \(n) ingested file(s) are no longer on the QNAP", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.callout.weight(.semibold))
        case .notIngested:
            Label("Not ingested. NOT safe to format.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.callout.weight(.semibold))
        case .empty:
            Text("No footage on this card").font(.callout).foregroundStyle(.secondary)
        case nil:
            Text("Status unknown").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: Ingest sheet

struct IngestSheet: View {
    @ObservedObject var model: IngestModel
    @ObservedObject var templates: TemplateStore
    var started: () -> Void
    @EnvironmentObject var shares: ShareStore
    @EnvironmentObject var jobs: JobStore
    @Environment(\.dismiss) private var dismiss

    @State private var templateID: UUID?
    @State private var date = Date()
    @State private var name = ""
    @State private var roles: [String: String] = [:]      // card id -> role ("" = skip)
    @State private var audioDest: [String: String] = [:]  // source id -> folder ("" = skip)
    @State private var reason = ""
    @State private var checks: [IngestCheck] = []
    @State private var cardPlans: [CardPlan] = []
    @State private var audioPlans: [AudioPlan] = []
    @State private var shootPath: String?
    @State private var planning = false
    @State private var starting = false
    @State private var error: String?
    @State private var confirm = false
    @State private var dateTouched = false

    private var template: ShootTemplate? { templates.templates.first { $0.id == templateID } }
    private var warnings: [IngestCheck] { checks.filter { $0.level == .warning } }
    private var cardsWithMedia: [Card] { model.cards.filter { !$0.media.isEmpty } }
    /// A Mac source can go to an audio folder or any camera folder (e.g. a 360 camera on USB).
    private var macFolders: [String] {
        guard let t = template else { return [] }
        var seen = Set<String>()
        return (t.audioFolders + t.cardRoles).filter { seen.insert($0).inserted }
    }

    private var folderName: String {
        let f = DateFormatter()
        f.dateFormat = "MM.dd"
        return f.string(from: date) + " " + name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ingest Shoot").font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Shoot type").foregroundStyle(.secondary)
                    Picker("", selection: $templateID) {
                        ForEach(templates.templates) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
                GridRow {
                    Text("Shoot date").foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(get: { date }, set: { date = $0; dateTouched = true }), displayedComponents: .date)
                        .labelsHidden().frame(maxWidth: 160)
                }
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Hannah + Rory @ Chart House (FAB)", text: $name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Text(shootPath.map { "QNAP › \(template?.shareName ?? "") › \(relative($0))" } ?? "–")
                        .font(.callout.weight(.medium)).textSelection(.enabled).lineLimit(2)
                }
            }

            Divider()
            Text("Where each card goes").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cardsWithMedia) { c in
                        HStack {
                            Image(systemName: "sdcard.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(c.name).font(.body.weight(.medium))
                                Text("\(c.summary) · \(fmtBytes(c.bytes))").font(.caption).foregroundStyle(.secondary)
                                PreviewStrip(previews: model.previews[c.id + "|\(c.bytes)"], height: 40)
                            }
                            Spacer()
                            Picker("", selection: binding($roles, c.id)) {
                                Text("Don't ingest").tag("")
                                ForEach(template?.cardRoles ?? [], id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 200)
                        }
                    }
                    ForEach(model.audio) { a in
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text("\(a.name) (this Mac)").font(.body.weight(.medium))
                                Text("\(a.files.count) files · \(fmtBytes(a.bytes))").font(.caption).foregroundStyle(.secondary)
                                PreviewStrip(previews: model.previews[a.id + "|\(a.bytes)"], height: 40)
                            }
                            Spacer()
                            Picker("", selection: binding($audioDest, a.id)) {
                                Text("Don't ingest").tag("")
                                ForEach(macFolders, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 200)
                        }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 340)

            Divider()
            HStack {
                Text("Checks").font(.headline)
                if planning { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 5) {
                if checks.isEmpty && !planning && shootPath != nil && error == nil && (!cardPlans.isEmpty || !audioPlans.isEmpty) {
                    Label("All checks passed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if shootPath == nil && !planning {
                    Text("Enter a name and assign at least one card.").foregroundStyle(.secondary)
                }
                ForEach(checks) { c in
                    Label(c.text, systemImage: c.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(c.level == .warning ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !warnings.isEmpty {
                TextField("To ingest anyway, say why (e.g. \"short ceremony, A Cam only shot 2 hours\")", text: $reason)
                    .textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ingest") { confirm = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear(perform: setUp)
        .onChange(of: model.cards) { _, _ in setUp() }
        .task(id: signature) { await plan() }
        .confirmationDialog("Start this ingest?", isPresented: $confirm) {
            Button("Ingest") { Task { await start() } }
        } message: {
            Text(summary + (warnings.isEmpty ? "" : "\n\nYour reason: \(reason)"))
        }
    }

    private var canStart: Bool {
        !planning && !starting && shootPath != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (!cardPlans.isEmpty || !audioPlans.isEmpty)
            && (warnings.isEmpty || reason.trimmingCharacters(in: .whitespaces).count >= 3)
    }

    private var summary: String {
        var lines = cardPlans.map { "\($0.card.name) → \(relative($0.dest))" }
        lines += audioPlans.map { "\($0.source.name) (Mac) → \(relative($0.dest))" }
        return lines.joined(separator: "\n")
    }

    private var signature: String {
        "\(shares.list(.qnap).count)|\(model.cards.count)|\(templateID?.uuidString ?? "")|\(folderName)|\(roles.sorted { $0.key < $1.key })|\(audioDest.sorted { $0.key < $1.key })"
    }

    private func relative(_ path: String) -> String {
        guard let t = template, let share = shares.list(.qnap).first(where: { $0.name == t.shareName }) else { return path }
        return path.hasPrefix(share.path + "/") ? String(path.dropFirst(share.path.count + 1)).replacingOccurrences(of: "/", with: " › ") : path
    }

    private func binding(_ dict: Binding<[String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { dict.wrappedValue[key] ?? "" }, set: { dict.wrappedValue[key] = $0 })
    }

    private func setUp() {
        if templateID == nil { templateID = templates.templates.first?.id }
        // Default the shoot date to the earliest footage on the cards (shoots are usually ingested the next day).
        if !dateTouched, let first = cardsWithMedia.compactMap({ $0.dates?.0 }).min() { date = first }
    }

    /// Works out where everything goes and what looks wrong. Nothing changes on the NAS here.
    private func plan() async {
        guard let t = template else { return }
        await shares.loadIfNeeded()
        guard let share = shares.list(.qnap).first(where: { $0.name == t.shareName }) else {
            error = "The template's share “\(t.shareName)” isn't on the QNAP."
            return
        }
        planning = true
        error = nil
        await model.loadHistory(t, shares: shares)
        let year = Calendar.current.component(.year, from: date)
        let shoot = share.path + "/" + t.parentPath(year: year) + "/" + folderName
        shootPath = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : shoot
        var out: [IngestCheck] = []
        var plans: [CardPlan] = []

        if (try? await NAS.exists(.qnap, shoot)) == true {
            out.append(IngestCheck(level: .info, text: "This shoot folder already exists; cards will be added to it."))
        }

        // Cards: where each goes, avoiding name clashes inside a camera folder.
        var totals: [String: Int64] = [:]
        let byRole = Dictionary(grouping: cardsWithMedia.filter { !(roles[$0.id] ?? "").isEmpty }) { roles[$0.id]! }
        for (role, cards) in byRole.sorted(by: { $0.key < $1.key }) {
            let folder = shoot + "/" + role
            var taken = (try? await NAS.folderFiles(folder)) ?? [:]
            totals[role, default: 0] += taken.values.reduce(0, +)
            let ordered = cards.sorted { ($0.dates?.0 ?? .distantPast) < ($1.dates?.0 ?? .distantPast) }
            for (i, c) in ordered.enumerated() {
                let clash = c.media.contains { f in taken[f.name].map { $0 != f.size } ?? false }
                    || Set(c.media.map(\.name)).count < c.media.count
                let dest = clash ? folder + "/Card \(i + 1)" : folder
                if clash {
                    out.append(IngestCheck(level: .info, text: "\(c.name): some file names are already used in \(role), so this card goes in \(role)/Card \(i + 1)."))
                } else {
                    let already = c.media.filter { taken[$0.name] == $0.size }.count
                    if already > 0 { out.append(IngestCheck(level: .info, text: "\(c.name): \(already) file(s) are already in \(role); they'll be checked, not copied twice.")) }
                    for f in c.media { taken[f.name] = f.size }
                }
                plans.append(CardPlan(card: c, role: role, dest: dest))
                totals[role, default: 0] += c.bytes
                let skipped = c.skipped.sorted { $0.value > $1.value }.map { "\($0.value.formatted()) \($0.key)" }
                if !skipped.isEmpty { out.append(IngestCheck(level: .info, text: "\(c.name): skipping \(skipped.joined(separator: ", ")).")) }
            }
        }

        // The checks that catch a missing card.
        for c in cardsWithMedia where (roles[c.id] ?? "").isEmpty {
            out.append(IngestCheck(level: .warning, text: "\(c.name) (\(fmtBytes(c.bytes))) isn't assigned, so it won't be ingested."))
        }
        for c in cardsWithMedia where !(roles[c.id] ?? "").isEmpty {
            switch model.states[c.mount] {
            case .safe(let shoots, let when):
                out.append(IngestCheck(level: .warning, text: "\(c.name) was already ingested into \(shoots.joined(separator: ", ")) (\(when)). Is this the right card?"))
            default: break
            }
        }
        for r in t.requiredRoles where (totals[r] ?? 0) == 0 {
            out.append(IngestCheck(level: .warning, text: "No card is assigned to \(r). Is a card missing?"))
        }
        let hist = model.history[t.id] ?? [:]
        for (role, total) in totals.sorted(by: { $0.key < $1.key }) {
            guard let past = hist[role], past.count >= 3 else { continue }
            let s = past.sorted()
            let median = s[s.count / 2], low = s[s.count / 10], high = s[min(s.count - 1, s.count * 9 / 10)]
            if Double(total) < Double(median) * 0.5 {
                out.append(IngestCheck(level: .warning, text: "\(role) is \(fmtBytes(total)), but your \(t.name) shoots usually have \(fmtBytes(low))–\(fmtBytes(high)) there (median \(fmtBytes(median)), \(s.count) shoots). Missing a card?"))
            }
        }
        if let main = t.requiredRoles.first, let mainTotal = totals[main], mainTotal > 0 {
            for (role, total) in totals where role != main && !role.contains("Audio") && total > mainTotal {
                out.append(IngestCheck(level: .warning, text: "\(main) (\(fmtBytes(mainTotal))) is smaller than \(role) (\(fmtBytes(total))). \(main) is normally the biggest. Missing a card?"))
            }
        }
        let bytes = plans.reduce(Int64(0)) { $0 + $1.card.bytes }
        if bytes > 0, let free = try? await NAS.freeBytes(Location(share: share)), free < bytes + bytes / 20 {
            out.append(IngestCheck(level: .warning, text: "Only \(fmtBytes(free)) free on \(t.shareName), and this ingest needs \(fmtBytes(bytes))."))
        }

        // Audio from this Mac.
        var aplans: [AudioPlan] = []
        for a in model.audio {
            let d = audioDest[a.id] ?? ""
            if d.isEmpty { out.append(IngestCheck(level: .warning, text: "\(a.name) on this Mac (\(a.files.count) files, \(fmtBytes(a.bytes))) isn't assigned, so it won't be ingested.")) }
            else { aplans.append(AudioPlan(source: a, dest: shoot + "/" + d)) }
        }

        if Task.isCancelled { return }
        checks = out.sorted { ($0.level == .warning ? 0 : 1) < ($1.level == .warning ? 0 : 1) }
        cardPlans = plans
        audioPlans = aplans
        planning = false
    }

    private func start() async {
        guard let t = template, let shoot = shootPath,
              let share = shares.list(.qnap).first(where: { $0.name == t.shareName }) else { return }
        starting = true
        error = nil
        do {
            var folders = t.folders.map { shoot + "/" + $0 }
            folders += cardPlans.map(\.dest) + audioPlans.map(\.dest)
            try await NAS.makeFolders(Array(Set(folders)).sorted())
            if !cardPlans.isEmpty {
                let id = NAS.newJobID("ingest")
                let shootLoc = Location(share: share, rel: String(shoot.dropFirst(share.path.count + 1)))
                var job = JobSpec(id: id, title: "Ingest: \(shootLoc.breadcrumb)" + (warnings.isEmpty ? "" : " (warned: \(reason))"), runner: .qnap)
                for (i, p) in cardPlans.enumerated() {
                    let list = "card\(i + 1).list"
                    job.lists[list] = p.card.media.map(\.path)
                    let cardLoc = Location(share: Share(host: .qnap, name: p.card.name, path: p.card.mount))
                    job.copies.append(CopyStep(from: cardLoc, to: p.dest, toHost: .qnap, list: list,
                                               backup: shootLoc.recycleDir(job: id), update: false, flat: true, card: p.card.name))
                }
                job.ingestShoot = shoot
                job.totalFiles = cardPlans.reduce(0) { $0 + $1.card.media.count }
                job.totalBytes = cardPlans.reduce(0) { $0 + $1.card.bytes }
                job.verify = true
                try await NAS.start(job)
                await jobs.refresh()
            }
            let audio = audioPlans
            Task { await model.copyAudio(audio) }
            starting = false
            started()
        } catch {
            self.error = error.localizedDescription
            starting = false
        }
    }
}

// MARK: Templates

struct TemplatesSheet: View {
    @ObservedObject var store: TemplateStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shoot Templates").font(.title2.weight(.semibold))
            HSplitView {
                List(selection: $selection) {
                    ForEach(store.templates) { Text($0.name).tag($0.id) }
                }
                .frame(minWidth: 180, maxWidth: 220)
                if let i = store.templates.firstIndex(where: { $0.id == selection }) {
                    TemplateEditor(template: $store.templates[i]).padding(.leading, 12).id(store.templates[i].id)
                } else {
                    Text("Choose a template").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 440)
            HStack {
                Button("Add") {
                    var t = ShootTemplate.defaults[0]
                    t.id = UUID()
                    t.name = "New Template"
                    store.templates.append(t)
                    selection = t.id
                }
                Button("Delete") { store.templates.removeAll { $0.id == selection }; selection = nil }
                    .disabled(selection == nil || store.templates.count <= 1)
                Button("Restore Defaults") { store.templates = ShootTemplate.defaults; selection = nil }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { selection = store.templates.first?.id }
    }
}

struct TemplateEditor: View {
    @Binding var template: ShootTemplate

    var body: some View {
        Form {
            TextField("Name", text: $template.name)
            TextField("QNAP share", text: $template.shareName)
            TextField("Parent folder ({YYYY} = year)", text: $template.parent)
            lines("Folders for every shoot", $template.folders)
            lines("Folders a card can go to", $template.cardRoles)
            lines("Must have a card (warns if empty)", $template.requiredRoles)
            lines("Folders for Mac audio", $template.audioFolders)
            LabeledContent("Past shoots (for size checks)") {
                LinesField(lines: Binding(
                    get: { template.history.map { "\($0.host.name) | \($0.shareName) | \($0.parentGlob)" } },
                    set: { lines in
                        template.history = lines.compactMap { line in
                            let p = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                            guard p.count == 3, let h = HostID.allCases.first(where: { $0.name.lowercased() == p[0].lowercased() }) else { return nil }
                            return HistorySource(host: h, shareName: p[1], parentGlob: p[2])
                        }
                    }), height: 44)
            }
        }
        .formStyle(.grouped)
    }

    private func lines(_ title: String, _ value: Binding<[String]>) -> some View {
        LabeledContent(title) { LinesField(lines: value, height: 60) }
    }
}

/// One item per line. Keeps its own text so a new empty line survives while typing; blank lines are dropped from the value.
struct LinesField: View {
    @Binding var lines: [String]
    var height: CGFloat
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .frame(height: height)
            .onAppear { text = lines.joined(separator: "\n") }
            .onChange(of: text) { _, t in
                lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
    }
}

/// A row of thumbnails sampled across a card's timeline, so cameras are easy to tell apart.
struct PreviewStrip: View {
    var previews: [Preview]?
    var height: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            if let previews {
                if previews.isEmpty { Text("No preview").font(.caption).foregroundStyle(.tertiary) }
                ForEach(previews) { p in
                    Image(nsImage: p.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: height * min(2, max(0.5, p.image.size.width / max(1, p.image.size.height))), height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help(p.name + (p.date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Loading previews…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: height, alignment: .leading)
    }
}
