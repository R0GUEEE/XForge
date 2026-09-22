import Foundation

enum GuestShell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func environment(_ values: [String: String]?) -> String {
        guard let values else { return "" }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(quote($0.value))" }
            .joined(separator: " ") + " "
    }
}

/// Interface to the embedded Linux VM. The concrete implementation boots a
/// bundled iSH-style userspace and gives us a shell to run commands in plus
/// access to the guest filesystem (read/write files, stage artifacts).
@MainActor
protocol LinuxVM: AnyObject {
    /// Boot the embedded Linux (blocking until a shell is ready).
    func boot() async throws
    /// Install the bundled rootfs ahead of first use, so the first build does
    /// not pay for the import. Best effort; a no-op once it is installed.
    func prepareRootfs() async
    /// Run a command through the guest's interactive login terminal, streaming output.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32
    /// Run a shell script through the terminal's login launch command
    /// (`/bin/sh`), delivering output as the guest writes it.
    func runLoginStreaming(
        _ script: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32
    /// Read a file out of the guest filesystem into a host URL.
    func copyOut(guestPath: String, to hostURL: URL) async throws
    /// Stage a host file into the guest filesystem.
    func copyIn(hostURL: URL, to guestPath: String) async throws
    /// Attach the screen to the guest's console shell: the session `/sbin/init`
    /// respawns there. Output is delivered as the guest writes it.
    func startInteractiveShell(
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> any InteractiveShellSession
    var isBooted: Bool { get }
}

extension LinuxVM {
    /// Default for VMs with no shared folder to tail: fall back to the one-shot
    /// capture, which delivers the output when the command finishes.
    func runLoginStreaming(
        _ script: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await run(script, environment: environment, onOutput: onOutput)
    }
}
