import Foundation

/// A serial executor backed by one permanent OS thread.
///
/// A DispatchQueue is not sufficient here: it preserves ordering but may move
/// work between pthreads. ish-arm64 stores its active guest process in thread-local
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

/// `LinuxEmulator` backed by the embedded ish-arm64 engine.
///
/// ish-arm64 runs a real Linux guest in-process: its aarch64 backend dispatches
/// guest instructions to pre-compiled "gadget" functions rather than emitting
/// machine code, so it needs no JIT entitlement and works in a sideloaded app.
/// The root filesystem is the Alpine aarch64 minirootfs bundled in the app; on
/// first boot it is imported into the engine's `fakefs` format, then mounted as `/`.
///
/// Threading: ish-arm64 keeps its current guest task in a thread-local, so boot and
/// every command run serialized on one dedicated queue.
@MainActor
final class ISHEmulator: LinuxEmulator {
    let name = "ish-arm64 (arm64 guest)"
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
                    // Capture XForge's own breadcrumbs before the engine can
                    // write anything. The engine's kernel messages go through
                    // its build-time log handler (nslog, so they reach the
                    // device console); this file is the boot/import/command
                    // trace that makes a bug report readable.
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

    func startInit(_ program: String) async throws {
        if !isRunning { try await boot() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guestThread.submit {
                let rc = program.withCString { xf_ish_start_init($0) }
                guard rc == 0 else {
                    continuation.resume(throwing: LinuxVMError.notImplemented(
                        ishLastError(fallback: "The guest's init could not start (errno \(rc)).")))
                    return
                }
                XForgeLog.note("emulator: \(program) is pid 1")
                continuation.resume()
            }
        }
    }

    func openConsole(
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> any GuestConsole {
        if !isRunning { try await boot() }
        let console = BridgeConsole(onOutput: onOutput)
        console.startReading()
        XForgeLog.note("emulator: console reader started")
        return console
    }

    func startDetached(
        _ command: String,
        shell: String?,
        stdinPath: String?
    ) async throws -> DetachedProcess {
        if !isRunning { try await boot() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DetachedProcess, Error>) in
            guestThread.submit {
                let rc: Int32 = command.withCString { cCommand in
                    let run: (UnsafePointer<CChar>?) -> Int32 = { cShell in
                        if let stdinPath {
                            return stdinPath.withCString { cStdin in
                                xf_ish_run_detached(cCommand, cShell, cStdin)
                            }
                        }
                        return xf_ish_run_detached(cCommand, cShell, nil)
                    }
                    if let shell { return shell.withCString { run($0) } }
                    return run(nil)
                }
                guard rc > 0 else {
                    // Negative: the process never started. Report it rather than
                    // handing back a handle to something that does not exist.
                    continuation.resume(throwing: LinuxVMError.notImplemented(
                        ishLastError(fallback: "The process could not start (errno \(rc)).")))
                    return
                }
                continuation.resume(returning: GuestProcess(pid: rc, thread: self.guestThread))
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

/// A guest process started by `ISHEmulator.startDetached`.
///
/// Every call hops onto the one guest thread, because the engine may only be
/// driven from there. The thread is free precisely because the process was
/// *started* detached rather than run to completion — which is the whole reason
/// this exists: a blocking run would have held that thread for the process's
/// lifetime and starved everything else in the app.
///
/// Deliberately NOT `@MainActor`: it is a handle to something that lives on the
/// guest thread, and it is constructed from inside that thread's queue. Marking
/// it main-actor isolated made its initialiser unreachable from where it is
/// created, and it has no main-actor state to protect.
private final class GuestProcess: DetachedProcess, @unchecked Sendable {
    let pid: Int32
    private let thread: GuestThreadExecutor

    init(pid: Int32, thread: GuestThreadExecutor) {
        self.pid = pid
        self.thread = thread
    }

    var isRunning: Bool {
        // Asks the guest, which means hopping onto its thread — so this is
        // `async` rather than a plain property, and it does not block: the hop is
        // a queued job that completes immediately, not a wait on the process.
        get async { await checkAlive() }
    }

    private func checkAlive() async -> Bool {
        let pid = self.pid
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            thread.submit {
                continuation.resume(returning: xf_ish_process_alive(pid) == 1)
            }
        }
    }

    func signal(_ number: Int32) async {
        let pid = self.pid
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            thread.submit {
                _ = xf_ish_kill_process(pid, number)
                continuation.resume()
            }
        }
    }

    /// Poll for exit rather than blocking the guest thread.
    ///
    /// A blocking wait would occupy the one thread the engine allows, for as long
    /// as the process runs — the very starvation that detached processes exist to
    /// avoid. Polling asks a cheap question repeatedly instead, leaving the thread
    /// free between asks.
    @discardableResult
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : nil
        while true {
            if !(await checkAlive()) { return true }
            if let deadline, Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// The host end of the guest's console tty.
///
/// Two directions, two threads, because that is what a terminal is:
///  - **out**: a thread of its own blocks in `xf_ish_console_read` and hands each
///    chunk to `onOutput` as the guest writes it. It is not the engine's thread:
///    reading the console touches none of the engine's per-thread guest state, and
///    the engine thread has to stay free to run the guest (and any command
///    XForge has started) while output streams out.
///  - **in**: writes are handed to a serial queue. A tty's input buffer is small,
///    so a paste larger than it has to be pushed in pieces, waiting for the guest
///    to drain each one — and that waiting must not happen on the thread that is
///    handling a keystroke.
final class BridgeConsole: GuestConsole, @unchecked Sendable {
    /// Big enough that a screenful arrives in a single read, small enough that a
    /// burst of output does not allocate.
    private static let readChunk = 32 * 1024
    /// How long a single read waits before the loop checks whether it should stop.
    private static let readTimeoutMs: Int32 = 500
    /// Give up on an input burst the guest has not drained — a tty nobody is
    /// reading from must not wedge the keyboard.
    private static let inputDeadline: TimeInterval = 5

    private let onOutput: @Sendable (String) -> Void
    private let inputQueue = DispatchQueue(label: "org.xforge.console.input")
    private let state = NSLock()
    private var stopped = false

    init(onOutput: @escaping @Sendable (String) -> Void) {
        self.onOutput = onOutput
    }

    deinit {
        stop()
    }

    var isReady: Bool { xf_ish_console_ready() == 1 }

    /// Begin delivering the console's output. Called once, by the emulator.
    func startReading() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "org.xforge.console.reader"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 256 * 1024
        thread.start()
    }

    @discardableResult
    func write(_ text: String) -> Bool {
        guard !text.isEmpty, let data = text.data(using: .utf8), !data.isEmpty else {
            return false
        }
        // `GuestConsole` promises `false` for "there is no console to write to",
        // and the terminal reports that to the user. Returning `true` here
        // unconditionally meant input was accepted, queued against a console that
        // was stopped or not up yet, and silently dropped — the one failure mode a
        // terminal must not have.
        guard !isStopped, isReady else { return false }
        inputQueue.async { [weak self] in self?.push(data) }
        return true
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let result = xf_ish_console_resize(Int32(cols), Int32(rows))
        if result != 0 {
            XForgeLog.note("console: could not set \(cols)x\(rows) (error \(result))")
        }
    }

    func stop() {
        state.lock()
        stopped = true
        state.unlock()
    }

    private var isStopped: Bool {
        state.lock()
        defer { state.unlock() }
        return stopped
    }

    /// Read until stopped. `xf_ish_console_read` returns 0 when its short wait
    /// expires, which is what gives this loop the chance to notice `stop()`.
    private func readLoop() {
        var buffer = [CChar](repeating: 0, count: Self.readChunk)
        while !isStopped {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Int(xf_ish_console_read(base, pointer.count, Self.readTimeoutMs))
            }
            guard count > 0 else { continue }
            let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
            onOutput(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// Push input in pieces, waiting for the guest to drain the tty between them.
    private func push(_ data: Data) {
        var offset = 0
        let deadline = Date().addingTimeInterval(Self.inputDeadline)
        while offset < data.count, !isStopped, Date() < deadline {
            let accepted = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return -1 }
                return Int(xf_ish_console_write(base + offset, data.count - offset))
            }
            if accepted > 0 {
                offset += accepted
                continue
            }
            // No console yet, or its buffer is full while the guest reads.
            Thread.sleep(forTimeInterval: 0.01)
        }
        if offset < data.count {
            XForgeLog.note("console: \(data.count - offset) byte(s) of input not delivered")
        }
    }
}

/// Reads the bridge's thread-local last error. Must be called on the guest thread.
private func ishLastError(fallback: String) -> String {
    let message = String(cString: xf_ish_last_error())
    return message.isEmpty ? fallback : message
}
