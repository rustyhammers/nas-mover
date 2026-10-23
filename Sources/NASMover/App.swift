import SwiftUI
import AppKit
import Combine
import Sparkle

/// Sparkle auto-updates. The feed URL and signing key live in Info.plist (see build.sh).
final class Updater: ObservableObject {
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published var canCheck = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func check() { controller.checkForUpdates(nil) }
}

@main
struct NASMoverApp: App {
    @StateObject private var jobs = JobStore()
    @StateObject private var shares = ShareStore()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var updater = Updater()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("NAS Mover") {
            ContentView()
                .environmentObject(jobs)
                .environmentObject(shares)
                .environmentObject(settings)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
            }
        }
        Settings {
            SettingsView().environmentObject(settings).environmentObject(shares)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case transfer = "Copy / Move"
    case unify = "Unify"
    case verify = "Verify"
    case jobs = "Jobs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .transfer: return "arrow.right.doc.on.clipboard"
        case .unify: return "arrow.triangle.merge"
        case .verify: return "checkmark.seal"
        case .jobs: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var jobs: JobStore
    @EnvironmentObject var shares: ShareStore
    @State private var section: SidebarItem? = .transfer
    @State private var showSetup = !AppSettings.shared.isConfigured

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .jobs ? jobs.runningCount : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { ConnectionStatus().padding(10) }
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if section != .jobs { ActiveJobsBar(showJobs: { section = .jobs }) }
                }
        }
        .sheet(isPresented: $showSetup) { SetupView { showSetup = false } }
        .onReceive(NotificationCenter.default.publisher(for: .showSetup)) { _ in showSetup = true }
        .task { await shares.loadIfNeeded() }
        .task { await jobs.pollForever() }
    }

    @ViewBuilder
    private var detail: some View {
            switch section ?? .transfer {
            case .transfer: TransferView(showJobs: { section = .jobs })
            case .unify: UnifyView(showJobs: { section = .jobs })
            case .verify: VerifyView(showJobs: { section = .jobs })
            case .jobs: JobsView()
            }
    }
}

struct ConnectionStatus: View {
    @EnvironmentObject var shares: ShareStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(HostID.allCases) { h in
                HStack(spacing: 6) {
                    Circle().fill(color(h)).frame(width: 8, height: 8)
                    Text(h.name).font(.caption)
                    Spacer()
                }
                .help(shares.errors[h] ?? "Connected")
            }
            if !shares.errors.isEmpty {
                Button("Retry") { Task { await shares.reload() } }.font(.caption)
            }
        }
    }
    func color(_ h: HostID) -> Color {
        if shares.errors[h] != nil { return .red }
        return shares.shares[h] == nil ? .gray : .green
    }
}

extension Notification.Name {
    static let showSetup = Notification.Name("NASMoverShowSetup")
}

@MainActor
final class ShareStore: ObservableObject {
    @Published var shares: [HostID: [Share]] = [:]
    @Published var errors: [HostID: String] = [:]
    private var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await reload()
    }

    func reload() async {
        errors = [:]
        guard AppSettings.shared.isConfigured else { return }
        await withTaskGroup(of: (HostID, Result<[Share], Error>).self) { g in
            for h in HostID.allCases {
                g.addTask {
                    do { return (h, .success(try await NAS.shares(h))) } catch { return (h, .failure(error)) }
                }
            }
            for await (h, r) in g {
                switch r {
                case .success(let s): shares[h] = s
                case .failure(let e): errors[h] = e.localizedDescription
                }
            }
        }
    }

    func list(_ h: HostID) -> [Share] { shares[h] ?? [] }
}

@MainActor
final class JobStore: ObservableObject {
    @Published var jobs: [JobInfo] = []
    @Published var error: String?
    /// Recent (time, amount) samples per running job and phase, for a speed that reflects the last ~30 s.
    private var samples: [String: [(Date, Double)]] = [:]
    var runningCount: Int { jobs.filter { $0.isRunning || $0.state == "starting" }.count }

    func refresh() async {
        guard AppSettings.shared.isConfigured else { jobs = []; return }
        var all: [JobInfo] = []
        var errs: [String] = []
        await withTaskGroup(of: Result<[JobInfo], Error>.self) { g in
            for h in HostID.allCases {
                g.addTask {
                    do { return .success(try await NAS.jobs(h)) } catch { return .failure(error) }
                }
            }
            for await r in g {
                switch r {
                case .success(let j): all += j
                case .failure(let e): errs.append(e.localizedDescription)
                }
            }
        }
        jobs = all.sorted { $0.id > $1.id }
        let now = Date()
        for j in jobs where j.isRunning {
            let key = j.id + (j.isHashing ? "#hash" : "#copy")
            var s = samples[key] ?? []
            let slow = j.verifySides.filter { $0.total > 0 }.min { Double($0.done) / Double($0.total) < Double($1.done) / Double($1.total) }
            s.append((now, j.isHashing ? (slow.map { Double($0.done) } ?? Double(j.hashedFiles)) : Double(j.doneBytes)))
            s.removeAll { now.timeIntervalSince($0.0) > 30 }
            samples[key] = s
        }
        error = errs.isEmpty ? nil : errs.joined(separator: "\n")
    }

    /// Live numbers for a running job (bytes while copying, files while checksumming).
    func stats(_ j: JobInfo) -> LiveStats {
        let hashing = j.isHashing && (j.hashTotal > 0 || !j.verifySides.isEmpty)
        // Verification finishes when the slower NAS does, so track that side's bytes.
        let slow = j.verifySides.filter { $0.total > 0 }.min { Double($0.done) / Double($0.total) < Double($1.done) / Double($1.total) }
        let done = hashing ? (slow.map { Double($0.done) } ?? Double(j.hashedFiles)) : Double(j.doneBytes)
        let total = hashing ? (slow.map { Double($0.total) } ?? Double(j.hashTotal)) : Double(max(j.totalBytes, j.doneBytes))
        let elapsed = j.started.map { (j.finished ?? Date()).timeIntervalSince($0) } ?? 0
        var rate: Double?
        if let s = samples[j.id + (hashing ? "#hash" : "#copy")], let first = s.first, let last = s.last,
           last.0.timeIntervalSince(first.0) >= 4, last.1 > first.1 {
            rate = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
        } else if !hashing, let r = j.rate {
            rate = r
        }
        let remaining = rate.flatMap { $0 > 0 && total > done ? (total - done) / $0 : nil }
        return LiveStats(hashing: hashing, byBytes: !hashing || slow != nil, done: done, total: total, elapsed: elapsed, rate: rate, remaining: remaining)
    }

    func pollForever() async {
        while !Task.isCancelled {
            await refresh()
            let delay: UInt64 = runningCount > 0 ? 2 : 8
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
    }
}
