import Foundation

/// Thread-safe string accumulator for output captured from a `@Sendable` callback.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

/// Concrete `LinuxVM` that drives an in-process `LinuxEmulator` (iSH-AOK).
///
/// iOS cannot spawn subprocesses, so the guest runs inside the app and this type
/// provides the command/file bridge to it.
///
/// File transfer goes through the directory shared with the guest at `/host`
/// (`hostShare`), *not* through the command pipe: an `.ipa` is easily tens of
/// megabytes, and piping that as base64 through a shell would both truncate and
/// exhaust memory. The pipe is only a fallback for when no share is configured.
@MainActor
final class EmbeddedLinuxVM: LinuxVM {
    let root: URL
    private let hostShare: URL?
    private let emulator: LinuxEmulator
    private(set) var isBooted = false

    /// No timeout: builds run in the foreground and may legitimately take minutes.
    private static let noTimeout: TimeInterval = 0
    /// Capture cap for the base64 fallback path (the share path is uncapped).
    private static let outputCap = 64 * 1024 * 1024
    /// Guest path of the shared host directory.
    private static let guestShare = "/host"
    /// Staging subdirectory inside the share used for transfers.
    private static let transferDir = ".xforge-transfer"

    init(root: URL, hostShare: URL? = nil, emulator: LinuxEmulator) {
        self.root = root
        self.hostShare = hostShare
        self.emulator = emulator
    }

    func boot() async throws {
        guard !isBooted else { return }
        try await emulator.boot()
        isBooted = emulator.isRunning
        if isBooted { await configureGuestResolver() }
    }

    /// Write the guest's `/etc/resolv.conf` from the device's own DNS.
    ///
    /// Resolution happens in the guest, and the bundled minirootfs ships no
    /// nameservers, so without this `apk add` — the first thing provisioning
    /// runs — cannot reach its repositories. Failure is not fatal: the guest
    /// still boots, and a user can see what happened in the engine log.
    private func configureGuestResolver() async {
        guard let share = hostShare else { return }
        let (text, source) = GuestNetwork.resolvConfForDevice()

        let staging = share.appendingPathComponent(Self.transferDir, isDirectory: true)
        let file = staging.appendingPathComponent("resolv.conf")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            XForgeLog.note("dns: could not stage resolv.conf: \(error.localizedDescription)")
            return
        }

        let status = (try? await run(
            // The file can be a dangling symlink into /run in newer roots, so
            // replace it rather than writing through it (same reason iSH-AOK's
            // app unlinks first).
            "rm -f /etc/resolv.conf && cp -f /host/\(Self.transferDir)/resolv.conf /etc/resolv.conf && cat /etc/resolv.conf",
            environment: nil
        ) { _ in }) ?? -1

        XForgeLog.note("dns: resolv.conf from \(source) servers (exit \(status)): "
            + text.split(separator: "\n").joined(separator: " "))

        // Prove resolution actually works, and say so in the log. A guest with a
        // correct-looking resolv.conf that still cannot resolve is the failure
        // that costs the most time to find: it looks like a code bug when it is
        // the network, or the Local Network permission, and the guest's own
        // error ("DNS: transient error") says nothing about which.
        let box = OutputBox()
        _ = try? await run("timeout 8 nslookup dl-cdn.alpinelinux.org 2>&1 | tail -3",
                           environment: nil) { box.append($0) }
        let answer = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        XForgeLog.note("dns: resolution probe: \(answer.isEmpty ? "(no output)" : answer)")
    }

    /// Run a command in the guest, forwarding its output, and return its exit code.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await boot()

        let env = environment.map { pairs in
            pairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + " "
        } ?? ""

        let result = try await emulator.runCommand(
            env + command,
            shell: nil,
            timeout: Self.noTimeout,
            maxOutput: Self.outputCap
        )
        if !result.output.isEmpty {
            onOutput(result.output)
        }
        if result.truncated {
            onOutput("\n[output truncated at \(Self.outputCap / (1024 * 1024)) MB]\n")
        }
        return result.status
    }

    // MARK: - File transfer

    /// Copy a file out of the guest into a host URL.
    func copyOut(guestPath: String, to hostURL: URL) async throws {
        if let share = hostShare {
            let name = "out-\(UUID().uuidString)"
            let status = try await run(
                "mkdir -p \(Self.guestShare)/\(Self.transferDir) && "
                + "cp -f '\(guestPath)' '\(Self.guestShare)/\(Self.transferDir)/\(name)'",
                environment: nil
            ) { _ in }
            guard status == 0 else { throw LinuxVMError.fileCopyFailed }

            let staged = share
                .appendingPathComponent(Self.transferDir, isDirectory: true)
                .appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: staged.path) else {
                throw LinuxVMError.fileCopyFailed
            }
            try? FileManager.default.removeItem(at: hostURL)
            try FileManager.default.createDirectory(
                at: hostURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staged, to: hostURL)
            return
        }

        // Fallback: base64 over the shell.
        let box = OutputBox()
        let code = try await run(
            "base64 -w0 '\(guestPath)' 2>/dev/null || echo __XF_COPY_ERR__",
            environment: nil
        ) { box.append($0) }

        let trimmed = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !trimmed.contains("__XF_COPY_ERR__"),
              let data = Data(base64Encoded: trimmed) else {
            throw LinuxVMError.fileCopyFailed
        }
        try FileManager.default.createDirectory(
            at: hostURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: hostURL)
    }

    /// Copy a host file into the guest.
    func copyIn(hostURL: URL, to guestPath: String) async throws {
        if let share = hostShare {
            let name = "in-\(UUID().uuidString)"
            let staging = share
                .appendingPathComponent(Self.transferDir, isDirectory: true)
                .appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: hostURL, to: staging)

            let dir = (guestPath as NSString).deletingLastPathComponent
            let status = try await run(
                "mkdir -p '\(dir)' && cp -f '\(Self.guestShare)/\(Self.transferDir)/\(name)' '\(guestPath)' && "
                + "rm -f '\(Self.guestShare)/\(Self.transferDir)/\(name)'",
                environment: nil
            ) { _ in }
            guard status == 0 else { throw LinuxVMError.fileCopyFailed }
            return
        }

        let data = try Data(contentsOf: hostURL)
        let b64 = data.base64EncodedString()
        let dir = (guestPath as NSString).deletingLastPathComponent
        let status = try await run(
            "mkdir -p '\(dir)' && base64 -d > '\(guestPath)' <<'__XF_B64__'\n\(b64)\n__XF_B64__\n",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw LinuxVMError.fileCopyFailed }
    }
}

enum LinuxVMError: LocalizedError {
    case notImplemented(String)
    case fileCopyFailed

    var errorDescription: String? {
        switch self {
        case .notImplemented(let m): return m
        case .fileCopyFailed:
            return "Could not copy the file to/from the embedded Linux."
        }
    }
}
