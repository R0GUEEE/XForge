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
    /// The write end of the input FIFO, held open for the session's life.
    ///
    /// Opening and closing per write would be wrong twice over: each close is an
    /// EOF the shell would act on, and reopening a FIFO blocks until a reader
    /// appears. One handle, opened once, is what makes the input a continuous
    /// stream rather than a series of complete (and therefore terminating) files.
    private var inputHandle: FileHandle?

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
        // Start reading the output file only now: before this point the shell has
        // not been told to write to it, so there is nothing to miss.
        tailer.start()

        // Open the write end and keep it. The shell is already blocked reading the
        // FIFO, so this does not block, and holding it open is what stops the
        // shell seeing an end-of-input after every command.
        inputHandle = FileHandle(forWritingAtPath: inputURL.path)

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
        guard let inputHandle else { return false }
        do {
            // Written to the held-open FIFO. A FIFO has no offset, so there is
            // nothing to seek and no risk of the guest's read position drifting
            // away from ours.
            try inputHandle.write(contentsOf: data)
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
        // Closing the write end is what tells the shell its input has ended, so it
        // is part of stopping rather than an afterthought.
        try? inputHandle?.close()
        inputHandle = nil
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
