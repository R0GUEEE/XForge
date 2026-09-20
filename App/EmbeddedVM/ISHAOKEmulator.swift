import Foundation

/// A serial executor backed by one permanent OS thread.
///
/// A DispatchQueue is not sufficient here: it preserves ordering but may move
/// work between pthreads. iSH-AOK stores its active guest process in thread-local
/// storage, so importing, booting, and every command must run on the exact same
/// pthread for the lifetime of the guest.
private final class GuestThreadExecutor: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var thread: Thread?

    init() {
        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "org.xforge.ish.guest"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func submit(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}

/// `LinuxEmulator` backed by the embedded iSH-AOK engine.
///
/// iSH-AOK runs a real Linux guest in-process (its aarch64 "gadget JIT" needs no
/// JIT entitlement, so it works in a sideloaded app). The root filesystem is the
/// Alpine aarch64 minirootfs bundled in the app; on first boot it is imported
/// into iSH-AOK's `fakefs` format, then mounted as `/`.
///
/// Threading: iSH-AOK keeps its current guest task in a thread-local, so boot and
/// every command run serialized on one dedicated queue.
@MainActor
final class ISHAOKEmulator: LinuxEmulator {
    let name = "iSH-AOK (arm64 guest)"
    private(set) var isRunning = false

    private let rootsDirectory: URL
    private let hostDirectory: URL
    private let guestThread = GuestThreadExecutor()

    init(rootsDirectory: URL, hostDirectory: URL) {
        self.rootsDirectory = rootsDirectory
        self.hostDirectory = hostDirectory
    }

    func boot() async throws {
        guard !isRunning else { return }
        let roots = rootsDirectory
        let host = hostDirectory
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guestThread.submit {
                do {
                    // Capture the engine's own log before it can write anything:
                    // its kernel messages (including the one `die()` prints on
                    // its way to `abort()`) go to fd 555 and are otherwise
                    // discarded by an iOS app.
                    XForgeLog.prepare()
                    XForgeLog.note("emulator: boot requested (rootfs \(roots.lastPathComponent))")

                    // Import the bundled Alpine rootfs into fakefs the first
                    // time; subsequent launches reuse it.
                    let root = try RootfsInstaller.installIfNeeded(into: roots)
                    XForgeLog.note("emulator: rootfs ready at \(root.lastPathComponent)")
                    let rc = root.path.withCString { rootPath in
                        host.path.withCString { hostPath in
                            xf_ish_boot(rootPath, hostPath)
                        }
                    }
                    guard rc == 0 else {
                        throw LinuxVMError.notImplemented(ishLastError(fallback: "Could not boot the guest (errno \(rc))."))
                    }
                    XForgeLog.note("emulator: boot complete")
                    continuation.resume()
                } catch {
                    XForgeLog.note("emulator: boot failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
        isRunning = true
    }

    /// Import the bundled rootfs on the guest's permanent serial thread,
    /// without booting the emulator. The importer itself is host-only; the
    /// engine's one-time initialization happens later in `boot()`.
    func prepareRootfs() async throws {
        let roots = rootsDirectory
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guestThread.submit {
                do {
                    XForgeLog.prepare()
                    XForgeLog.note("emulator: rootfs pre-install requested")
                    let root = try RootfsInstaller.installIfNeeded(into: roots)
                    XForgeLog.note("emulator: rootfs pre-installed at \(root.lastPathComponent)")
                    continuation.resume()
                } catch {
                    XForgeLog.note("emulator: rootfs pre-install failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func runCommand(
        _ command: String,
        shell: String?,
        timeout: TimeInterval,
        maxOutput: Int
    ) async throws -> GuestCommandResult {
        if !isRunning { try await boot() }
        let timeoutMs = timeout <= 0 ? 0 : Int32(min(timeout * 1000, Double(Int32.max)))
        let maxOut = maxOutput > 0 ? maxOutput : 256 * 1024

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestCommandResult, Error>) in
            guestThread.submit {
                var raw = xf_guest_result()
                let rc: Int32 = command.withCString { cCommand in
                    if let shell {
                        return shell.withCString { cShell in
                            xf_ish_run(cCommand, cShell, timeoutMs, maxOut, &raw)
                        }
                    }
                    return xf_ish_run(cCommand, nil, timeoutMs, maxOut, &raw)
                }
                guard rc == 0 else {
                    continuation.resume(throwing: LinuxVMError.notImplemented(
                        ishLastError(fallback: "The command could not start (errno \(rc)).")))
                    return
                }

                let output = raw.output.map { String(cString: $0) } ?? ""
                let result = GuestCommandResult(
                    launched: raw.launched != 0,
                    exited: raw.exited != 0,
                    exitCode: raw.exit_code,
                    termSignal: raw.term_signal,
                    timedOut: raw.timed_out != 0,
                    truncated: raw.truncated != 0,
                    output: output
                )
                var mutable = raw
                xf_guest_result_free(&mutable)
                continuation.resume(returning: result)
            }
        }
    }

    func shutdown() async {
        guard isRunning else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guestThread.submit {
                xf_ish_shutdown()
                continuation.resume()
            }
        }
        isRunning = false
    }
}

/// Reads the bridge's thread-local last error. Must be called on the guest thread.
private func ishLastError(fallback: String) -> String {
    let message = String(cString: xf_ish_last_error())
    return message.isEmpty ? fallback : message
}
