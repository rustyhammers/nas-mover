import Foundation

enum HostID: String, CaseIterable, Identifiable, Codable {
    case qnap, unas
    var id: String { rawValue }
    var name: String { self == .qnap ? "QNAP" : "UNAS" }
    var other: HostID { self == .qnap ? .unas : .qnap }
}

/// Per-Mac connection settings, filled in by the Setup screen.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// ssh targets, e.g. "admin@qnap.local" and "root@unas.local".
    @Published var qnapTarget: String { didSet { save() } }
    @Published var unasTarget: String { didSet { save() } }
    /// How the QNAP reaches the UNAS (used by jobs running on the QNAP).
    @Published var unasFromQnap: String { didSet { save() } }
    @Published var unasOwner: String { didSet { save() } }
    @Published var streams: Int { didSet { save() } }

    private let d = UserDefaults.standard

    private init() {
        qnapTarget = d.string(forKey: "qnapTarget") ?? ""
        unasTarget = d.string(forKey: "unasTarget") ?? ""
        unasFromQnap = d.string(forKey: "unasFromQnap") ?? ""
        unasOwner = d.string(forKey: "unasOwner") ?? ""
        let s = d.integer(forKey: "streams")
        streams = s == 0 ? 4 : s
    }

    private func save() {
        d.set(qnapTarget, forKey: "qnapTarget")
        d.set(unasTarget, forKey: "unasTarget")
        d.set(unasFromQnap, forKey: "unasFromQnap")
        d.set(unasOwner, forKey: "unasOwner")
        d.set(streams, forKey: "streams")
    }

    func target(_ h: HostID) -> String { h == .qnap ? qnapTarget : unasTarget }

    var isConfigured: Bool { !qnapTarget.isEmpty && !unasTarget.isEmpty && !unasFromQnap.isEmpty }
}

struct Share: Hashable, Identifiable {
    var host: HostID
    var name: String
    /// Filesystem path of the share's root (what SMB shows).
    var path: String
    /// Where NAS Mover keeps originals and replaced files: a plain folder at the share's root.
    /// Not the NAS's own recycle bin, which empties itself by file age (QNAP purged a Move's
    /// originals hours after it finished because the footage was older than its 180-day limit).
    var recycleRoot: String { path + "/" + Share.recycleFolder }
    static let recycleFolder = "_NAS Mover Recycle"
    var id: String { host.rawValue + ":" + name }

    /// Name with spaces/case removed, used to match the same share across NASes.
    var matchKey: String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
}

struct Location: Hashable {
    var share: Share
    /// Path inside the share, "" for the share root.
    var rel: String = ""

    var host: HostID { share.host }
    var fullPath: String { rel.isEmpty ? share.path : share.path + "/" + rel }
    var displayName: String { rel.isEmpty ? share.name : (rel as NSString).lastPathComponent }
    var breadcrumb: String {
        ([host.name, share.name] + rel.split(separator: "/").map(String.init)).joined(separator: " › ")
    }
    func child(_ name: String) -> Location { Location(share: share, rel: rel.isEmpty ? name : rel + "/" + name) }
    var parent: Location? {
        guard !rel.isEmpty else { return nil }
        let p = (rel as NSString).deletingLastPathComponent
        return Location(share: share, rel: p)
    }
    /// Recycle-bin folder for a job, mirroring this location's path.
    func recycleDir(job: String) -> String {
        let base = share.recycleRoot + "/" + job
        return rel.isEmpty ? base : base + "/" + rel
    }
}

enum TransferMode: String, CaseIterable, Identifiable {
    case copy = "Copy", move = "Move"
    var id: String { rawValue }
}

/// A file or folder in the Browse tab.
struct Entry: Identifiable, Hashable {
    var name: String
    var isDir: Bool
    var size: Int64?          // files always; folders once measured
    var modified: Date
    var id: String { name }
}

/// One share's _NAS Mover Recycle folder and what's in it.
struct RecycleBin: Identifiable {
    var share: Share
    var total: Int64
    var items: [(name: String, size: Int64)]
    var id: String { share.id }
    var path: String { share.recycleRoot }
}

struct PreviewItem: Identifiable, Hashable {
    var path: String
    var size: Int64
    var id: String { path }
}

/// One NAS volume (from df): `id` tells two shares on the same disk apart from different disks.
struct Volume: Hashable {
    var host: HostID
    var id: String
    var size: Int64
    var free: Int64
    func usedPercent(free f: Int64) -> Int { size > 0 ? Int((Double(size - f) / Double(size) * 100).rounded()) : 0 }
}

struct TransferPreview {
    var newFiles: [PreviewItem] = []
    var updatedFiles: [PreviewItem] = []
    var skippedNewer: [PreviewItem] = []
    var totalItems: Int = 0
    var totalBytes: Int64 = 0
    var freeBytes: Int64? { dstVolume?.free }
    /// Disk space on the destination's and the source's volumes, read at preview time.
    var dstVolume: Volume?
    var srcVolume: Volume?

    var bytesToCopy: Int64 { (newFiles + updatedFiles).reduce(0) { $0 + $1.size } }
    var filesToCopy: Int { newFiles.count + updatedFiles.count }
}

struct JobInfo: Identifiable {
    var id: String
    var host: HostID
    var title: String
    var state: String      // running | done | failed | cancelled
    var phase: String
    var result: String
    var doneFiles: Int
    var doneBytes: Int64
    var totalFiles: Int
    var totalBytes: Int64
    var started: Date?
    var finished: Date?
    var hashedFiles: Int = 0
    var hashTotal: Int = 0
    var verifyPending: Bool = false
    /// Checksum progress per NAS: (host, bytes checked, bytes to check).
    var verifySides: [(host: HostID, done: Int64, total: Int64)] = []

    var isRunning: Bool { state == "running" }
    var isHashing: Bool { phase.hasPrefix("Verifying") || phase.hasPrefix("Hashing") }
    var fraction: Double {
        guard totalBytes > 0 else { return totalFiles > 0 ? Double(doneFiles) / Double(totalFiles) : 0 }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }
    var rate: Double? {
        guard let started, doneBytes > 0 else { return nil }
        let t = (finished ?? Date()).timeIntervalSince(started)
        return t > 0 ? Double(doneBytes) / t : nil
    }
}

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func fmtDuration(_ s: Double) -> String {
    if s < 60 { return "\(Int(s)) s" }
    let m = Int(s / 60)
    if m < 10 { return "\(m) min \(Int(s) % 60) s" }
    if m < 60 { return "\(m) min" }
    let h = m / 60
    return h < 48 ? "\(h) h \(m % 60) min" : "\(h / 24) days \(h % 24) h"
}

struct LiveStats {
    var hashing: Bool
    var byBytes: Bool = true
    var done: Double
    var total: Double
    var elapsed: Double
    var rate: Double?
    var remaining: Double?
    var fraction: Double { total > 0 ? min(1, done / total) : 0 }
}

/// Rough time estimate from the 2026-10-19 benchmarks: ~200 MB/s for big files, ~200 files/s for small ones.
func estimateSeconds(files: Int, bytes: Int64) -> Double {
    max(Double(bytes) / 200_000_000, Double(files) / 200)
}
