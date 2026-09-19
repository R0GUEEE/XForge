import Foundation

/// `LinuxEmulator` backed by the embedded iSH-AOK engine.
///
/// iSH-AOK runs a real Linux guest in-process (its aarch64 "gadget JIT" needs no
/// JIT entitlement, so it works in a sideloaded app). The root filesystem is the
/// Alpine aarch64 minirootfs bundled in the app; on first boot it is imported
/// into iSH-AOK's `fakefs` format, then mounted as `/`.
///
/// Threading: iSH-AOK keeps its current guest task in a thread-local, so boot and
/// every command run serialized on one dedicated queue.
@MainActor
final class ISHAOKEmulator: LinuxEmulator {
    let name = "iSH-AOK (arm64 guest)"
    private(set) var isRunning = false

    private let rootsDirectory: URL
    private let guestQueue = DispatchQueue(label: "org.xforge.ish.guest", qos: .userInitiated)

    init(rootsDirectory: URL) {
        self.rootsDirectory = rootsDirectory
    }

    func boot() async throws {
        guard !isRunning else { return }
        let roots = rootsDirectory
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guestQueue.async {
                do {
                    // Import the bundled Alpine rootfs into fakefs the first
                    // time; subsequent launches reuse it.
                    let root = try RootfsInstaller.installIfNeeded(into: roots)
                    let rc = root.path.withCString { xf_ish_boot($0) }
                    guard rc == 0 else {
                        throw LinuxVMError.notImplemented(ishLastError(fallback: "Could not boot the guest (errno \(rc))."))
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isRunning = true
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
            guestQueue.async {
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

    func shutdown() async {
        guard isRunning else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guestQueue.async {
                xf_ish_shutdown()
                continuation.resume()
            }
        }
        isRunning = false
    }
}

/// Reads the bridge's thread-local last error. Must be called on the guest queue.
private func ishLastError(fallback: String) -> String {
    let message = String(cString: xf_ish_last_error())
    return message.isEmpty ? fallback : message
}
