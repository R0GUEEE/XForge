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
/// provides the command/file bridge to it. The engine's primitive is one-shot
/// command capture, so `run` executes a command and forwards its merged output
/// to `onOutput`.
@MainActor
final class EmbeddedLinuxVM: LinuxVM {
    let root: URL
    private let emulator: LinuxEmulator
    private(set) var isBooted = false

    /// No timeout: builds run in the foreground and may legitimately take minutes.
    private static let noTimeout: TimeInterval = 0
    /// Generous capture cap for build logs (bytes).
    private static let outputCap = 8 * 1024 * 1024

    init(root: URL, emulator: LinuxEmulator) {
        self.root = root
        self.emulator = emulator
    }

    func boot() async throws {
        guard !isBooted else { return }
        try await emulator.boot()
        isBooted = emulator.isRunning
    }

    /// Run a command in the guest, forwarding its output, and return its exit code.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        try await boot()

        let env = environment.map { pairs in
            pairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + " "
        } ?? ""

        let result = try await emulator.runCommand(
            env + command,
            shell: nil,
            timeout: Self.noTimeout,
            maxOutput: Self.outputCap
        )
        if !result.output.isEmpty {
            onOutput(result.output)
        }
        return result.status
    }

    /// Copy a file out of the guest into a host URL (base64 over the shell).
    func copyOut(guestPath: String, to hostURL: URL) async throws {
        let box = OutputBox()
        let code = try await run(
            "base64 -w0 '\(guestPath)' 2>/dev/null || echo __XF_COPY_ERR__",
            environment: nil
        ) { box.append($0) }

        let trimmed = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !trimmed.contains("__XF_COPY_ERR__"),
              let data = Data(base64Encoded: trimmed) else {
            throw LinuxVMError.fileCopyFailed
        }
        try data.write(to: hostURL)
    }

    /// Copy a host file into the guest (base64 over the shell).
    func copyIn(hostURL: URL, to guestPath: String) async throws {
        let data = try Data(contentsOf: hostURL)
        let b64 = data.base64EncodedString()
        let dir = (guestPath as NSString).deletingLastPathComponent
        _ = try await run(
            "mkdir -p '\(dir)' && base64 -d > '\(guestPath)' <<'__XF_B64__'\n\(b64)\n__XF_B64__\n",
            environment: nil
        ) { _ in }
    }
}

enum LinuxVMError: LocalizedError {
    case notImplemented(String)
    case fileCopyFailed
    var errorDescription: String? {
        switch self {
        case .notImplemented(let m): return m
        case .fileCopyFailed: return "Could not copy the file to/from the embedded Linux."
        }
    }
}
