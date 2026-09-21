import Foundation
import SwiftUI
import UIKit

/// The app's one terminal into the embedded Alpine Linux.
///
/// This is a real shell session, with one architectural caveat that everything
/// here is built around: XForge's engine bridge runs *one command at a time* and
/// hands back its output, so there is no live pty to type into. The session
/// therefore keeps the shell's state on the host side:
///
///  - the working directory survives `cd` between commands (the guest reports
///    where each command ended);
///  - output is streamed as the guest writes it, through a screen model that
///    understands carriage returns, backspaces and SGR colour (`TerminalBuffer`);
///  - the transcript and history are persisted, so reopening the terminal shows
///    the previous session;
///  - other screens (Toolchain, Build) hand commands to the *same* session, so
///    what they install is visible here while it runs.
@MainActor
final class TerminalSession: ObservableObject {
    /// The screen model. Views render `buffer.lines` and re-render when
    /// `revision` changes.
    let buffer = TerminalBuffer()

    /// Bumped whenever the screen changes.
    @Published private(set) var revision = 0
    @Published private(set) var running = false
    @Published private(set) var booting = false
    @Published var input = ""
    @Published private(set) var cwd = "/root"
    @Published private(set) var history: [String] = []
    @Published private(set) var lastExit: Int32?
    /// Queue of commands handed over by other screens, oldest first.
    @Published private(set) var pending: [TerminalCommand] = []
    /// Title of the command that is running, when it was not typed here.
    @Published private(set) var activeLabel: String?
    /// True once the guest has been booted successfully in this session.
    @Published private(set) var isBooted = false
    @Published private(set) var problem: String?

    /// Marker the guest prints after each command so the host can recover `$PWD`.
    private static let marker = "__XFORGE_PWD__"

    /// A command queued for the terminal, optionally with the label of the
    /// screen that asked for it.
    struct TerminalCommand: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var label: String?
    }

    private var historyIndex: Int?
    private var didAttemptBoot = false
    private var holdback = ""
    private var markerSeen = false
    private var generation = 0

    init() {
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

    var prompt: String { cwd == "/root" ? "$" : "\(cwd) $" }

    /// Whether anything can be typed right now.
    var acceptsInput: Bool { !booting }

    // MARK: - Boot

    /// Boot the guest, importing the bundled rootfs if needed. Safe to call from
    /// several screens; only the first call does work.
    func boot() async {
        guard !didAttemptBoot else { return }
        didAttemptBoot = true
        booting = true
        problem = nil
        buffer.appendLine("[booting the embedded Linux — \(EmbeddedLinuxVM.launchCommand)]",
                          style: TerminalStyle(foreground: .index(8)))
        revision += 1

        do {
            let vm = XForgeEnvironment.makeVM()
            await vm.prepareRootfs()
            try await vm.boot()
            isBooted = true
            buffer.appendLine("[guest is up — Alpine aarch64 Linux]",
                              style: TerminalStyle(foreground: .index(2)))
        } catch {
            problem = error.localizedDescription
            buffer.appendLine("[error] \(error.localizedDescription)",
                              style: TerminalStyle(foreground: .index(1)))
        }
        booting = false
        revision += 1
        save()
        startNextIfIdle()
    }

    // MARK: - Running

    /// Run whatever has been typed.
    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        input = ""
        historyIndex = nil
        history.append(command)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        save()
        enqueue(TerminalCommand(text: command, label: nil))
    }

    /// Hand a command to the terminal from another screen. It runs as soon as
    /// the current one finishes; the terminal shows who asked for it.
    func enqueue(_ command: TerminalCommand) {
        pending.append(command)
        startNextIfIdle()
    }

    func enqueue(_ command: String, label: String? = nil) {
        enqueue(TerminalCommand(text: command, label: label))
    }

    private func startNextIfIdle() {
        guard !running, !booting, !pending.isEmpty else { return }
        if !didAttemptBoot {
            // The terminal has not booted yet: boot first, then the queue drains.
            Task { await boot() }
            return
        }
        guard isBooted else {
            // Booting failed earlier. Keep the queue, and report why on screen.
            buffer.appendLine("[waiting] the guest is not running; \(pending.count) command(s) queued",
                              style: TerminalStyle(foreground: .index(3)))
            revision += 1
            return
        }
        let next = pending.removeFirst()
        run(next)
    }

    private func run(_ command: TerminalCommand) {
        running = true
        activeLabel = command.label
        markerSeen = false
        holdback = ""
        let currentGeneration = generation

        let promptLine = "\(prompt) \(command.text)"
        // A command handed over by another screen is echoed with a note saying so,
        // because the user did not type it and needs to know where it came from.
        if let label = command.label, !label.isEmpty {
            buffer.appendLine(promptLine, style: TerminalStyle(foreground: .index(14)))
            buffer.appendLine("  ↑ requested by \(label)",
                              style: TerminalStyle(foreground: .index(8)))
        } else {
            buffer.appendLine(promptLine, style: TerminalStyle(foreground: .index(10)))
        }
        revision += 1

        Task { [weak self] in
            guard let self else { return }
            // Hold the app awake while the guest works, for the whole task
            // including its early exit when the command is detached.
            let keepAwake = InstallAssertion.begin(reason: "terminal command")
            defer { keepAwake.end() }
            var status: Int32 = -1
            do {
                let vm = XForgeEnvironment.makeVM()
                status = try await vm.runLoginStreaming(
                    self.script(for: command.text),
                    environment: nil
                ) { [weak self] chunk in
                    Task { @MainActor in self?.consume(chunk, generation: currentGeneration) }
                }
            } catch {
                if currentGeneration == self.generation {
                    self.flushHoldback()
                    self.buffer.appendLine("[error] \(error.localizedDescription)",
                                           style: TerminalStyle(foreground: .index(1)))
                }
            }

            // Let the last streamed chunks reach the main actor before the
            // marker is stripped from the screen.
            try? await Task.sleep(for: .milliseconds(150))
            guard currentGeneration == self.generation else { return }
            self.finishStreaming()
            self.lastExit = status
            if status != 0 {
                self.buffer.appendLine("[exit \(status)]",
                                       style: TerminalStyle(foreground: .index(9)))
            }
            self.revision += 1
            self.running = false
            self.activeLabel = nil
            self.save()
            self.startNextIfIdle()
        }
    }

    /// Stop watching the running command.
    ///
    /// The guest command itself is not signalled — the engine's command
    /// primitive has no way to deliver a signal to a running child — so this
    /// detaches the screen and lets the command finish on its own. `running`
    /// goes false so the next command can be typed meanwhile.
    func interrupt() {
        guard running else { return }
        generation += 1
        detachRunningCommand()
        buffer.appendLine("^C",
                          style: TerminalStyle(foreground: .index(9)))
        buffer.appendLine("[stopped watching; the command keeps running in the guest]",
                          style: TerminalStyle(foreground: .index(8)))
        revision += 1
    }

    private func detachRunningCommand() {
        running = false
        activeLabel = nil
        holdback = ""
        save()
    }

    // MARK: - Output handling

    private func consume(_ chunk: String, generation currentGeneration: Int) {
        guard currentGeneration == generation else { return }
        // Anything after the marker is the directory report itself, not output.
        guard !markerSeen else { return }
        holdback += chunk

        if let range = holdback.range(of: Self.marker) {
            // Everything before the marker is the command's real output; what
            // follows it on the same line is the directory it ended in.
            buffer.feed(String(holdback[..<range.lowerBound]))
            let rest = String(holdback[range.upperBound...])
            let directory = rest
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if directory.hasPrefix("/") { cwd = directory }
            holdback = ""
            markerSeen = true
        } else {
            // Keep the tail that could be the start of a marker from reaching the
            // screen, so a marker split across two chunks is still stripped.
            let keep = Self.marker.count
            guard holdback.count > keep else { return }
            let cut = holdback.index(holdback.endIndex, offsetBy: -keep)
            buffer.feed(String(holdback[..<cut]))
            holdback = String(holdback[cut...])
        }
        revision += 1
    }

    private func finishStreaming() {
        if !markerSeen { flushHoldback() }
        if buffer.current.isEmpty {
            // The command printed a trailing newline of its own; nothing to add.
        }
    }

    private func flushHoldback() {
        guard !holdback.isEmpty else { return }
        buffer.feed(holdback)
        holdback = ""
        revision += 1
    }

    /// The script fed to the login shell: replay `cd`, run the command, report
    /// the directory it ended in, and preserve the command's exit status.
    private func script(for command: String) -> String {
        """
        cd \(GuestShell.quote(cwd)) 2>/dev/null
        \(command)
        __xf_rc=$?
        printf '\\n\(Self.marker)%s\\n' "$PWD"
        exit $__xf_rc
        """
    }

    // MARK: - Editing

    func recall(offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = max(0, min(history.count, current + offset))
        historyIndex = next == history.count ? nil : next
        input = historyIndex.map { history[$0] } ?? ""
    }

    /// Insert text from the key bar at the end of the input line.
    func insert(_ text: String) {
        input += text
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // A pasted multi-line command should run as typed, not be squashed onto
        // one line, so keep its newlines.
        input += text
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
        buffer.appendLine("Commands run one at a time; output streams here live.",
                          style: TerminalStyle(foreground: .index(8)))
        buffer.appendLine("Try: uname -a · cat /etc/alpine-release · ls /root · apk --version",
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
