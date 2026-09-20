import SwiftUI

/// A real shell into the embedded Alpine aarch64 Linux.
///
/// The engine's primitive is "run this command line, give me its output when it
/// finishes", so this view keeps the shell's *state* on the host side:
///
///  - the working directory survives `cd` between commands (each command runs as
///    `cd <cwd>; <command>; pwd`, and the new directory is read back);
///  - command history is kept, recalled with ↑/↓ (or the arrow buttons) and
///    persisted across launches;
///  - the scrollback is never thrown away except by Clear.
@MainActor
struct TerminalView: View {
    @State private var output = ""
    @State private var input = ""
    @State private var running = false
    @State private var cwd = "/root"
    @State private var history: [String] = []
    @State private var historyIndex: Int?

    private static let marker = "__XFORGE_PWD__"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? Self.banner : output)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("bottom")
                }
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: output) { _ in
                    withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .ignoresSafeArea(.container, edges: [.bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(prompt).foregroundStyle(.green).font(.system(.body, design: .monospaced))
                TextField("command", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.go)
                    .onSubmit { run() }
                    .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Button { run() } label: {
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
                Button { recall(offset: -1) } label: {
                    Label("Previous command", systemImage: "chevron.up")
                }
                .disabled(history.isEmpty || running)

                Button { recall(offset: 1) } label: {
                    Label("Next command", systemImage: "chevron.down")
                }
                .disabled(history.isEmpty || running)

                Button { output = "" } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .disabled(output.isEmpty)
            }
        }
        .onAppear(perform: loadHistory)
    }

    private var prompt: String {
        cwd == "/root" ? "$" : "\(cwd) $"
    }

    private static let banner = """
    XForge terminal — commands run in the embedded Alpine aarch64 Linux.
    The tools XForge installs live in its rootfs, so `swift --version` and
    `xtool --version` work here. `sh /root/install-toolchain.sh` (re)installs them.

    Try: uname -a · cat /etc/alpine-release · ls /host · swift --version

    """

    private func recall(offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = max(0, min(history.count, current + offset))
        historyIndex = next == history.count ? nil : next
        input = historyIndex.map { history[$0] } ?? ""
    }

    private func run() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running else { return }
        input = ""
        historyIndex = nil
        history.append(command)
        saveHistory()
        running = true
        output += "\(prompt) \(command)\n"

        Task {
            let buffer = OutputBuffer()
            do {
                let vm = XForgeEnvironment.makeVM()
                if !vm.isBooted {
                    output += "[booting the embedded Linux — the first boot imports the rootfs…]\n"
                }
                // Carry the working directory across commands: the engine starts a
                // fresh shell per command, so `cd` has to be replayed, and the
                // directory it ends in read back off a marker.
                let wrapped = "cd \(shellQuoted(cwd)) 2>/dev/null; \(command)\n"
                    + "printf '\\n\(Self.marker)%s' \"$PWD\""
                XForgeLog.note("terminal: \(command)")
                let status = try await vm.run(wrapped, environment: nil) { chunk in
                    buffer.append(chunk)
                }
                var text = buffer.value
                if let range = text.range(of: Self.marker) {
                    let newDirectory = text[range.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newDirectory.isEmpty { cwd = newDirectory }
                    text = String(text[..<range.lowerBound])
                }
                if !text.isEmpty {
                    output += text.hasSuffix("\n") ? text : text + "\n"
                }
                output += "[exit \(status)]\n"
            } catch {
                output += "[error] \(error.localizedDescription)\n"
            }
            running = false
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - History

    private var historyURL: URL {
        XForgeEnvironment.documentDirectory.appendingPathComponent("terminal-history.txt")
    }

    private func loadHistory() {
        guard history.isEmpty,
              let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        history = text.split(separator: "\n").map(String.init).suffix(200).map { $0 }
    }

    private func saveHistory() {
        let text = history.suffix(200).joined(separator: "\n")
        try? text.write(to: historyURL, atomically: true, encoding: .utf8)
    }
}

/// Thread-safe accumulator for output delivered from the VM's `@Sendable` callback.
private final class OutputBuffer: @unchecked Sendable {
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
