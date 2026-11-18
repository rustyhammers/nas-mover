import SwiftUI

/// Folder sizes (du, size on disk) for every file browser, measured in the background as folders come
/// into view: a few at a time, newest view first, remembered for 10 minutes so going back is instant.
@MainActor
final class SizeCache: ObservableObject {
    static let shared = SizeCache()

    @Published private(set) var sizes: [String: Int64] = [:]
    private var measuredAt: [String: Date] = [:]
    private var queue: [(owner: String, parent: Location, name: String)] = []
    private var running = Set<String>()
    private let maxWorkers = 3
    private let fresh: TimeInterval = 600

    private static func key(_ parent: Location, _ name: String) -> String { parent.host.rawValue + ":" + parent.fullPath + "/" + name }

    func size(_ parent: Location, _ name: String) -> Int64? { sizes[Self.key(parent, name)] }

    /// True while a size for this folder is queued or being measured.
    func pending(_ parent: Location, _ name: String) -> Bool {
        let k = Self.key(parent, name)
        return running.contains(k) || queue.contains { Self.key($0.parent, $0.name) == k }
    }

    /// Measure these folders inside `parent` for one browser (`owner`). Whatever that browser was still
    /// waiting on from its previous folder is dropped, so only what's on screen gets measured, and the
    /// newest view goes first. `force` re-measures even recent sizes.
    func request(_ owner: String, _ parent: Location, _ names: [String], force: Bool = false) {
        let now = Date()
        let wanted = names.filter { n in
            let k = Self.key(parent, n)
            if running.contains(k) || queue.contains(where: { Self.key($0.parent, $0.name) == k && $0.owner != owner }) { return false }
            if !force, let t = measuredAt[k], now.timeIntervalSince(t) < fresh { return false }
            return true
        }
        queue = wanted.map { (owner, parent, $0) } + queue.filter { $0.owner != owner }
        pump()
    }

    /// Forget sizes under `loc` (after deleting or copying into it).
    func invalidate(_ loc: Location) {
        let prefix = loc.host.rawValue + ":" + loc.fullPath
        for k in measuredAt.keys where k == prefix || k.hasPrefix(prefix + "/") || prefix.hasPrefix(k + "/") {
            measuredAt[k] = nil
        }
    }

    private func pump() {
        while running.count < maxWorkers, !queue.isEmpty {
            let item = queue.removeFirst()
            let k = Self.key(item.parent, item.name)
            running.insert(k)
            objectWillChange.send()
            Task {
                let result = try? await NAS.sizes(item.parent, [item.name])
                running.remove(k)
                if let v = result?[item.name] {
                    sizes[k] = v
                    measuredAt[k] = Date()
                } else {
                    objectWillChange.send()
                }
                pump()
            }
        }
    }
}

/// A folder's size, or a quiet placeholder while it's being measured.
struct FolderSizeText: View {
    @ObservedObject var cache = SizeCache.shared
    let parent: Location
    let name: String

    var body: some View {
        if let s = cache.size(parent, name) {
            Text(fmtBytes(s)).monospacedDigit().foregroundStyle(.secondary)
        } else if cache.pending(parent, name) {
            Text("…").foregroundStyle(.tertiary).help("Measuring")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
