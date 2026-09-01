import Foundation

/// An in-process Linux execution engine.
///
/// iOS cannot spawn subprocesses, so an embedded Linux runs as a **library** inside
/// the app (QEMU- or iSH-based), exposing a guest shell over a byte pipe. Conformers
/// boot a Linux userspace and give us stdin/stdout access. This is the seam between
/// XForge and any embedded emulator; it is the same shape as tctiSH's libqemu embed.
@MainActor
protocol LinuxEmulator: AnyObject {
    var name: String { get }
    var isRunning: Bool { get }
    /// Boot the guest; returns once a shell is ready to accept commands.
    func boot() async throws
    /// Write bytes to the guest's stdin.
    func write(_ data: Data) async throws
    /// Read available bytes from the guest's stdout. Throws when the guest exits.
    func read() async throws -> Data
    func shutdown() async
}

/// The default emulator when none is bundled yet. It boots with a clear, actionable
/// error pointing at the artifact that must be produced (see build-emulator.yml).
@MainActor
final class PendingLinuxEmulator: LinuxEmulator {
    let name = "none"
    var isRunning = false
    func boot() async throws {
        throw LinuxVMError.notImplemented(
            "No embedded Linux emulator is bundled yet. Produce `libqemu` / a Linux binary " +
            "via .github/workflows/build-emulator.yml (or download it from the releases), " +
            "and place it under Documents/embedded-linux/, then retry."
        )
    }
    func write(_ data: Data) async throws { throw LinuxVMError.notImplemented("No emulator running") }
    func read() async throws -> Data { throw LinuxVMError.notImplemented("No emulator running") }
    func shutdown() async {}
}

/// The concrete emulator that will wrap an embedded QEMU-style library.
/// `boot()` looks for a prebuilt emulator artifact (downloaded or bundled); once the
/// library is linked this type drives it via a small C shim (mirroring tctiSH).
@MainActor
final class EmbeddedQemuLinux: LinuxEmulator {
    let name = "QEMU (embedded)"
    private(set) var isRunning = false
    let rootfs: URL

    init(rootfs: URL) {
        self.rootfs = rootfs
    }

    func boot() async throws {
        // IMPLEMENT: dlopen/preload the embedded libqemu (built by build-emulator.yml),
        // boot the Alpine aarch64 guest at `rootfs`, set isRunning = true.
        guard bundledEmulatorExists() else {
            throw LinuxVMError.notImplemented(
                "Embedded QEMU library not present. Run build-emulator.yml (or download the " +
                "release asset) so libqemu lands in the app, then retry."
            )
        }
        throw LinuxVMError.notImplemented("QEMU shim not yet linked (see build-emulator.yml).")
    }

    func write(_ data: Data) async throws {
        throw LinuxVMError.notImplemented("QEMU guest I/O not yet wired.")
    }

    func read() async throws -> Data {
        throw LinuxVMError.notImplemented("QEMU guest I/O not yet wired.")
    }

    func shutdown() async {}

    private func bundledEmulatorExists() -> Bool {
        let candidates = [
            rootfs.appendingPathComponent("usr/bin/linux"),
            rootfs.appendingPathComponent("libqemu.dylib"),
            rootfs.appendingPathComponent("qemu-system-aarch64"),
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
