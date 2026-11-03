import Foundation
import SwiftUI

// MARK: Templates

/// Where to look for past shoots of a template, to learn how big each camera folder usually is.
struct HistorySource: Codable, Hashable {
    var host: HostID
    var shareName: String
    /// Folder pattern inside the share whose subfolders are shoots, e.g. "Wedding Videography - *".
    var parentGlob: String
}

/// A shoot type: where its shoots live and which folders a new shoot gets.
struct ShootTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var shareName: String               // QNAP share
    var parent: String                  // folder inside the share; {YYYY} = shoot year
    var folders: [String]               // created for every shoot ("_Audio/PR-2" for nested)
    var cardRoles: [String]             // folders a card can be assigned to
    var requiredRoles: [String]         // warn when no card is assigned
    var audioFolders: [String]          // folders a Mac audio source can be assigned to
    var history: [HistorySource]

    func parentPath(year: Int) -> String { parent.replacingOccurrences(of: "{YYYY}", with: String(year)) }

    static let defaults: [ShootTemplate] = [
        ShootTemplate(name: "Wedding Videography", shareName: "Active Production", parent: "Wedding Videography - {YYYY}",
                      folders: ["A Cam", "B Cam", "C Cam", "Drone", "360", "_Audio", "_Audio/PR-2", "_Audio/PR-4", "_Assets"],
                      cardRoles: ["A Cam", "B Cam", "C Cam", "Drone", "360", "_Audio/PR-2", "_Audio/PR-4"],
                      requiredRoles: ["A Cam"],
                      audioFolders: ["_Audio", "_Audio/PR-2", "_Audio/PR-4"],
                      history: [HistorySource(host: .qnap, shareName: "Active Production", parentGlob: "Wedding Videography - *"),
                                HistorySource(host: .unas, shareName: "DiamondLakeArchive", parentGlob: "Wedding Videography/*")]),
        ShootTemplate(name: "Wedding Photography", shareName: "Active Production", parent: "Wedding Photography - {YYYY}",
                      folders: ["A Cam", "B Cam"],
                      cardRoles: ["A Cam", "B Cam", "A Cam (Reception)"],
                      requiredRoles: ["A Cam"],
                      audioFolders: [],
                      history: [HistorySource(host: .qnap, shareName: "Active Production", parentGlob: "Wedding Photography - *")]),
        ShootTemplate(name: "Private Event", shareName: "Active Production", parent: "Private Events",
                      folders: ["Video", "Photo", "_Audio"],
                      cardRoles: ["Video", "Photo", "_Audio"],
                      requiredRoles: [],
                      audioFolders: ["_Audio"],
                      history: [HistorySource(host: .qnap, shareName: "Active Production", parentGlob: "Private Events")]),
        ShootTemplate(name: "Legacy Film", shareName: "Active Production", parent: "Legacy Films - {YYYY}",
                      folders: ["RAW/A Cam", "RAW/B Cam", "RAW/C Cam", "RAW/Photos", "RAW/_Audio"],
                      cardRoles: ["RAW/A Cam", "RAW/B Cam", "RAW/C Cam", "RAW/Photos", "RAW/_Audio"],
                      requiredRoles: ["RAW/A Cam"],
                      audioFolders: ["RAW/_Audio"],
                      history: [HistorySource(host: .qnap, shareName: "Active Production", parentGlob: "Legacy Films - *")]),
    ]
}

final class TemplateStore: ObservableObject {
    @Published var templates: [ShootTemplate] { didSet { save() } }
    private let key = "ingestTemplates"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let t = try? JSONDecoder().decode([ShootTemplate].self, from: d), !t.isEmpty {
            templates = t
        } else {
            templates = ShootTemplate.defaults
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: Cards and audio sources

struct CardFile: Hashable {
    var path: String      // relative to the card
    var size: Int64
    var mtime: Int64
    var name: String { (path as NSString).lastPathComponent }
}

/// Which card files are footage worth keeping. Camera bookkeeping (thumbnails, databases, in-camera proxies) is skipped.
enum MediaFilter {
    static let extensions: Set<String> = [
        "mp4", "mov", "mxf", "mts", "m2ts", "avi", "insv", "insp", "braw", "r3d", "crm", "360",
        "arw", "cr3", "cr2", "nef", "raf", "dng", "rw2", "orf", "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff",
        "wav", "mp3", "m4a", "aac", "flac", "aif", "aiff",
        "xml", "srt",
    ]
    static let skipFolders: Set<String> = ["THMBNL", "SUB", "GENERAL", "DATABASE", "AVF_INFO", "SONY", "CANONMSC", "MISC",
                                           ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"]
    static let skipFiles: Set<String> = ["MEDIAPRO.XML", "STATUS.BIN", "CUEUP.XML", "TAKELIST.XML"]

    /// nil = keep; otherwise why it's skipped.
    static func skipReason(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return "empty" }
        if name.hasPrefix(".") { return "hidden files" }
        if let f = parts.dropLast().first(where: { skipFolders.contains($0.uppercased()) || skipFolders.contains($0) }) {
            return f.uppercased() == "THMBNL" ? "thumbnails" : f.uppercased() == "SUB" ? "in-camera proxies" : "camera system files"
        }
        if skipFiles.contains(name.uppercased()) { return "camera system files" }
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions.contains(ext) ? nil : ".\(ext.isEmpty ? "(none)" : ext) files"
    }
}

struct Card: Identifiable, Hashable {
    var mount: String                 // /share/external/DEV3702_1 on the QNAP
    var device: String                // reader/card model
    var media: [CardFile]
    var skipped: [String: Int]
    var id: String { mount }
    var slot: String { (mount as NSString).lastPathComponent }
    var name: String { device.isEmpty ? slot : "\(device) (\(slot))" }
    var bytes: Int64 { media.reduce(0) { $0 + $1.size } }

    /// e.g. "5 MP4 · 1,580 ARW"
    var summary: String {
        var c: [String: Int] = [:]
        for f in media { c[(f.name as NSString).pathExtension.uppercased(), default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.prefix(4).map { "\($0.value.formatted()) \($0.key)" }.joined(separator: " · ")
    }
    var dates: (Date, Date)? {
        let t = media.map(\.mtime).filter { $0 > 0 }
        guard let a = t.min(), let b = t.max() else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(a)), Date(timeIntervalSince1970: TimeInterval(b)))
    }
}

enum CardState: Hashable {
    case empty
    case notIngested
    case partial(done: Int, total: Int, shoots: [String])
    case safe(shoots: [String], when: String)
    case missingOnNAS(Int)
}

struct AudioFile: Hashable {
    var url: URL
    var size: Int64
    var name: String { url.lastPathComponent }
}

struct AudioSource: Identifiable, Hashable {
    var volume: URL
    var files: [AudioFile]
    var id: String { volume.path }
    var name: String { volume.lastPathComponent }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

extension NAS {
    static let ledgerPath = ".nasmover/ingest/ledger.tsv"

    /// Cards mounted in the QNAP's readers, with every file on them.
    static func cards() async throws -> [Card] {
        let script = #"""
        mount | awk '$3 ~ /^\/share\/external\// { print $1 " " $3 }' | while read -r dev mnt; do
          b=$(basename "$dev" | sed 's/[0-9]*$//')
          echo "@@ $mnt|$(cat /sys/block/$b/device/vendor 2>/dev/null | tr -s ' ') $(cat /sys/block/$b/device/model 2>/dev/null | tr -s ' ')"
          (cd "$mnt" && find . -type f -print | sed 's|^\./||' | tr '\n' '\0' | xargs -0 -r stat -c '%s %Y %n')
        done
        """#
        let out = try await SSH.check(target(.qnap), "sh -s", stdin: Data(script.utf8))
        var cards: [Card] = []
        for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("@@ ") {
                let p = line.dropFirst(3).split(separator: "|", maxSplits: 1).map(String.init)
                cards.append(Card(mount: p[0], device: (p.count > 1 ? p[1] : "").trimmingCharacters(in: .whitespaces), media: [], skipped: [:]))
                continue
            }
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard !cards.isEmpty, f.count == 3, let size = Int64(f[0]), let mt = Int64(f[1]) else { continue }
            let path = String(f[2])
            if let why = MediaFilter.skipReason(path) {
                cards[cards.count - 1].skipped[why, default: 0] += 1
            } else {
                cards[cards.count - 1].media.append(CardFile(path: path, size: size, mtime: mt))
            }
        }
        return cards
    }

    /// Looks each card file up in the ingest ledger (same name, size and date) and checks its copy still exists.
    static func cardStates(_ cards: [Card]) async throws -> [String: CardState] {
        var input = ""
        for c in cards { for f in c.media { input += "\(c.mount)\t\(f.size)\t\(f.mtime)\t\(f.name)\n" } }
        let script = #"""
        L=~/LEDGER_PATH
        [ -f "$L" ] || exit 0
        T=$(printf '\t')
        awk -F'\t' 'FILENAME == ARGV[1] { k = $3 "/" $1 "/" $2; d[k] = $5; s[k] = $6; w[k] = $8; next }
                    { k = $4 "/" $2 "/" $3; if (k in d) print $1 "\t" $4 "\t" d[k] "\t" s[k] "\t" w[k] }' "$L" - |
        while IFS="$T" read -r mnt name dest shoot when; do
          if [ -f "$dest" ]; then st=ok; else st=gone; fi
          printf '%s\t%s\t%s\t%s\t%s\n' "$mnt" "$name" "$st" "$shoot" "$when"
        done
        """#
        let out = try await SSH.check(target(.qnap), "sh -c \(shq(script.replacingOccurrences(of: "LEDGER_PATH", with: ledgerPath)))", stdin: Data(input.utf8))
        var ok: [String: Set<String>] = [:], gone: [String: Int] = [:], shoots: [String: Set<String>] = [:], when: [String: String] = [:]
        for raw in out.split(separator: "\n") {
            let c = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count == 5 else { continue }
            if c[2] == "ok" { ok[c[0], default: []].insert(c[1]) } else { gone[c[0], default: 0] += 1 }
            shoots[c[0], default: []].insert((c[3] as NSString).lastPathComponent)
            when[c[0]] = max(when[c[0]] ?? "", c[4])
        }
        var states: [String: CardState] = [:]
        for c in cards {
            let total = Set(c.media.map(\.name)).count
            let done = ok[c.mount]?.count ?? 0
            let names = Array(shoots[c.mount] ?? []).sorted()
            if total == 0 { states[c.mount] = .empty }
            else if let g = gone[c.mount], g > 0 { states[c.mount] = .missingOnNAS(g) }
            else if done >= total { states[c.mount] = .safe(shoots: names, when: when[c.mount] ?? "") }
            else if done > 0 { states[c.mount] = .partial(done: done, total: total, shoots: names) }
            else { states[c.mount] = .notIngested }
        }
        return states
    }

    /// Sizes of each role folder in past shoots of a template: role -> [bytes].
    @MainActor static func roleHistory(_ t: ShootTemplate, shares: ShareStore) async -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for src in t.history {
            guard let share = shares.list(src.host).first(where: { $0.name == src.shareName }) else { continue }
            let glob = src.parentGlob.map { $0 == "*" ? "*" : "\\" + String($0) }.joined()
            var script = "cd \(shq(share.path)) || exit 0\nfor d in \(glob)/*/; do\n"
            for r in t.cardRoles {
                script += "  [ -d \"$d\"\(shq(r)) ] && printf '%s|%s\\n' \(shq(r)) \"$(du -sk \"$d\"\(shq(r)) | cut -f1)\"\n"
            }
            script += "done\nexit 0\n"
            guard let out = try? await SSH.check(target(src.host), "sh -s", stdin: Data(script.utf8)) else { continue }
            for raw in out.split(separator: "\n") {
                let p = raw.split(separator: "|")
                guard p.count == 2, let kb = Int64(p[1]), kb > 1024 else { continue }
                result[String(p[0]), default: []].append(kb * 1024)
            }
        }
        return result
    }

    /// Files already in a folder on the QNAP: name -> size.
    static func folderFiles(_ path: String) async throws -> [String: Int64] {
        let out = try await SSH.check(target(.qnap), "cd \(shq(path)) 2>/dev/null || exit 0; for f in * .[!.]*; do [ -f \"$f\" ] && stat -c '%s %n' \"$f\"; done; exit 0")
        var r: [String: Int64] = [:]
        for raw in out.split(separator: "\n") {
            let p = raw.split(separator: " ", maxSplits: 1)
            if p.count == 2, let s = Int64(p[0]) { r[String(p[1])] = s }
        }
        return r
    }

    /// Creates the shoot's folders (rw for everyone, like folders made over SMB).
    static func makeFolders(_ paths: [String]) async throws {
        let script = "umask 000\n" + paths.map { "mkdir -p \(shq($0)) || exit 1" }.joined(separator: "\n") + "\n"
        _ = try await SSH.check(target(.qnap), "sh -s", stdin: Data(script.utf8))
    }
}

/// Recorders, mic receivers, cameras and cards plugged into this Mac (drives up to 1 TB, so working SSDs aren't offered).
enum AudioScanner {
    static let maxVolume: Int64 = 1_100_000_000_000

    static func sources() -> [AudioSource] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                                      .volumeIsRootFileSystemKey, .volumeTotalCapacityKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [AudioSource] = []
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsLocal == true, r.volumeIsRootFileSystem != true,
                  r.volumeIsInternal != true || r.volumeIsRemovable == true || r.volumeIsEjectable == true,
                  Int64(r.volumeTotalCapacity ?? 0) <= maxVolume else { continue }
            var files: [AudioFile] = []
            let e = FileManager.default.enumerator(at: v, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var seen = 0
            while let u = e?.nextObject() as? URL {
                seen += 1
                if seen > 50_000 { break }
                let rel = String(u.path.dropFirst(v.path.count + 1))
                guard MediaFilter.skipReason(rel) == nil,
                      let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), rv.isRegularFile == true else { continue }
                files.append(AudioFile(url: u, size: Int64(rv.fileSize ?? 0)))
            }
            if !files.isEmpty { out.append(AudioSource(volume: v, files: files.sorted { $0.name < $1.name })) }
        }
        return out
    }

    static func md5(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/md5")
        p.arguments = ["-q", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Ingest model

struct IngestCheck: Identifiable, Hashable {
    enum Level { case info, warning }
    var level: Level
    var text: String
    var id: String { text }
}

/// Where each card's files go once collisions are resolved.
struct CardPlan: Hashable {
    var card: Card
    var role: String
    var dest: String
}

struct AudioPlan: Hashable {
    var source: AudioSource
    var dest: String
}

@MainActor
final class IngestModel: ObservableObject {
    @Published var cards: [Card] = []
    @Published var states: [String: CardState] = [:]
    @Published var audio: [AudioSource] = []
    @Published var loading = false
    @Published var error: String?
    @Published var audioStatus: String?
    @Published var audioResult: String?
    @Published var history: [UUID: [String: [Int64]]] = [:]

    func refresh() async {
        loading = true
        error = nil
        audio = await Task.detached { AudioScanner.sources() }.value
        do {
            cards = try await NAS.cards()
            states = (try? await NAS.cardStates(cards)) ?? [:]
        } catch {
            self.error = "Couldn't read the QNAP's card readers: \(error.localizedDescription)"
        }
        loading = false
    }

    func loadHistory(_ t: ShootTemplate, shares: ShareStore) async {
        if history[t.id] != nil { return }
        history[t.id] = await NAS.roleHistory(t, shares: shares)
    }

    /// Safe to format? Checksums the card against a folder (normally the production share) as a job on the QNAP.
    func checkCard(_ c: Card, in search: Location) async throws {
        var job = JobSpec(id: NAS.newJobID("cardcheck"), title: "Check card: \(c.name) against \(search.breadcrumb)", runner: .qnap)
        job.verify = false
        job.lists["card.list"] = c.media.map(\.path)
        job.cardCheck = (c, "card.list", search)
        job.totalFiles = c.media.count
        job.totalBytes = c.bytes
        try await NAS.start(job)
    }

    /// Copies the Mac's audio sources up to the QNAP and MD5-checks every file. Runs alongside the card job.
    func copyAudio(_ plans: [AudioPlan]) async {
        guard !plans.isEmpty else { return }
        let t = NAS.target(.qnap)
        let total = plans.reduce(Int64(0)) { $0 + $1.source.bytes }
        let count = plans.reduce(0) { $0 + $1.source.files.count }
        var doneBytes: Int64 = 0, n = 0, copied = 0, already = 0
        var failures: [String] = []
        audioResult = nil
        for p in plans {
            var existing = (try? await NAS.folderFiles(p.dest)) ?? [:]
            var dest = p.dest
            // A different file with the same name already there: this source goes in its own subfolder instead.
            if p.source.files.contains(where: { f in existing[f.name].map { $0 != f.size } ?? false }) {
                dest = p.dest + "/" + p.source.name
                existing = (try? await NAS.folderFiles(dest)) ?? [:]
            }
            for f in p.source.files {
                n += 1
                audioStatus = "From this Mac: \(n) of \(count) files · \(fmtBytes(doneBytes)) of \(fmtBytes(total))"
                let final = dest + "/" + f.name
                let tmp = dest + "/." + f.name + ".nasmover-part"
                do {
                    let local = try await Task.detached { try AudioScanner.md5(f.url) }.value
                    if existing[f.name] == f.size {
                        let remote = try await SSH.check(t, "md5sum \(shq(final)) | cut -c1-32").trimmingCharacters(in: .whitespacesAndNewlines)
                        if remote == local { already += 1; doneBytes += f.size; continue }
                        throw SSHError(message: "a different \(f.name) is already there")
                    }
                    let r = try await SSH.run(t, "umask 000; mkdir -p \(shq(dest)) && cat > \(shq(tmp))", stdinFile: f.url)
                    guard r.code == 0 else { throw SSHError(message: r.err.isEmpty ? "copy failed" : r.err) }
                    let remote = try await SSH.check(t, "md5sum \(shq(tmp)) | cut -c1-32").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard remote == local else { throw SSHError(message: "checksum mismatch after copying") }
                    _ = try await SSH.check(t, "mv \(shq(tmp)) \(shq(final))")
                    copied += 1
                } catch {
                    failures.append("\(p.source.name)/\(f.name): \(error.localizedDescription)")
                }
                doneBytes += f.size
            }
        }
        audioStatus = nil
        audioResult = failures.isEmpty
            ? "From this Mac: \(copied) copied and verified\(already > 0 ? ", \(already) already there" : ""). Safe to clear those devices."
            : "From this Mac: \(failures.count) file(s) failed. Don't clear those devices. " + failures.prefix(3).joined(separator: "; ")
    }
}
