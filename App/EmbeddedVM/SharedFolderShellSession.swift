import Foundation

/// The concrete `InteractiveShellSession`: a shell running in the guest, started
/// *detached* so it does not occupy the engine's one guest thread, reading its
/// stdin from a file the host appends to and writing its output to a file the
/// host tails.
///
/// Both ends live in the shared folder (`realfs`), so each direction is ordinary
/// file I/O — the same trick the terminal's output transport has always used, now
/// with the other direction as well.
@MainActor
final class SharedFolderShellSession: InteractiveShellSession {
    private let inputURL: URL
    private let outputURL: URL
    private let tailer: FileTailer
    private var process: (any DetachedProcess)?

    let guestInput: String
    let guestOutput: String
    private(set) var isRunning = false
    private(set) var pid: Int32 = 0

    init(inputURL: URL, outputURL: URL, guestInput: String, guestOutput: String,
         onOutput: @escaping @Sendable (String) -> Void) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.guestInput = guestInput
        self.guestOutput = guestOutput
        self.tailer = FileTailer(url: outputURL, onChunk: onOutput)
    }

    /// Hand the session the process it is driving. Called once, right after the
    /// guest shell has been started.
    func attach(process: any DetachedProcess, onExit: @escaping @MainActor () -> Void) {
        self.process = process
        self.pid = process.pid
        self.isRunning = true
        // Output is safe to tail immediately; the guest opens the output path as
        // soon as its detached command starts.
        tailer.start()

        // A regular host file is appended to per write. Inside the guest, `tail -f`
        // is the long-lived writer-facing bridge that feeds those appends into the
        // shell's stdin stream.

        // Watch for the shell ending by itself (`exit`, or a crash). Polling the
        // guest process is the only way to learn this — there is no host-side
        // waitpid for a detached pid, and blocking the engine's one thread on a
        // wait is exactly what detaching avoids.
        Task { [weak self] in
            while await process.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.isRunning else { return }
            self.markStopped()
            onExit()
        }
    }

    /// Mark the session dead after the guest shell exits on its own.
    func markStopped() {
        isRunning = false
        tailer.stop()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard isRunning else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        do {
            let handle = try FileHandle(forWritingTo: inputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// A third of Ctrl-C, which is worth stating plainly: sending the `0x03`
    /// *character* only interrupts a program whose stdin is a **tty**, because
    /// the tty driver is what turns it into a signal. This transport is a pipe
    /// from a regular file, so the byte would be read as ordinary input. The
    /// signal is delivered directly instead, which reaches the process whatever
    /// its stdin is.
    func interruptForeground() async {
        guard let process else { return }
        await process.signal(Self.sigint)
    }

    func sendControl(_ scalar: UInt8) -> Bool {
        guard let text = String(bytes: [scalar], encoding: .utf8) else { return false }
        return send(text)
    }

    func stop() {
        isRunning = false
        tailer.stop()
        process = nil
        // Stop the guest shell too, or it outlives the screen that was driving it.
        if let process {
            Task { [process] in
                await process.signal(Self.sigterm)
                // If it ignores SIGTERM, insist. SIGKILL cannot be caught.
                if await process.waitForExit(timeout: 2) == false {
                    await process.signal(Self.sigkill)
                }
            }
        }
        process = nil
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    private static let sigint: Int32 = 2
    private static let sigterm: Int32 = 15
    private static let sigkill: Int32 = 9
}
