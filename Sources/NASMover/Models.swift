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
    /// Where this share's recycle bin lives.
    var recycleRoot: String
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
        let base = share.recycleRoot + "/NAS Mover/" + job
        return rel.isEmpty ? base : base + "/" + rel
    }
}

enum TransferMode: String, CaseIterable, Identifiable {
    case copy = "Copy", move = "Move"
    var id: String { rawValue }
}

struct PreviewItem: Identifiable, Hashable {
    var path: String
    var size: Int64
    var id: String { path }
}

struct TransferPreview {
    var newFiles: [PreviewItem] = []
    var updatedFiles: [PreviewItem] = []
    var skippedNewer: [PreviewItem] = []
    var totalItems: Int = 0
    var totalBytes: Int64 = 0
    var freeBytes: Int64?

    var bytesToCopy: Int64 { (newFiles + updatedFiles).reduce(0) { $0 + $1.size } }
    var filesToCopy: Int { newFiles.count + updatedFiles.count }
}

struct JobInfo: Identifiable, Hashable {
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
    if s < 60 { return "under a minute" }
    let m = Int(s / 60)
    if m < 60 { return "\(m) min" }
    let h = m / 60
    return h < 48 ? "\(h) h \(m % 60) min" : "\(h / 24) days \(h % 24) h"
}

/// Rough time estimate from the 2026-10-19 benchmarks: ~200 MB/s for big files, ~200 files/s for small ones.
func estimateSeconds(files: Int, bytes: Int64) -> Double {
    max(Double(bytes) / 200_000_000, Double(files) / 200)
}
