import SwiftUI

/// One-time, per-Mac setup: SSH keys from this Mac to both NASes, and from the QNAP to the UNAS.
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var macPublicKey: URL? {
        ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"]
            .map { home.appendingPathComponent(".ssh/" + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func createMacKey() throws {
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "ed25519", "-N", "", "-C", "nas-mover@\(Host.current().localizedName ?? "mac")",
                       "-f", ssh.appendingPathComponent("id_ed25519").path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SSHError(message: "ssh-keygen failed") }
    }

    /// True if key-based login to `target` works.
    static func canLogIn(_ target: String) async -> Bool {
        guard !target.isEmpty, let r = try? await SSH.run(target, "true") else { return false }
        return r.code == 0
    }

    /// Adds this Mac's public key to `target`'s authorized_keys, logging in once with `password`.
    static func installMacKey(_ target: String, password: String) async throws {
        guard let pub = macPublicKey else { throw SSHError(message: "Create this Mac's SSH key first.") }
        let key = try String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let script = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && K=$(cat) && (grep -qxF \"$K\" ~/.ssh/authorized_keys || echo \"$K\" >> ~/.ssh/authorized_keys)"
        let r = try await SSH.runWithPassword(target, script, password: password, stdin: Data((key + "\n").utf8))
        if r.code != 0 {
            let e = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError(message: e.contains("denied") ? "Login refused. Check the user name and password." : (e.isEmpty ? "Couldn't install the key (exit \(r.code))." : e))
        }
    }

    /// Lets the QNAP log in to the UNAS by itself (jobs run on the QNAP). Returns the target to use from the QNAP.
    static func linkQnapToUnas(qnap: String, unas: String) async throws -> String {
        // 1. A key on the QNAP.
        let qpub = try await SSH.check(qnap, "[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C nas-mover-qnap -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 2. Trust it on the UNAS, and read the UNAS's own host key and addresses (authoritative, no scanning).
        _ = try await SSH.check(unas, "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && K=$(cat) && (grep -qxF \"$K\" ~/.ssh/authorized_keys || echo \"$K\" >> ~/.ssh/authorized_keys)",
                                stdin: Data((qpub + "\n").utf8))
        let hostKey = try await SSH.check(unas, "cat /etc/ssh/ssh_host_ed25519_key.pub").split(separator: " ").prefix(2).joined(separator: " ")
        let ips = try await SSH.check(unas, "hostname -I 2>/dev/null || hostname -i").split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(".") && !$0.hasPrefix("127.") && !$0.hasPrefix("172.") }
        let user = unas.contains("@") ? String(unas.split(separator: "@")[0]) : "root"
        // 3. Pin the host key on the QNAP and try each address until one works.
        for ip in ips {
            let line = "\(ip) \(hostKey)"
            _ = try await SSH.check(qnap, "touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts && (grep -qxF \(shq(line)) ~/.ssh/known_hosts || echo \(shq(line)) >> ~/.ssh/known_hosts)")
            let target = "\(user)@\(ip)"
            let r = try await SSH.run(qnap, "ssh -o BatchMode=yes -o ConnectTimeout=5 \(shq(target)) true")
            if r.code == 0 { return target }
        }
        throw SSHError(message: "The QNAP couldn't reach the UNAS on \(ips.joined(separator: ", ")).")
    }

    static func qnapReachesUnas(qnap: String, via: String) async -> Bool {
        guard !via.isEmpty, let r = try? await SSH.run(qnap, "ssh -o BatchMode=yes -o ConnectTimeout=5 \(shq(via)) true") else { return false }
        return r.code == 0
    }

    /// The user:group that owns most files in the UNAS shares (so copies look like everything else).
    static func detectUnasOwner(_ unas: String) async -> String? {
        let cmd = "for d in /volume/*/.srv/.unifi-drive/*/.data; do find \"$d\" -mindepth 1 -maxdepth 2 -printf '%u:%g\\n' 2>/dev/null | head -500; done | grep -v '^root:' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'"
        let out = (try? await SSH.check(unas, cmd))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }
}

enum CheckState: Equatable {
    case unknown, checking, ok, failed(String)
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var qnapHost = ""
    @Published var qnapUser = ""
    @Published var unasHost = ""
    @Published var unasUser = "root"
    @Published var qnapPassword = ""
    @Published var unasPassword = ""

    @Published var macKey: CheckState = .unknown
    @Published var qnap: CheckState = .unknown
    @Published var unas: CheckState = .unknown
    @Published var link: CheckState = .unknown
    @Published var owner = ""
    @Published var unasFromQnap = ""
    @Published var busy = false

    init() {
        let s = AppSettings.shared
        (qnapUser, qnapHost) = Self.split(s.qnapTarget, defaultUser: "")
        (unasUser, unasHost) = Self.split(s.unasTarget, defaultUser: "root")
        owner = s.unasOwner
        unasFromQnap = s.unasFromQnap
    }

    static func split(_ t: String, defaultUser: String) -> (String, String) {
        guard let at = t.firstIndex(of: "@") else { return (defaultUser, t) }
        return (String(t[..<at]), String(t[t.index(after: at)...]))
    }

    var qnapTarget: String { qnapUser.isEmpty ? qnapHost : "\(qnapUser)@\(qnapHost)" }
    var unasTarget: String { unasUser.isEmpty ? unasHost : "\(unasUser)@\(unasHost)" }
    var canFinish: Bool { qnap == .ok && unas == .ok && link == .ok }

    func checkAll() async {
        busy = true
        macKey = Setup.macPublicKey == nil ? .failed("No SSH key on this Mac yet.") : .ok
        if !qnapHost.isEmpty { qnap = .checking }
        if !unasHost.isEmpty { unas = .checking }
        async let q = Setup.canLogIn(qnapTarget)
        async let u = Setup.canLogIn(unasTarget)
        let (qok, uok) = await (q, u)
        qnap = qnapHost.isEmpty ? .unknown : (qok ? .ok : .failed("Key login doesn't work yet."))
        unas = unasHost.isEmpty ? .unknown : (uok ? .ok : .failed("Key login doesn't work yet."))
        if qok && uok {
            link = .checking
            link = await Setup.qnapReachesUnas(qnap: qnapTarget, via: unasFromQnap) ? .ok : .failed("Not linked yet.")
            if owner.isEmpty, let o = await Setup.detectUnasOwner(unasTarget) { owner = o }
        }
        busy = false
    }

    func createKey() async {
        do { try Setup.createMacKey() } catch { macKey = .failed(error.localizedDescription) }
        await checkAll()
    }

    func install(_ host: HostID) async {
        busy = true
        let target = host == .qnap ? qnapTarget : unasTarget
        let pw = host == .qnap ? qnapPassword : unasPassword
        do {
            try await Setup.installMacKey(target, password: pw)
        } catch {
            if host == .qnap { qnap = .failed(error.localizedDescription) } else { unas = .failed(error.localizedDescription) }
            busy = false
            return
        }
        if host == .qnap { qnapPassword = "" } else { unasPassword = "" }
        await checkAll()
    }

    func linkHosts() async {
        busy = true
        link = .checking
        do {
            unasFromQnap = try await Setup.linkQnapToUnas(qnap: qnapTarget, unas: unasTarget)
            link = .ok
        } catch {
            link = .failed(error.localizedDescription)
        }
        busy = false
    }

    func save() {
        let s = AppSettings.shared
        s.qnapTarget = qnapTarget
        s.unasTarget = unasTarget
        s.unasFromQnap = unasFromQnap
        s.unasOwner = owner
        NAS.resetCache()
    }
}

struct SetupView: View {
    var done: () -> Void
    @StateObject private var m = SetupModel()
    @EnvironmentObject var shares: ShareStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Set up NAS Mover").font(.title2.bold())
                    Text("Connects this Mac to your QNAP and UNAS with SSH keys. Passwords are used once to install the key and never stored.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Section("Addresses") {
                    HStack {
                        TextField("QNAP address", text: $m.qnapHost, prompt: Text("qnap.local or 10.0.0.5"))
                        TextField("User", text: $m.qnapUser, prompt: Text("admin")).frame(width: 140)
                    }
                    HStack {
                        TextField("UNAS address", text: $m.unasHost, prompt: Text("unas.local or 10.0.0.6"))
                        TextField("User", text: $m.unasUser).frame(width: 140)
                    }
                    Text("QNAP: enable SSH in Control Panel › Network & File Services › Telnet/SSH (an administrator account is required). UNAS: enable SSH and set its password in UniFi under Settings › Control Plane › Console › Advanced; the user is root.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check Connections") { Task { await m.checkAll() } }
                        .disabled(m.busy || m.qnapHost.isEmpty || m.unasHost.isEmpty)
                }

                Section("Steps") {
                    step("This Mac has an SSH key", m.macKey) {
                        Button("Create Key") { Task { await m.createKey() } }
                    }
                    step("This Mac can log in to the QNAP", m.qnap) {
                        passwordInstall($m.qnapPassword) { Task { await m.install(.qnap) } }
                    }
                    step("This Mac can log in to the UNAS", m.unas) {
                        passwordInstall($m.unasPassword) { Task { await m.install(.unas) } }
                    }
                    step("The QNAP can log in to the UNAS (jobs run on the QNAP)", m.link) {
                        Button("Link Them") { Task { await m.linkHosts() } }.disabled(m.qnap != .ok || m.unas != .ok)
                    }
                    if m.link == .ok {
                        LabeledContent("QNAP reaches the UNAS as", value: m.unasFromQnap)
                    }
                    TextField("Owner for files written to the UNAS", text: $m.owner, prompt: Text("detected automatically"))
                }
            }
            .formStyle(.grouped)
            .disabled(m.busy)

            HStack {
                if m.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save") {
                    m.save()
                    Task { await shares.reload() }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!m.canFinish)
            }
        }
        .padding(24)
        .frame(width: 640)
        .task { if !m.qnapHost.isEmpty { await m.checkAll() } }
    }

    @ViewBuilder
    private func step<Fix: View>(_ title: String, _ state: CheckState, @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
            case .checking: ProgressView().controlSize(.small)
            case .unknown: Image(systemName: "circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if case .failed(let why) = state {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                    fix()
                }
            }
        }
    }

    private func passwordInstall(_ pw: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack {
            SecureField("Password (used once)", text: pw).frame(maxWidth: 220)
            Button("Install Key", action: action).disabled(pw.wrappedValue.isEmpty || Setup.macPublicKey == nil)
        }
    }
}
