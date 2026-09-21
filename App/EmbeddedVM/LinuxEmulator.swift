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
/// inside the app. XForge uses ish-arm64 (github.com/OpenMinis/ish-arm64): a real Linux
/// kernel + userspace emulator whose threaded-code interpreter dispatches aarch64
/// guest instructions to pre-compiled functions ("gadgets"). It emits no machine
/// code and needs no executable memory, so no JIT entitlement is required and it
/// works in a sideloaded app.
///
/// The engine's primitive is "run this command line, give me its merged output
/// and exit status" — the engine's guest command runner — not a byte
/// pipe. Conformers boot a guest and then execute commands through that.
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
    func shutdown() async
}

/// Fallback used if the ish-arm64 core is not linked into the app. Keeps the UI
/// honest with a clear, actionable error instead of silently doing nothing.
@MainActor
final class PendingLinuxEmulator: LinuxEmulator {
    let name = "none"
    var isRunning = false
    func boot() async throws {
        throw LinuxVMError.notImplemented(
            "The embedded ish-arm64 Linux core is not linked into this build. " +
            "Rebuild with `make ish-core` (see EmbeddedLinux/build-ish-aok-core.sh)."
        )
    }
    func prepareRootfs() async throws {
        // No engine is linked; the boot path reports the real problem.
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
