import Foundation

/// Result of one headless command run in the guest.
struct GuestCommandResult: Sendable {
    var launched: Bool
    var exited: Bool
    var exitCode: Int32
    var termSignal: Int32
    var timedOut: Bool
    var truncated: Bool
    var output: String

    /// Exit status the caller should branch on (non-zero also for timeouts/signals).
    var status: Int32 {
        if timedOut { return 124 }          // like coreutils `timeout`
        if !exited && termSignal != 0 { return 128 + termSignal }
        return exitCode
    }
}

/// The host end of the guest's console — a real tty, so what the host writes goes
/// through the guest kernel's line discipline: it echoes, it edits, it turns
/// Ctrl-C into a signal for the foreground program, and it lets a full-screen
/// program put the terminal in raw mode.
///
/// Deliberately not main-actor isolated: reading blocks until the guest writes,
/// so it happens on a thread of its own, and the calls it makes touch no
/// per-thread engine state.
protocol GuestConsole: AnyObject, Sendable {
    /// Whether the guest has opened its console yet.
    var isReady: Bool { get }
    /// Push host input into the guest's console. Returns false only when there is
    /// no console to write to.
    @discardableResult func write(_ text: String) -> Bool
    /// Tell the guest how big the screen is, so its programs wrap and lay out
    /// correctly (and redraw when the size changes).
    func resize(cols: Int, rows: Int)
    /// Stop reading. Idempotent.
    func stop()
}

/// An in-process Linux execution engine.
///
/// iOS cannot spawn subprocesses, so the embedded Linux runs as a **library**
/// inside the app. XForge uses ish-arm64 (github.com/OpenMinis/ish-arm64): a real Linux
/// kernel + userspace emulator whose threaded-code interpreter dispatches aarch64
/// guest instructions to pre-compiled functions ("gadgets"). It emits no machine
/// code and needs no executable memory, so no JIT entitlement is required and it
/// works in a sideloaded app.
///
/// The engine's primitive is "run this command line, give me its merged output
/// and exit status" — the engine's guest command runner — not a byte
/// pipe. Conformers boot a guest and then execute commands through that. The one
/// exception is the guest console, which *is* a byte pipe in both directions (see
/// `GuestConsole`), because a terminal has to be a tty to behave like one.
@MainActor
protocol LinuxEmulator: AnyObject {
    var name: String { get }
    var isRunning: Bool { get }
    /// Boot the guest; returns once commands can be run.
    func boot() async throws
    /// Import the bundled root filesystem into the engine's on-disk format
    /// ahead of first use, without booting the guest. Idempotent: a root that
    /// is already installed is left untouched.
    func prepareRootfs() async throws
    /// Run one command headlessly in the guest.
    func runCommand(
        _ command: String,
        shell: String?,
        timeout: TimeInterval,
        maxOutput: Int
    ) async throws -> GuestCommandResult

    /// Start the guest's own init as pid 1, giving it the console as its stdio.
    /// This is what boots the guest as a *system*: init reads /etc/inittab, which
    /// puts a root shell on the console. Safe to call once per boot.
    func startInit(_ program: String) async throws

    /// Attach to the guest console, delivering its output as the guest produces
    /// it. Returns the host end, which is what the terminal types into.
    func openConsole(onOutput: @Sendable @escaping (String) -> Void) async throws -> any GuestConsole

    /// Start a command and return immediately, without waiting for it to exit.
    ///
    /// `stdinPath` is a *guest* path the child reads its stdin from (NULL for
    /// `/dev/null`). A detached command redirects its own stdout/stderr, so the
    /// caller supplies a complete command line.
    ///
    /// Returns a handle for waiting on and signalling the process.
    func startDetached(
        _ command: String,
        shell: String?,
        stdinPath: String?
    ) async throws -> DetachedProcess

    func shutdown() async
}

/// A guest process started with `startDetached`.
///
/// It is deliberately thin: the engine reports no exit *status* for a process
/// nobody waits on, so a detached command communicates its result through
/// whatever its command line redirects to. This handle answers the two questions
/// the host actually needs — is it still running, and how do I stop it.
/// Not `@MainActor`: the handle itself is thread-agnostic and does its own
/// hopping onto the guest thread, so callers may hold and use it from anywhere.
/// `Sendable` is what carries that guarantee.
protocol DetachedProcess: AnyObject, Sendable {
    /// Guest pid, for logging and for `kill`.
    var pid: Int32 { get }
    /// Whether it is still running.
    ///
    /// `async`, because answering it means asking the guest — every engine call
    /// has to hop onto the one thread the engine allows, so this cannot be a
    /// synchronous property even though it reads like one.
    var isRunning: Bool { get async }
    /// Send a real guest signal. `SIGINT` (2) interrupts the foreground program,
    /// `SIGTERM` (15) asks it to stop, `SIGKILL` (9) cannot be caught.
    func signal(_ number: Int32) async
    /// Wait for exit, up to `timeout` seconds (0 waits indefinitely).
    /// Returns true if it exited.
    @discardableResult
    func waitForExit(timeout: TimeInterval) async -> Bool
}

