import Foundation
import SwiftUI
import UIKit

/// The app's one terminal into the embedded Alpine Linux.
///
/// This is the guest's own console: `/sbin/init` owns it, and it respawns
/// `/sbin/xforge-login root` on it, so the shell you type into is a real login
/// session with a real tty — the login shell root is configured with in
/// `/etc/passwd`. See `InteractiveShellSession` for what that buys.
///
/// Consequences of it being a real console, which are the point of the change:
///  - the working directory is the shell's own, so `cd` persists;
///  - the *guest's* line discipline supplies echo, backspace, `Ctrl-D` and
///    editing — the host does not synthesise any of it;
///  - `Ctrl-C` is a byte again, so the tty turns it into `SIGINT` for whatever is
///    running in the foreground, and `Ctrl-Z` suspends it;
///  - logging out (or killing the shell) gives a fresh login, because init
///    respawns it rather than leaving a dead screen.
@MainActor
final class TerminalSession: ObservableObject {
    /// The screen model. Views render `buffer.lines` and re-render when
    /// `revision` changes.
    let buffer = TerminalBuffer()

    /// Bumped whenever the screen changes.
    @Published private(set) var revision = 0
    /// True while the guest console is attached and input is being forwarded to it.
    @Published private(set) var running = false
    @Published private(set) var booting = false
    @Published private(set) var cwd = "/root"
    /// Commands handed over by other screens, run through the same console.
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
                    }
                )
                self.shell = session
                self.isBooted = true
                self.running = true
                self.buffer.appendLine("[guest is up — Alpine aarch64 Linux]",
                                       style: TerminalStyle(foreground: .index(2)))
                // The console's size is the screen's, but layout may have run
                // before the shell existed.
                self.reportSize()
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

    /// Stop the shell. The console belongs to the guest's init, which keeps
    /// running; this only stops this screen from reading and writing to it.
    func shutdown() {
        shell?.stop()
        shell = nil
        running = false
        revision += 1
    }

    // MARK: - Screen size

    /// The size the terminal is drawn at, in characters. The guest needs it or its
    /// programs wrap to nothing — `ls` prints one name per line at width 0.
    private var screenCols = 0
    private var screenRows = 0

    /// Called by the terminal surface whenever its geometry changes.
    func consoleResized(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != screenCols || rows != screenRows else { return }
        screenCols = cols
        screenRows = rows
        shell?.resize(cols: cols, rows: rows)
    }

    private func reportSize() {
        guard screenCols > 0, screenRows > 0 else { return }
        shell?.resize(cols: screenCols, rows: screenRows)
    }

    // MARK: - Input

    /// Send raw keyboard/terminal input straight to the console.
    ///
    /// Nothing is interpreted here: the console is a tty, so the guest's line
    /// discipline and the shell's own line editor are what echo, erase, complete
    /// and recall. That is why there is no command field and no host-side prompt.
    func sendRaw(_ text: String) {
        guard !text.isEmpty else { return }
        sendToShell(text, label: nil)
    }

    /// Hand a line to the console from another screen. It is written like anything
    /// else, so it runs in the same session — with the same environment, the same
    /// directory, and after whatever is already queued.
    ///
    /// Booting this session is part of the job. A screen that queues a command
    /// boots the *guest* first, and that is not the same as this console being
    /// attached to it: only the Terminal tab called `boot()`. So a command queued
    /// before the Terminal tab had ever been opened — which is every install from
    /// the Toolchain, Downloads and Settings screens on a fresh launch, since
    /// SwiftUI does not build an unselected tab — was reported as undeliverable to
    /// a buffer nobody was looking at, while the screen that queued it said it was
    /// running in the Terminal.
    func enqueue(_ line: String, label: String? = nil) {
        enqueue(QueuedLine(text: line, label: label))
    }

    func enqueue(_ line: QueuedLine) {
        pending.append(line)
        guard shell?.isRunning != true else {
            drainQueue()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.boot()
            // If the boot failed the queue is still drained, which reports the
            // line as undelivered — the honest outcome, and the reason the drop
            // path stays.
            self.drainQueue()
        }
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

    /// Interrupt the foreground program with Ctrl-C.
    ///
    /// The byte, not a host-side `kill`: the console is a real tty, so the guest's
    /// line discipline turns `0x03` into `SIGINT` for the foreground process group
    /// — which reaches whatever is running, and leaves the shell itself alone.
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

    // MARK: - Screen

    func clear() {
        buffer.clear()
        banner()
        revision += 1
        save()
    }

    private func banner() {
        buffer.appendLine("XForge terminal — the guest's own console.",
                          style: TerminalStyle(foreground: .index(11)))
        buffer.appendLine("Alpine boots /sbin/init as pid 1, which starts root's login shell on this",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("terminal — the shell /etc/passwd names for root. Ctrl-C interrupts the",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("foreground program; `exit` ends the session and init starts a fresh one.",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("")
        revision += 1
    }

    // MARK: - Persistence

    private static var transcriptURL: URL {
        XForgeEnvironment.documentDirectory.appendingPathComponent("terminal-transcript.txt")
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func save() {
        try? String(buffer.plainText.suffix(200_000))
            .write(to: Self.transcriptURL, atomically: true, encoding: .utf8)
    }
}
