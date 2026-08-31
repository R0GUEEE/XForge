import Foundation

/// Concrete `LinuxVM` backed by an embedded Linux binary that we bundle.
///
/// THIS IS THE LONG POLE OF THE PROJECT. The embedded Linux must contain a
/// Swift aarch64 Linux toolchain + the `darwin` Swift SDK + xtool. Building that
/// userspace is the work in `EmbeddedLinux/`; this type is the thin host-side
/// bridge that boots it and talks to it.
///
/// Two bridging options are being evaluated (see Docs/DESIGN.md):
///   1. Reuse an iSH-AOK arm64 guest binary, driving it over a pty.
///   2. A purpose-built, stripped userspace launched as a subprocess, talking
///      over stdin/stdout with a simple line protocol.
///
/// This file is a working skeleton: the boot/run plumbing below compiles and is
/// the shape the real implementation will take. Replace `// IMPLEMENT:` with the
/// actual subprocess/pty launch once `EmbeddedLinux/` lands.
final class EmbeddedLinuxVM: LinuxVM {
    let root: URL
    private(set) var isBooted = false

    init(root: URL) {
        self.root = root
    }

    func boot() async throws {
        guard !isBooted else { return }
        // IMPLEMENT: locate the embedded Linux binary under `root`, launch it,
        // wait for a shell-ready prompt, set isBooted = true.
        throw LinuxVMError.notImplemented(
            "Embedded Linux userspace not built yet. See EmbeddedLinux/ and Docs/DESIGN.md."
        )
    }

    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @escaping (String) -> Void
    ) async throws -> Int32 {
        // IMPLEMENT: write command to guest stdin, stream stdout to onOutput,
        // return guest exit code.
        throw LinuxVMError.notImplemented("VM run() not implemented yet.")
    }

    func copyOut(guestPath: String, to hostURL: URL) async throws {
        throw LinuxVMError.notImplemented("VM copyOut() not implemented yet.")
    }

    func copyIn(hostURL: URL, to guestPath: String) async throws {
        throw LinuxVMError.notImplemented("VM copyIn() not implemented yet.")
    }
}

enum LinuxVMError: LocalizedError {
    case notImplemented(String)
    var errorDescription: String? {
        switch self {
        case .notImplemented(let msg): return msg
        }
    }
}
