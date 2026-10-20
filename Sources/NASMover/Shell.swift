import Foundation

/// Single-quotes a string for a POSIX shell.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct CommandResult {
    var out: Data
    var err: String
    var code: Int32
    var text: String { String(decoding: out, as: UTF8.self) }
}

struct SSHError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum SSH {
    static let localDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nasmover")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Runs `command` on `target` over SSH. Connections are multiplexed so repeated calls are cheap.
    static func run(_ target: String, _ command: String, stdin: Data? = nil) async throws -> CommandResult {
        try await launch([
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(localDir.path)/cm-%C",
            "-o", "ControlPersist=300",
            target, command,
        ], target: target, command: command, stdin: stdin)
    }

    /// Runs `command` logging in with a password (used once, by Setup, to install a key).
    /// The password reaches ssh through a short-lived askpass helper, never the command line or disk.
    static func runWithPassword(_ target: String, _ command: String, password: String, stdin: Data? = nil) async throws -> CommandResult {
        let askpass = localDir.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$NASMOVER_PW\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["NASMOVER_PW"] = password
        return try await launch([
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
            target, command,
        ], target: target, command: "(password login) " + command, stdin: stdin, env: env)
    }

    private static func launch(_ args: [String], target: String, command: String, stdin: Data?, env: [String: String]? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = args
                if let env { p.environment = env }
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                p.standardInput = inPipe
                do { try p.run() } catch {
                    cont.resume(throwing: SSHError(message: "Could not start ssh: \(error.localizedDescription)"))
                    return
                }
                var errData = Data()
                let errReader = DispatchQueue(label: "ssh-stderr")
                let group = DispatchGroup()
                group.enter()
                errReader.async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                DispatchQueue.global().async {
                    if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                    try? inPipe.fileHandleForWriting.close()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                log("\(target) exit=\(p.terminationStatus) cmd=\(command.prefix(120).replacingOccurrences(of: "\n", with: " "))"
                    + (errData.isEmpty ? "" : " err=\(String(decoding: errData.prefix(300), as: UTF8.self))"))
                cont.resume(returning: CommandResult(out: outData, err: String(decoding: errData, as: UTF8.self), code: p.terminationStatus))
            }
        }
    }

    private static let logQueue = DispatchQueue(label: "nasmover-log")

    /// Appends to ~/.nasmover/app.log (trimmed when it passes 2 MB).
    static func log(_ line: String) {
        logQueue.async {
            let url = localDir.appendingPathComponent("app.log")
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                if (try? h.seekToEnd()) ?? 0 > 2_000_000 { try? h.truncate(atOffset: 0) }
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Like `run`, but throws when the command exits non-zero.
    static func check(_ target: String, _ command: String, stdin: Data? = nil) async throws -> String {
        let r = try await run(target, command, stdin: stdin)
        if r.code != 0 {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("No route to host") {
                throw SSHError(message: "macOS is blocking local network access. Open System Settings › Privacy & Security › Local Network, turn on NAS Mover, then click Retry.")
            }
            throw SSHError(message: msg.isEmpty ? "Command failed on \(target) (exit \(r.code))" : msg)
        }
        return r.text
    }
}
