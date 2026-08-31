import Foundation

/// Interface to the embedded Linux VM. The concrete implementation boots a
/// bundled iSH-style userspace and gives us a shell to run commands in plus
/// access to the guest filesystem (read/write files, stage artifacts).
@MainActor
protocol LinuxVM: AnyObject {
    /// Boot the embedded Linux (blocking until a shell is ready).
    func boot() async throws
    /// Run a command in the guest, streaming stdout lines.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32
    /// Read a file out of the guest filesystem into a host URL.
    func copyOut(guestPath: String, to hostURL: URL) async throws
    /// Stage a host file into the guest filesystem.
    func copyIn(hostURL: URL, to guestPath: String) async throws
    var isBooted: Bool { get }
}
