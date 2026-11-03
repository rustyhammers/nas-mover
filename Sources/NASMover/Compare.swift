import Foundation

/// What a checksum job found on each side: path -> MD5, plus the size and date the file had when it was read.
struct ChecksumResults {
    struct Entry { var md5: String; var file: FileEntry }
    var a: [String: Entry]
    var b: [String: Entry]

    /// The MD5 only if the file still has the size and date the latest scan saw; otherwise it's out of date.
    static func current(_ m: [String: Entry], _ path: String, _ index: [String: FileEntry]) -> String? {
        guard let e = m[path], let now = index[path], e.file.size == now.size, e.file.mtime == now.mtime else { return nil }
        return e.md5
    }
}

/// The comparison engine shared by Unify and Retire: classify two indexes, pair up moved files,
/// and fold in full checksums from a checksum job.
enum Comparison {
    struct Result {
        var items: [DiffItem]
        var identical: [String]
    }

    static func build(_ ma: [String: FileEntry], _ mb: [String: FileEntry], tolerance: Int64) -> Result {
        var items: [DiffItem] = []
        var identical: [String] = []
        var onlyA: [String] = []
        for (path, ea) in ma {
            guard let eb = mb[path] else { onlyA.append(path); continue }
            let dt = ea.mtime - eb.mtime
            let kind: DiffKind
            if ea.size == eb.size {
                if abs(dt) <= tolerance { identical.append(path); continue }
                kind = .likelySame
            } else if abs(dt) <= tolerance {
                kind = .conflict
            } else {
                kind = dt > 0 ? .newerA : .newerB
            }
            items.append(DiffItem(path: path, a: ea, b: eb, kind: kind, action: kind.defaultAction))
        }
        let onlyB = mb.keys.filter { ma[$0] == nil }

        // Moved or renamed: same name, size and date at a different path on the other side.
        var byKey: [String: [String]] = [:]
        for p in onlyB { byKey[key(p, mb[p]!), default: []].append(p) }
        var usedB = Set<String>()
        for p in onlyA.sorted() {
            let ea = ma[p]!
            let candidates = (byKey[key(p, ea)] ?? []).filter { !usedB.contains($0) && abs(mb[$0]!.mtime - ea.mtime) <= tolerance }
            if let best = candidates.max(by: { (sharedTail(p, $0), $1) < (sharedTail(p, $1), $0) }) {
                usedB.insert(best)
                items.append(DiffItem(path: p, a: ea, b: mb[best], kind: .moved, action: DiffKind.moved.defaultAction, bPath: best))
            } else {
                items.append(DiffItem(path: p, a: ea, b: nil, kind: .onlyA, action: DiffKind.onlyA.defaultAction))
            }
        }
        for p in onlyB where !usedB.contains(p) {
            items.append(DiffItem(path: p, a: nil, b: mb[p], kind: .onlyB, action: DiffKind.onlyB.defaultAction))
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Result(items: items, identical: identical)
    }

    private static func key(_ path: String, _ e: FileEntry) -> String {
        (path as NSString).lastPathComponent + "\u{0}" + String(e.size)
    }

    /// How many trailing path components two paths share (more = more likely the same file, moved with its folder).
    private static func sharedTail(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: "/").reversed(), y = b.split(separator: "/").reversed()
        var n = 0
        for (p, q) in zip(x, y) { if p == q { n += 1 } else { break } }
        return n
    }

    struct Checked {
        var verified = 0      // pairs whose contents match
        var unreadable = 0    // pairs where one side had no checksum (unreadable, or changed while reading)
        var damaged = 0       // same size and date, different contents
    }

    /// Re-sorts everything using full checksums (path -> MD5 for each side).
    static func apply(_ r: inout Result, ma: [String: FileEntry], mb: [String: FileEntry], sums: ChecksumResults) -> Checked {
        func ha(_ p: String) -> String? { ChecksumResults.current(sums.a, p, ma) }
        func hb(_ p: String) -> String? { ChecksumResults.current(sums.b, p, mb) }
        var c = Checked()
        var items: [DiffItem] = []
        var identical: [String] = []
        for p in r.identical {
            guard let x = ha(p), let y = hb(p) else { c.unreadable += 1; identical.append(p); continue }
            if x == y { c.verified += 1; identical.append(p) } else {
                c.damaged += 1
                items.append(DiffItem(path: p, a: ma[p], b: mb[p], kind: .damaged, action: DiffKind.damaged.defaultAction))
            }
        }
        for var i in r.items {
            switch i.kind {
            case .likelySame:
                if let x = ha(i.path), let y = hb(i.path) {
                    if x == y { c.verified += 1; identical.append(i.path); continue }
                    i.kind = (i.a?.mtime ?? 0) > (i.b?.mtime ?? 0) ? .newerA : .newerB
                    i.action = i.kind.defaultAction
                } else { c.unreadable += 1 }
                items.append(i)
            case .moved:
                let bp = i.bPath ?? i.path
                if let x = ha(i.path), let y = hb(bp) {
                    if x == y {
                        c.verified += 1
                        i.verified = true
                        items.append(i)
                    } else {
                        // Same name, size and date but different contents: not the same file after all.
                        items.append(DiffItem(path: i.path, a: i.a, b: nil, kind: .onlyA, action: DiffKind.onlyA.defaultAction))
                        items.append(DiffItem(path: bp, a: nil, b: i.b, kind: .onlyB, action: DiffKind.onlyB.defaultAction))
                    }
                } else { c.unreadable += 1; items.append(i) }
            default:
                items.append(i)
            }
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        r = Result(items: items, identical: identical)
        return c
    }
}

/// Runs a checksum job for two folders on the NAS and waits for it, surviving tab switches.
/// The last job for each pair of folders is remembered, so its results can be reused later.
@MainActor
final class ChecksumTracker: ObservableObject {
    @Published var job: (host: HostID, id: String)?
    @Published var progress: String?
    @Published var error: String?
    private var poll: Task<Void, Never>?

    var isRunning: Bool { job != nil && poll != nil }

    private static func key(_ a: Location, _ b: Location) -> String {
        "checksum|\(a.host.rawValue):\(a.fullPath)|\(b.host.rawValue):\(b.fullPath)"
    }

    /// A finished or running checksum job for this exact pair, if one was started from this Mac.
    static func previous(_ a: Location, _ b: Location) -> (host: HostID, id: String)? {
        guard let s = UserDefaults.standard.string(forKey: key(a, b)) else { return nil }
        let p = s.split(separator: "|", maxSplits: 1)
        guard p.count == 2, let h = HostID(rawValue: String(p[0])) else { return nil }
        return (h, String(p[1]))
    }

    func start(_ a: Location, _ b: Location, title: String, onDone: @escaping (ChecksumResults) -> Void) async {
        error = nil
        let id = NAS.newJobID("checksum")
        var spec = JobSpec(id: id, title: title, runner: NAS.runner(a.host, b.host))
        spec.verify = false
        spec.audit = (a, b)
        do {
            try await NAS.start(spec)
            UserDefaults.standard.set("\(spec.runner.rawValue)|\(id)", forKey: Self.key(a, b))
            follow((spec.runner, id), onDone: onDone)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Waits for a job (new or remembered), then hands over its checksums.
    func follow(_ j: (host: HostID, id: String), onDone: @escaping (ChecksumResults) -> Void) {
        poll?.cancel()
        job = j
        progress = "Starting…"
        error = nil
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let info = try await NAS.jobs(j.host).first { $0.id == j.id }
                    guard let self else { return }
                    guard let info else { self.error = "The checksum job is gone from the \(j.host.name)."; break }
                    if info.isRunning || info.state == "starting" {
                        let sides = info.verifySides.map { "\($0.host.name) \($0.total > 0 ? Int(Double($0.done) / Double($0.total) * 100) : 0)%" }
                        self.progress = sides.isEmpty ? info.phase : "Checksumming: " + sides.joined(separator: " · ")
                    } else if info.state == "done" || info.state == "failed" {
                        // A failed run still has checksums for everything it could read; the rest count as unchecked.
                        self.progress = "Loading checksums…"
                        let sums = try await NAS.auditHashes(j.host, job: j.id)
                        if info.state == "failed" { self.error = info.result }
                        self.progress = nil
                        self.poll = nil
                        onDone(sums)
                        return
                    } else {
                        self.error = "The checksum job was \(info.state)."
                        break
                    }
                } catch {
                    self?.progress = "Can't reach the NAS right now, retrying…"
                }
                try? await Task.sleep(for: .seconds(10))
            }
            self?.progress = nil
            self?.poll = nil
        }
    }

    func reset() {
        poll?.cancel()
        poll = nil
        job = nil
        progress = nil
        error = nil
    }
}
