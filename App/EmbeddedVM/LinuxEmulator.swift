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

/// An in-process Linux execution engine.
///
/// iOS cannot spawn subprocesses, so the embedded Linux runs as a **library**
/// inside the app. XForge uses iSH-AOK (github.com/emkey1/ish-AOK): a real Linux
/// kernel + userspace emulator whose "gadget JIT" runs the aarch64 guest without
/// needing a JIT entitlement, so it works in a sideloaded app.
///
/// The engine's primitive is "run this command line, give me its merged output
/// and exit status" — iSH-AOK's `run_guest_command_capture_shell` — not a byte
/// pipe. Conformers boot a guest and then execute commands through that.
@MainActor
protocol LinuxEmulator: AnyObject {
    var name: String { get }
    var isRunning: Bool { get }
    /// Boot the guest; returns once commands can be run.
    func boot() async throws
    /// Run one command headlessly in the guest.
    func runCommand(
        _ command: String,
        shell: String?,
        timeout: TimeInterval,
        maxOutput: Int
    ) async throws -> GuestCommandResult
    func shutdown() async
}

/// Fallback used if the iSH-AOK core is not linked into the app. Keeps the UI
/// honest with a clear, actionable error instead of silently doing nothing.
@MainActor
final class PendingLinuxEmulator: LinuxEmulator {
    let name = "none"
    var isRunning = false
    func boot() async throws {
        throw LinuxVMError.notImplemented(
            "The embedded iSH-AOK Linux core is not linked into this build. " +
            "Rebuild with `make ish-core` (see EmbeddedLinux/build-ish-aok-core.sh)."
        )
    }
    func runCommand(
        _ command: String,
        shell: String?,
        timeout: TimeInterval,
        maxOutput: Int
    ) async throws -> GuestCommandResult {
        throw LinuxVMError.notImplemented("No guest is running.")
    }
    func shutdown() async {}
}
