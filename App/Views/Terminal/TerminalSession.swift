import Foundation
import SwiftUI
import UIKit

/// The app's one terminal into the embedded Alpine Linux.
///
/// This is a real shell session: a **persistent** shell in the guest whose stdin
/// the host writes to and whose output the host reads as it is produced. See
/// `InteractiveShellSession` for the transport and what it does and does not
/// provide.
///
/// Consequences of it being a real shell, which are the point of the change:
///  - the working directory is the shell's own, so `cd` persists and there is no
///    replaying of `cd` before each command;
///  - a program that reads stdin — `read`, `cat`, `sort`, a REPL, a prompt for
///    input — receives what you type at the moment it asks;
///  - the prompt shown is the shell's, printed by the shell, not one the host
///    synthesises.
///
/// Signals are the exception. The engine cannot deliver a signal to a running
/// child, so an interrupt detaches the screen instead of stopping the guest, and
/// the session says exactly that rather than pretending otherwise.
@MainActor
final class TerminalSession: ObservableObject {
    /// The screen model. Views render `buffer.lines` and re-render when
    /// `revision` changes.
    let buffer = TerminalBuffer()

    /// Bumped whenever the screen changes.
    @Published private(set) var revision = 0
    /// True while the guest shell is up and input is being forwarded to it.
    @Published private(set) var running = false
    @Published private(set) var booting = false
    /// The line being composed locally, before it is handed to the shell.
    ///
    /// Typed text is echoed here first so the caret follows what you type even
    /// before the shell has seen the line; on submit it is written to the shell's
    /// stdin and the shell echoes it back with its own editing.
    @Published var input = ""
    @Published private(set) var cwd = "/root"
    @Published private(set) var history: [String] = []
    /// Commands handed over by other screens, run through the same shell.
    @Published private(set) var pending: [QueuedLine] = []
    @Published private(set) var activeLabel: String?
    @Published private(set) var isBooted = false
    @Published private(set) var problem: String?

    /// A line queued for the shell, optionally with the label of the screen that
    /// asked for it.
    struct QueuedLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var label: String?
    }

    private var shell: (any InteractiveShellSession)?
    private var historyIndex: Int?
    private var bootTask: Task<Void, Never>?
    private var didAttemptBoot = false

    /// How the session obtains a guest. Injectable so the terminal's logic can be
    /// tested against a stub instead of a real emulator.
    private let makeVM: @MainActor () -> any LinuxVM

    init(makeVM: @escaping @MainActor () -> any LinuxVM = { XForgeEnvironment.makeVM() }) {
        self.makeVM = makeVM
        let saved = Self.read(Self.transcriptURL)
        if let saved, !saved.isEmpty {
            if !saved.hasSuffix("\n") { buffer.feed(saved + "\n") }
            else { buffer.feed(saved) }
        }
        history = Self.read(Self.historyURL)?
            .split(separator: "\n")
            .map(String.init)
            .suffix(200)
            .map { $0 } ?? []
        if buffer.isAtStart { banner() }
    }

    /// Whether the exit key bar should send to a live shell.
    var acceptsInput: Bool { !booting && shell?.isRunning == true }

    // MARK: - Boot

    /// Start the shell, booting the guest first. Safe to call from several
    /// screens; only the first call does work.
    func boot() async {
        guard !didAttemptBoot else {
            await bootTask?.value
            return
        }
        didAttemptBoot = true
        booting = true
        problem = nil
        buffer.appendLine("[starting the embedded Linux…]",
                          style: TerminalStyle(foreground: .index(8)))
        revision += 1

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let vm = self.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                let session = try await vm.startInteractiveShell(
                    onOutput: { [weak self] chunk in
                        Task { @MainActor in self?.consume(chunk) }
                    },
                    onExit: { [weak self] in
                        Task { @MainActor in self?.shellExited() }
                    }
                )
                self.shell = session
                self.isBooted = true
                self.running = true
                self.buffer.appendLine("[guest is up — Alpine aarch64 Linux]",
                                       style: TerminalStyle(foreground: .index(2)))
            } catch {
                self.problem = error.localizedDescription
                self.buffer.appendLine("[error] \(error.localizedDescription)",
                                       style: TerminalStyle(foreground: .index(1)))
            }
            self.booting = false
            self.revision += 1
            self.save()
            self.drainQueue()
        }
        bootTask = task
        await task.value
    }

    /// The guest shell ended on its own — `exit`, or it died. Say so, rather
    /// than leaving a live-looking prompt that silently swallows input.
    private func shellExited() {
        guard running else { return }
        running = false
        shell = nil
        buffer.appendLine("", style: TerminalStyle())
        buffer.appendLine("[the shell exited — reopen the tab to start a new one]",
                          style: TerminalStyle(foreground: .index(3)))
        revision += 1
        save()
    }

    /// Stop the shell. The guest's shell exits when its stdin sees EOF, which
    /// happens when the app tears the transport down.
    func shutdown() {
        shell?.stop()
        shell = nil
        running = false
        revision += 1
    }

    // MARK: - Input

    /// Send the composed line to the shell.
    func submit() {
        let line = input
        input = ""
        historyIndex = nil
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            history.append(line)
            if history.count > 200 { history.removeFirst(history.count - 200) }
            save()
        }
        sendToShell(line + "\n", label: nil)
    }

    /// Hand a line to the shell from another screen. It is written to the shell's
    /// stdin like anything else, so it runs in the same session — with the same
    /// environment, the same directory, and after whatever is already queued.
    func enqueue(_ line: String, label: String? = nil) {
        pending.append(QueuedLine(text: line, label: label))
        drainQueue()
    }

    func enqueue(_ line: QueuedLine) {
        pending.append(line)
        drainQueue()
    }

    private func drainQueue() {
        guard !pending.isEmpty else { return }
        guard running, shell?.isRunning == true else {
            // No shell to write to. Take the line out of the queue and report it,
            // rather than leaving it pending forever and looking like it will run:
            // a command that silently never executes is the worst of the options.
            let dropped = pending.removeFirst()
            sendToShell(dropped.text, label: dropped.label)
            return
        }
        let next = pending.removeFirst()
        // A command from another screen is announced, because the user did not
        // type it and needs to know where it came from. The echo of the command
        // itself comes from the shell.
        if let label = next.label, !label.isEmpty {
            buffer.appendLine("↑ requested by \(label)",
                              style: TerminalStyle(foreground: .index(8)))
            revision += 1
        }
        sendToShell(next.text + "\n", label: next.label)
    }

    private func sendToShell(_ text: String, label: String?) {
        guard let shell, shell.isRunning else {
            // Nothing to write to. Report it rather than dropping the line, since
            // a queued install that silently never runs is worse than an error.
            buffer.appendLine("[error] the shell is not running; \(text.count) character(s) not sent",
                              style: TerminalStyle(foreground: .index(1)))
            revision += 1
            return
        }
        activeLabel = label
        if !shell.send(text) {
            buffer.appendLine("[error] the guest did not accept input",
                              style: TerminalStyle(foreground: .index(1)))
            revision += 1
        }
    }

    /// Type text at the current position: it goes into the local line, and is
    /// sent with the newline so the shell renders it in context.
    func insert(_ text: String) {
        input += text
    }

    /// Interrupt the foreground program with a real `SIGINT`.
    ///
    /// Not a Ctrl-C byte on stdin: that only becomes a signal when the program's
    /// stdin is a tty, and this session's stdin is a pipe from a file, so the
    /// byte would be read as ordinary input. The signal is delivered directly,
    /// which reaches the program whatever it is doing.
    func interrupt() {
        guard let shell, shell.isRunning else { return }
        Task { [weak self] in
            await shell.interruptForeground()
            self?.activeLabel = nil
            self?.revision += 1
        }
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // Hand it straight to the shell: it may be multi-line, or contain control
        // characters the key bar cannot produce.
        sendToShell(text, label: nil)
    }

    // MARK: - Output

    private func consume(_ chunk: String) {
        // Straight to the screen: the shell prints its own prompt, echoes what it
        // reads, and emits its own escape sequences — and the buffer understands
        // carriage returns, backspaces and SGR colour, so there is nothing to
        // interpret here.
        buffer.feed(chunk)
        revision += 1
    }

    // MARK: - Editing

    func recall(offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = max(0, min(history.count, current + offset))
        historyIndex = next == history.count ? nil : next
        input = historyIndex.map { history[$0] } ?? ""
    }

    func clear() {
        buffer.clear()
        banner()
        revision += 1
        save()
    }

    func clearInput() {
        input = ""
    }

    private func banner() {
        buffer.appendLine("XForge terminal — a shell into the embedded Alpine aarch64 Linux.",
                          style: TerminalStyle(foreground: .index(11)))
        buffer.appendLine("Type at the prompt. The shell is persistent, and programs that read",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("stdin receive what you type. Ctrl-C interrupts the foreground program.",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("")
        revision += 1
    }

    // MARK: - Persistence

    private static var transcriptURL: URL {
        XForgeEnvironment.documentDirectory.appendingPathComponent("terminal-transcript.txt")
    }

    private static var historyURL: URL {
        XForgeEnvironment.documentDirectory.appendingPathComponent("terminal-history.txt")
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func save() {
        try? String(buffer.plainText.suffix(200_000))
            .write(to: Self.transcriptURL, atomically: true, encoding: .utf8)
        try? history.suffix(200).joined(separator: "\n")
            .write(to: Self.historyURL, atomically: true, encoding: .utf8)
    }
}
