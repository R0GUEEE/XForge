import Foundation

/// Concrete `LinuxVM` that drives an in-process `LinuxEmulator` (QEMU/iSH-style
/// library) over a byte pipe. Since iOS cannot spawn subprocesses, the emulator runs
/// inside the app and this type provides the command/file bridge to its guest shell.
@MainActor
final class EmbeddedLinuxVM: LinuxVM {
    let root: URL
    private let emulator: LinuxEmulator
    private(set) var isBooted = false

    /// Sentinel we echo after each command so the host can capture the guest exit code.
    private static let exitSentinel = "__XF_EXIT__"

    init(root: URL, emulator: LinuxEmulator) {
        self.root = root
        self.emulator = emulator
    }

    func boot() async throws {
        guard !isBooted else { return }
        try await emulator.boot()
        isBooted = emulator.isRunning
    }

    /// Run a command in the guest, streaming stdout lines, and return its exit code.
    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await boot()

        let env = environment.map { pairs in
            pairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + " "
        } ?? ""
        // Echo a sentinel carrying $? so we can parse the real exit code.
        let full = "\(env)\(command)\nprintf '\\n\(Self.exitSentinel)%d\\n' $?\n"
        try await emulator.write(Data(full.utf8))

        var accumulated = ""
        var exitCode: Int32 = -1
        while true {
            let chunk = try await emulator.read()
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            accumulated += text

            if let range = accumulated.range(of: Self.exitSentinel) {
                let suffix = accumulated[range.upperBound...]
                let digits = suffix.prefix { $0.isNumber }
                exitCode = Int32(digits) ?? -1
                let beforeSentinel = String(accumulated[..<range.lowerBound])
                emit(beforeSentinel, to: onOutput)
                return exitCode
            }
            emit(accumulated, to: onOutput)
            accumulated = lastPartialLine(accumulated)
        }
    }

    /// Copy a file out of the guest into a host URL (base64 over the shell).
    func copyOut(guestPath: String, to hostURL: URL) async throws {
        var encoded = ""
        let code = try await run(
            "base64 -w0 '\(guestPath)' 2>/dev/null || echo __XF_COPY_ERR__",
            environment: nil
        ) { encoded += $0 }
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - helpers

    private func emit(_ text: String, to onOutput: @escaping (String) -> Void) {
        guard !text.isEmpty else { return }
        onOutput(text)
    }

    private func lastPartialLine(_ text: String) -> String {
        guard let newline = text.lastIndex(of: "\n") else { return text }
        let after = text.index(after: newline)
        return String(text[after...])
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
