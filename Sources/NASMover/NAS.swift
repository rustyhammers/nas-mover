import Foundation

struct CopyStep {
    var from: Location
    var to: String            // destination folder (full path)
    var toHost: HostID
    var list: String?         // name of a list file in the job folder; nil = whole folder
    var backup: String        // recycle folder on the receiving side for overwritten files
    var update: Bool          // never overwrite newer destination files
}

struct RecycleStep {
    var host: HostID
    var root: String          // folder the list is relative to (or the folder to recycle)
    var dest: String
    var list: String?         // nil = recycle `root` itself
}

struct JobSpec {
    var id: String
    var title: String
    var runner: HostID
    var copies: [CopyStep] = []
    var recycles: [RecycleStep] = []
    var verify: Bool = true
    var totalFiles: Int = 0
    var totalBytes: Int64 = 0
    var lists: [String: [String]] = [:]
    /// Verify Folder job: folder (on `runner`) to check against its ASC MHL history.
    var verifyFolder: String?
}

struct FileEntry {
    var size: Int64
    var mtime: Int64
}

enum NAS {
    static var settings: AppSettings { .shared }
    private static var homes: [HostID: String] = [:]

    static func target(_ h: HostID) -> String { settings.target(h) }

    /// Forget cached NAS home folders (after the connection settings change).
    static func resetCache() { homes = [:] }

    /// Jobs run on the QNAP whenever it's involved (it holds the key to the UNAS).
    static func runner(_ a: HostID, _ b: HostID) -> HostID { (a == .qnap || b == .qnap) ? .qnap : .unas }

    static let rsh = "ssh -o BatchMode=yes -o ServerAliveInterval=30 -c aes128-gcm@openssh.com"

    /// rsync path for `path` on `host`, as seen from `runner` (unquoted).
    static func spec(_ host: HostID, _ path: String, runner: HostID) -> String {
        host == runner ? path : settings.unasFromQnap + ":" + path
    }

    // MARK: Setup

    /// Uploads the runner script and exclude list; returns the NAS-side home folder.
    @discardableResult
    static func ensureInstalled(_ h: HostID) async throws -> String {
        if let home = homes[h] { return home }
        guard let runner = Bundle.main.url(forResource: "runner", withExtension: "sh"),
              let excludes = Bundle.main.url(forResource: "excludes", withExtension: "txt") else {
            throw SSHError(message: "App resources are missing (runner.sh / excludes.txt).")
        }
        let t = target(h)
        // Write to a temp file and rename: a running job keeps reading its own copy of the old script.
        _ = try await SSH.check(t, "mkdir -p ~/.nasmover/jobs ~/.nasmover/tmp && cat > ~/.nasmover/runner.sh.new && mv ~/.nasmover/runner.sh.new ~/.nasmover/runner.sh", stdin: try Data(contentsOf: runner))
        _ = try await SSH.check(t, "cat > ~/.nasmover/excludes.txt.new && mv ~/.nasmover/excludes.txt.new ~/.nasmover/excludes.txt", stdin: try Data(contentsOf: excludes))
        let home = try await SSH.check(t, "echo $HOME").trimmingCharacters(in: .whitespacesAndNewlines)
        homes[h] = home
        return home
    }

    // MARK: Browsing

    static func shares(_ h: HostID) async throws -> [Share] {
        let conf = h == .qnap ? "/etc/config/smb.conf" : "/etc/samba/share.conf"
        let text = try await SSH.check(target(h), "cat \(conf)")
        var result: [Share] = []
        var section: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let name = section, line.lowercased().hasPrefix("path") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let path = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch h {
            case .qnap:
                if name == "global" || name.hasPrefix("Dev") && name.contains("Partition") || path.hasPrefix("/share/external") { continue }
                result.append(Share(host: h, name: name, path: path, recycleRoot: path + "/@Recycle"))
            case .unas:
                guard path.contains("/.unifi-drive/"), path.hasSuffix("/.data"), !path.contains("%") else { continue }
                let shareDir = (path as NSString).deletingLastPathComponent
                result.append(Share(host: h, name: name, path: path, recycleRoot: shareDir + "/.trashcan"))
            }
            section = nil
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func folders(_ loc: Location) async throws -> [String] {
        let out = try await SSH.check(target(loc.host), "cd \(shq(loc.fullPath)) && find . -mindepth 1 -maxdepth 1 -type d")
        return out.split(separator: "\n")
            .map { String($0.dropFirst(2)) }
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("@") && $0 != "#recycle" && $0 != "ascmhl" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func exists(_ h: HostID, _ path: String) async throws -> Bool {
        let r = try await SSH.run(target(h), "[ -e \(shq(path)) ]")
        return r.code == 0
    }

    static func freeBytes(_ loc: Location) async throws -> Int64? {
        let out = try await SSH.check(target(loc.host), "df -Pk \(shq(loc.share.path)) | tail -1")
        let cols = out.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 4, let kb = Int64(cols[3]) else { return nil }
        return kb * 1024
    }

    // MARK: Preview

    /// Dry-runs copying `src` into `dstParent`, returning what would happen.
    static func preview(src: Location, dstParent: Location) async throws -> TransferPreview {
        let runner = runner(src.host, dstParent.host)
        let home = try await ensureInstalled(runner)
        let dst = dstParent.fullPath + "/" + src.displayName
        let s = shq(spec(src.host, src.fullPath + "/", runner: runner))
        let d = shq(spec(dstParent.host, dst + "/", runner: runner))
        @Sendable func cmd(_ update: Bool) -> String {
            "rsync -rlt -s -n \(update ? "-u" : "") --stats --exclude-from=\(shq(home + "/.nasmover/excludes.txt")) --out-format='%i|%l|%n' -e \(shq(rsh)) \(s) \(d)"
        }
        let t = target(runner)
        async let planned = SSH.run(t, cmd(true))
        async let full = SSH.run(t, cmd(false))
        async let free = freeBytes(dstParent)
        let (p, f) = try await (planned, full)
        for r in [p, f] where !dryRunOK(r) {
            throw SSHError(message: "Preview failed: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var pv = TransferPreview()
        var plannedPaths = Set<String>()
        for line in p.text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                let flags = parts[0]
                guard flags.count > 1, flags.dropFirst().first == "f" else { continue }
                let item = PreviewItem(path: String(parts[2]), size: Int64(parts[1]) ?? 0)
                plannedPaths.insert(item.path)
                if flags.contains("+++++++") { pv.newFiles.append(item) } else { pv.updatedFiles.append(item) }
            } else if line.hasPrefix("Number of files:") {
                pv.totalItems = firstNumber(in: line)
            } else if line.hasPrefix("Total file size:") {
                pv.totalBytes = Int64(firstNumber(in: line))
            }
        }
        for line in f.text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count > 1, parts[0].dropFirst().first == "f" else { continue }
            let path = String(parts[2])
            if !plannedPaths.contains(path) {
                pv.skippedNewer.append(PreviewItem(path: path, size: Int64(parts[1]) ?? 0))
            }
        }
        pv.freeBytes = try? await free
        return pv
    }

    /// QNAP's rsync exits 1 with "main.c(2289)" after any dry run that finds work; the output is still complete.
    static func dryRunOK(_ r: CommandResult) -> Bool {
        r.code == 0 || r.code == 24 || (r.code == 1 && r.err.contains("main.c(2289)"))
    }

    private static func firstNumber(in line: Substring) -> Int {
        let afterColon = line.split(separator: ":", maxSplits: 1).last ?? ""
        let digits = afterColon.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "," }
        return Int(digits.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    // MARK: Jobs

    static func newJobID(_ kind: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date()) + "_" + kind
    }

    static func start(_ job: JobSpec) async throws {
        let home = try await ensureInstalled(job.runner)
        let t = target(job.runner)
        let dir = home + "/.nasmover/jobs/" + job.id
        _ = try await SSH.check(t, "mkdir -p \(shq(dir))")

        var env: [(String, String)] = [
            ("RUNNER", job.runner.rawValue),
            ("UNAS_SSH", settings.unasFromQnap),
            ("UNAS_OWNER", settings.unasOwner),
            ("STREAMS", String(max(1, settings.streams))),
            ("EXCLUDES", home + "/.nasmover/excludes.txt"),
            ("VERIFY", job.verify ? "1" : "0"),
        ]
        if let vf = job.verifyFolder { env.append(("VF_PATH", vf)) }
        for (i, c) in job.copies.enumerated() {
            let n = i + 1
            env += [
                ("COPY\(n)_FROM_HOST", c.from.host.rawValue),
                ("COPY\(n)_FROM", c.from.fullPath),
                ("COPY\(n)_TO_HOST", c.toHost.rawValue),
                ("COPY\(n)_TO", c.to),
                ("COPY\(n)_LIST", c.list.map { dir + "/" + $0 } ?? "ALL"),
                ("COPY\(n)_BACKUP", c.backup),
                ("COPY\(n)_UPDATE", c.update ? "1" : "0"),
            ]
        }
        for (i, r) in job.recycles.enumerated() {
            let n = i + 1
            env += [
                ("RECYCLE\(n)_HOST", r.host.rawValue),
                ("RECYCLE\(n)_ROOT", r.root),
                ("RECYCLE\(n)_DEST", r.dest),
                ("RECYCLE\(n)_LIST", r.list.map { dir + "/" + $0 } ?? "SELF"),
            ]
        }
        let envText = env.map { "\($0.0)=\(shq($0.1))" }.joined(separator: "\n") + "\n"

        func put(_ name: String, _ text: String) async throws {
            _ = try await SSH.check(t, "cat > \(shq(dir + "/" + name))", stdin: Data(text.utf8))
        }
        try await put("job.env", envText)
        try await put("title", job.title + "\n")
        try await put("total", "\(job.totalFiles) \(job.totalBytes)\n")
        for (name, paths) in job.lists {
            try await put(name, paths.joined(separator: "\n") + "\n")
        }
        _ = try await SSH.check(t, "cd \(shq(dir)) && echo starting > state && setsid sh \(shq(home + "/.nasmover/runner.sh")) \(shq(dir)) </dev/null >runner.out 2>&1 &")
    }

    static func jobs(_ h: HostID) async throws -> [JobInfo] {
        let script = #"""
        cd ~/.nasmover/jobs 2>/dev/null || exit 0
        for d in */; do
          d=${d%/}
          [ -f "$d/job.env" ] || continue
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$(cat "$d/title" 2>/dev/null)" "$(cat "$d/state" 2>/dev/null)" \
            "$(cat "$d/phase" 2>/dev/null)" "$(cat "$d/result" 2>/dev/null)" "$(cat "$d/progress" 2>/dev/null)" \
            "$(cat "$d/total" 2>/dev/null)" "$(cat "$d/started" 2>/dev/null)" "$(cat "$d/finished" 2>/dev/null)" \
            "$(cat "$d/hprogress" 2>/dev/null)" "$(grep -c "^VERIFY='1'" "$d/job.env" 2>/dev/null)"
        done
        """#
        let out = try await SSH.check(target(h), "sh -s", stdin: Data(script.utf8))
        return out.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 9 else { return nil }
            let prog = c[5].split(separator: " ")
            let tot = c[6].split(separator: " ")
            var state = c[2].isEmpty ? "starting" : c[2]
            if state == "starting" || state == "running" {
                // keep as-is; staleness is checked by `refreshStale`
            }
            if state.isEmpty { state = "unknown" }
            let hp = c.count > 9 ? c[9].split(separator: " ") : []
            return JobInfo(
                id: c[0], host: h, title: c[1], state: state, phase: c[3], result: c[4],
                doneFiles: Int(prog.first ?? "") ?? 0, doneBytes: Int64(prog.dropFirst().first ?? "") ?? 0,
                totalFiles: Int(tot.first ?? "") ?? 0, totalBytes: Int64(tot.dropFirst().first ?? "") ?? 0,
                started: Double(c[7]).map { Date(timeIntervalSince1970: $0) },
                finished: Double(c[8]).map { Date(timeIntervalSince1970: $0) },
                hashedFiles: Int(hp.first ?? "") ?? 0, hashTotal: Int(hp.dropFirst().first ?? "") ?? 0,
                verifyPending: c.count > 10 && c[10] == "1"
            )
        }
    }

    static func cancel(_ job: JobInfo) async throws {
        let dir = "~/.nasmover/jobs/" + shq(job.id)
        _ = try await SSH.run(target(job.host), "kill -TERM $(cat \(dir)/pid) 2>/dev/null")
    }

    static func log(_ job: JobInfo) async throws -> String {
        let dir = "~/.nasmover/jobs/" + shq(job.id)
        let script = """
        cd \(dir) || exit 0
        echo "== Events =="; cat events.log 2>/dev/null
        echo; echo "== Result =="; cat result 2>/dev/null
        if [ -s runner.out ]; then echo; echo "== Runner output =="; tail -50 runner.out; fi
        for f in err.*; do [ -s "$f" ] && { echo; echo "== Errors ($f) =="; tail -50 "$f"; }; done
        for f in mismatch.*; do [ -s "$f" ] && { echo; echo "== Files that failed verification ($f) =="; head -200 "$f"; }; done
        for f in vf.problems vf.modified vf.new; do [ -s "$f" ] && { echo; echo "== $f =="; head -300 "$f"; }; done
        [ -s manifests ] && { echo; echo "== ASC MHL manifests written =="; cat manifests; }
        echo; echo "== Last files copied =="; cat log.* 2>/dev/null | tail -40
        """
        return try await SSH.check(target(job.host), "sh -s", stdin: Data(script.utf8))
    }

    static func deleteRecord(_ job: JobInfo) async throws {
        _ = try await SSH.check(target(job.host), "rm -rf ~/.nasmover/jobs/" + shq(job.id))
    }

    /// Summary of a folder's ASC MHL history: number of generations and when the latest was written.
    static func mhlHistory(_ loc: Location) async throws -> (generations: Int, latest: String?) {
        let out = try await SSH.check(target(loc.host), "ls \(shq(loc.fullPath + "/ascmhl")) 2>/dev/null | grep -E '^[0-9]+_.*\\.mhl$' | sort || true")
        let names = out.split(separator: "\n").map(String.init)
        guard let last = names.last else { return (0, nil) }
        // 0003_Folder_2026-10-20_023445Z.mhl -> 2026-10-20 02:34:45 UTC
        let parts = last.dropLast(4).split(separator: "_").suffix(2).map(String.init)
        guard parts.count == 2, parts[1].count >= 6 else { return (names.count, nil) }
        let t = Array(parts[1])
        return (names.count, "\(parts[0]) \(String(t[0...1])):\(String(t[2...3])) UTC")
    }

    // MARK: Unify

    /// Lists every file under `loc` with size and modification time, keyed by relative path.
    static func index(_ loc: Location) async throws -> [String: FileEntry] {
        let prune = ["@Recycle", ".@__thumb", ".@upload_cache", ".@__qini", ".trashcan", ".TemporaryItems",
                     ".Trashes", ".Spotlight-V100", ".fseventsd", "ascmhl"]
            .map { "-name \(shq($0))" }.joined(separator: " -o ")
        let cmd = "cd \(shq(loc.fullPath)) && find . \\( \(prune) \\) -prune -o -type f ! -name .DS_Store ! -name '._*' ! -name Thumbs.db -exec stat -c '%s %Y %n' {} +"
        let r = try await SSH.run(target(loc.host), cmd)
        if r.code != 0 && r.out.isEmpty {
            throw SSHError(message: "Could not index \(loc.breadcrumb): \(r.err)")
        }
        var result: [String: FileEntry] = [:]
        for line in r.text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = Int64(parts[0]), let mt = Int64(parts[1]) else { continue }
            var path = String(parts[2])
            if path.hasPrefix("./") { path.removeFirst(2) }
            result[path] = FileEntry(size: size, mtime: mt)
        }
        return result
    }

    /// Checksums `paths` on both sides; returns the ones whose contents differ.
    static func contentDiffers(a: Location, b: Location, paths: [String]) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let runner = runner(a.host, b.host)
        let home = try await ensureInstalled(runner)
        let t = target(runner)
        let listPath = home + "/.nasmover/tmp/" + UUID().uuidString + ".list"
        _ = try await SSH.check(t, "cat > \(shq(listPath))", stdin: Data((paths.joined(separator: "\n") + "\n").utf8))
        let s = shq(spec(a.host, a.fullPath + "/", runner: runner))
        let d = shq(spec(b.host, b.fullPath + "/", runner: runner))
        let r = try await SSH.run(t, "rsync -rlt -s -n -c --files-from=\(shq(listPath)) --out-format='%i|%n' -e \(shq(rsh)) \(s) \(d); rc=$?; rm -f \(shq(listPath)); exit $rc")
        if !dryRunOK(r) {
            throw SSHError(message: "Checksum comparison failed: \(r.err)")
        }
        var differs = Set<String>()
        for line in r.text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, parts[0].count > 1, parts[0].dropFirst().first == "f" else { continue }
            differs.insert(String(parts[1]))
        }
        return differs
    }
}
