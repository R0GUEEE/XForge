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
    private var bootTask: Task<Void, Error>?

    /// No timeout: builds run in the foreground and may legitimately take minutes.
    private static let noTimeout: TimeInterval = 0
    /// Capture cap for the base64 fallback path (the share path is uncapped).
    private static let outputCap = 64 * 1024 * 1024
    /// Guest path of the shared host directory.
    private static let guestShare = "/host"
    /// Staging subdirectory inside the share used for transfers.
    private static let transferDir = ".xforge-transfer"
    /// Launch command for an interactive terminal session: a login shell for
    /// root. Commands are fed to it on stdin, so they run with a login
    /// environment rather than a bare `sh -c`.
    static let launchCommand = "/bin/sh"

    init(root: URL, hostShare: URL? = nil, emulator: LinuxEmulator) {
        self.root = root
        self.hostShare = hostShare
        self.emulator = emulator
    }

    func boot() async throws {
        guard !isBooted else { return }
        if let bootTask {
            try await bootTask.value
            return
        }

        let task = Task {
            if !emulator.isRunning {
                try await emulator.boot()
            }
            guard emulator.isRunning else {
                throw LinuxVMError.guestDidNotStart
            }
            try await verifyRootfs()
            isBooted = true
            do {
                try await verifyCommandBridge()
            } catch {
                isBooted = false
                throw error
            }
            await configureGuestResolver()
        }
        bootTask = task
        do {
            try await task.value
            bootTask = nil
        } catch {
            isBooted = false
            bootTask = nil
            throw error
        }
    }

    /// Import the bundled rootfs before anything needs the guest, so the first
    /// build or terminal session is not the one that pays for it. Best effort:
    /// `boot()` imports it anyway when this has not run or has failed.
    func prepareRootfs() async {
        do {
            try await emulator.prepareRootfs()
        } catch {
            XForgeLog.note("rootfs: pre-install failed: \(error.localizedDescription)")
        }
    }

    /// Confirm that the mounted filesystem is a usable Alpine guest before any
    /// app feature is allowed to issue commands. This deliberately calls the
    /// emulator directly because the normal command path waits for boot.
    private func verifyRootfs() async throws {
        let probe = """
        set -eu
        test -x /bin/sh
        test -r /etc/alpine-release
        test -r /proc/version
        test -e /dev/null
        test -d /host
        __xf_probe=/root/.xforge-health-$$
        printf x > "$__xf_probe"
        test "$(cat "$__xf_probe")" = x
        rm -f "$__xf_probe"
        printf 'Alpine %s; kernel %s; shell %s\\n' \
            "$(cat /etc/alpine-release)" "$(uname -r)" "/bin/sh"
        """
        let result = try await emulator.runCommand(
            probe,
            shell: Self.launchCommand,
            timeout: 15,
            maxOutput: 64 * 1024
        )
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw LinuxVMError.guestHealthCheckFailed(
                detail.isEmpty ? "health check exited \(result.status)" : detail)
        }
        XForgeLog.note("rootfs: \(detail); /proc, /dev, /host, and writable root verified")
    }

    /// Exercise the same guest-to-host streaming path used by Terminal and every
    /// app command. A mounted rootfs is not enough if command output cannot cross
    /// the /host realfs bridge back into Swift.
    private func verifyCommandBridge() async throws {
        let token = "__XFORGE_BRIDGE_OK__"
        let output = OutputBox()
        let status = try await runLoginStreaming(
            "printf '%s\\n' \(GuestShell.quote(token))",
            environment: nil,
            onOutput: output.append
        )
        let received = output.value
        guard status == 0, received.contains(token) else {
            let detail = received.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinuxVMError.commandBridgeFailed(
                detail.isEmpty ? "no output returned from the guest" : detail)
        }
        XForgeLog.note("bridge: interactive /host command round trip verified")
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

    /// Run every app command through the same interactive login-shell transport
    /// used by Terminal, forwarding output while the command is running.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await runLoginStreaming(
            command,
            environment: environment,
            onOutput: onOutput
        )
    }

    /// Low-level one-shot primitive used only to launch the login-shell transport.
    /// App features must call `run` so their commands use the interactive terminal.
    private func runCaptured(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await boot()

        let env = GuestShell.environment(environment)

        let result = try await emulator.runCommand(
            env + command,
            shell: Self.launchCommand,
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

    /// Run a script through XForge's default Alpine launch shell, streaming its
    /// merged stdout+stderr to `onOutput` **as the guest writes it**.
    ///
    /// The engine's command primitive returns a command's output only once it
    /// has finished, so live output cannot come from there. Instead the guest
    /// redirects the session's output into the shared folder (`/host`), which is
    /// realfs, and the host tails that file while the (blocking) command is still
    /// running. The command's exit status still comes back from the engine.
    func runLoginStreaming(
        _ script: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await boot()
        guard let share = hostShare else {
            // No shared folder to tail; fall back to the captured output.
            return try await runCaptured(script, environment: environment, onOutput: onOutput)
        }

        let transfer = share.appendingPathComponent(Self.transferDir, isDirectory: true)
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        let name = "term-\(UUID().uuidString).log"
        let logURL = transfer.appendingPathComponent(name)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let guestLog = "\(Self.guestShare)/\(Self.transferDir)/\(name)"

        // The C bridge already runs this text as `/bin/sh -c`. A login
        // program requires a TTY and exits 1 in this headless command runner.
        let wrapped = """
        {
        \(script)
        } > \(GuestShell.quote(guestLog)) 2>&1
        """

        let tailer = FileTailer(url: logURL, onChunk: onOutput)
        tailer.start()
        do {
            let status = try await runCaptured(wrapped, environment: environment) { _ in }
            tailer.stop()
            try? FileManager.default.removeItem(at: logURL)
            return status
        } catch {
            tailer.stop()
            try? FileManager.default.removeItem(at: logURL)
            throw error
        }
    }

    // MARK: - File transfer

    /// Copy a file out of the guest into a host URL.
    func copyOut(guestPath: String, to hostURL: URL) async throws {
        if let share = hostShare {
            let name = "out-\(UUID().uuidString)"
            let status = try await run(
                "mkdir -p \(Self.guestShare)/\(Self.transferDir) && "
                + "cp -f \(GuestShell.quote(guestPath)) "
                + "\(GuestShell.quote("\(Self.guestShare)/\(Self.transferDir)/\(name)"))",
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
            "base64 -w0 \(GuestShell.quote(guestPath)) 2>/dev/null || echo __XF_COPY_ERR__",
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
                "mkdir -p \(GuestShell.quote(dir)) && "
                + "cp -f \(GuestShell.quote("\(Self.guestShare)/\(Self.transferDir)/\(name)")) "
                + "\(GuestShell.quote(guestPath)) && "
                + "rm -f \(GuestShell.quote("\(Self.guestShare)/\(Self.transferDir)/\(name)"))",
                environment: nil
            ) { _ in }
            guard status == 0 else { throw LinuxVMError.fileCopyFailed }
            return
        }

        let data = try Data(contentsOf: hostURL)
        let b64 = data.base64EncodedString()
        let dir = (guestPath as NSString).deletingLastPathComponent
        let status = try await run(
            "mkdir -p \(GuestShell.quote(dir)) && base64 -d > \(GuestShell.quote(guestPath)) "
            + "<<'__XF_B64__'\n\(b64)\n__XF_B64__\n",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw LinuxVMError.fileCopyFailed }
    }
}

enum LinuxVMError: LocalizedError {
    case notImplemented(String)
    case fileCopyFailed
    case guestDidNotStart
    case guestHealthCheckFailed(String)
    case commandBridgeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let m): return m
        case .fileCopyFailed:
            return "Could not copy the file to/from the embedded Linux."
        case .guestDidNotStart:
            return "The embedded Linux engine did not start."
        case .guestHealthCheckFailed(let detail):
            return "The Alpine system started but is not usable: \(detail)"
        case .commandBridgeFailed(let detail):
            return "Linux started, but XForge could not communicate with it: \(detail)"
        }
    }
}

/// Polls a file as the guest appends to it and hands each new chunk to `onChunk`.
///
/// This is what makes the terminal live despite the engine's one-shot command
/// primitive: the guest writes its output into the shared folder, and this reads
/// it back while the command is still running. `onChunk` runs on a private queue
/// and must not block (hop to the main actor asynchronously instead).
private final class FileTailer: @unchecked Sendable {
    private let url: URL
    private let onChunk: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "org.xforge.terminal.tail")
    private var offset: UInt64 = 0
    private var running = false

    init(url: URL, onChunk: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.onChunk = onChunk
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            poll()
        }
    }

    func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            drain()
        }
    }

    private func poll() {
        guard running else { return }
        drain()
        queue.asyncAfter(deadline: .now() + .milliseconds(80)) { [self] in poll() }
    }

    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            onChunk(String(decoding: data, as: UTF8.self))
        } catch {
            // The file may not exist (or have new bytes) yet; the next tick retries.
        }
    }
}
