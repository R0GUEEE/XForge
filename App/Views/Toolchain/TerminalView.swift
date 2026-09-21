import SwiftUI

/// A real shell into the embedded Alpine aarch64 Linux.
///
/// The engine's primitive is "run this command line, give me its output when it
/// finishes", so the shell's *state* is kept on the host side, augmented with a
/// live transcript:
///
///  - the guest is booted as soon as the screen appears, and the bundled Alpine
///    rootfs is imported first if needed;
///  - commands run through XForge's default Alpine launch command `/bin/sh`;
///  - output is streamed live (the guest writes into the shared folder, which the
///    host tails) instead of arriving only when the command finishes;
///  - the working directory survives `cd` between commands;
///  - the transcript and command history are persisted, so reopening the terminal
///    shows the previous session instead of a blank one.
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var running = false
    @Published private(set) var booting = false
    @Published var input = ""
    @Published private(set) var cwd = "/root"
    @Published private(set) var history: [String] = []

    /// Marker the guest's login shell appends so the host can recover `$PWD`.
    private static let marker = "__XFORGE_PWD__"
    /// XForge's default headless Alpine launch command.
    static let launchCommand = EmbeddedLinuxVM.launchCommand

    private var historyIndex: Int?
    private var didBoot = false

    init() {
        transcript = Self.read(Self.transcriptURL) ?? ""
        history = Self.read(Self.historyURL)?
            .split(separator: "\n").map(String.init).suffix(200).map { $0 } ?? []
    }

    var prompt: String { cwd == "/root" ? "$" : "\(cwd) $" }

    // MARK: - Boot

    /// Boot the guest and import the bundled rootfs if needed. Runs once per
    /// screen; later calls are no-ops.
    func boot() async {
        guard !didBoot, !booting else { return }
        booting = true
        append("\n[booting the embedded Linux — shell \(Self.launchCommand)]\n")
        do {
            let vm = XForgeEnvironment.makeVM()
            // Best effort: `boot()` imports the rootfs if this has not.
            await vm.prepareRootfs()
            try await vm.boot()
            didBoot = true
            append("[guest is up; Alpine is ready for commands]\n")
        } catch {
            didBoot = false
            append("[error] \(error.localizedDescription)\n")
            append("[open this screen again to retry Linux startup]\n")
        }
        booting = false
        save()
    }

    // MARK: - Run

    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running, !booting else { return }
        input = ""
        historyIndex = nil
        history.append(command)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        save()

        append("\(prompt) \(command)\n")
        running = true
        let start = transcript.count

        Task { [weak self] in
            guard let self else { return }
            do {
                let vm = XForgeEnvironment.makeVM()
                let status = try await vm.runLoginStreaming(self.script(for: command),
                                                            environment: nil) { [weak self] chunk in
                    Task { @MainActor in self?.append(chunk) }
                }
                // Let the final streamed chunks reach the main actor before the
                // marker is stripped.
                try? await Task.sleep(for: .milliseconds(150))
                self.finish(from: start)
                self.append("[exit \(status)]\n")
            } catch {
                self.append("[error] \(error.localizedDescription)\n")
            }
            self.running = false
            self.save()
        }
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

    /// Recover the new working directory from the marker and drop the marker
    /// from the transcript.
    private func finish(from start: Int) {
        let anchor = transcript.index(transcript.startIndex,
                                      offsetBy: min(start, transcript.count))
        guard let range = transcript.range(of: Self.marker,
                                           range: anchor..<transcript.endIndex) else { return }
        let newDirectory = transcript[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !newDirectory.isEmpty { cwd = newDirectory }
        transcript = String(transcript[..<range.lowerBound])
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
        transcript = ""
        save()
    }

    func append(_ text: String) {
        transcript += text
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
        // Cap the saved transcript so the file cannot grow without bound.
        try? String(transcript.suffix(200_000))
            .write(to: Self.transcriptURL, atomically: true, encoding: .utf8)
        try? history.suffix(200).joined(separator: "\n")
            .write(to: Self.historyURL, atomically: true, encoding: .utf8)
    }
}

struct TerminalView: View {
    @StateObject private var session = TerminalSession()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.transcript.isEmpty ? Self.banner : session.transcript)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("bottom")
                }
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: session.transcript) { _ in
                    withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .ignoresSafeArea(.container, edges: [.bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(session.prompt).foregroundStyle(.green).font(.system(.body, design: .monospaced))
                TextField("command", text: $session.input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.go)
                    .onSubmit { session.submit() }
                    .disabled(session.running || session.booting)
                if session.running || session.booting {
                    ProgressView().controlSize(.small)
                } else {
                    Button { session.submit() } label: {
                        Label("Run", systemImage: "return")
                    }
                }
            }
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.recall(offset: -1) } label: {
                    Label("Previous command", systemImage: "chevron.up")
                }
                .disabled(session.history.isEmpty || session.running)

                Button { session.recall(offset: 1) } label: {
                    Label("Next command", systemImage: "chevron.down")
                }
                .disabled(session.history.isEmpty || session.running)

                Button { session.clear() } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .disabled(session.transcript.isEmpty)
            }
        }
        .task { await session.boot() }
    }

    private static let banner = """
    XForge terminal — commands run in the embedded Alpine aarch64 Linux.
    Commands run with XForge's /bin/sh launch command and stream output here live.
    This starts with the bundled provisioned Alpine rootfs. Its build dependencies,
    Swift, and xtool are already installed in this terminal's guest filesystem.

    Try: uname -a · cat /etc/alpine-release · ls /host · apk --version

    """
}
