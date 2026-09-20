import SwiftUI

/// A shell into the embedded Alpine aarch64 Linux.
///
/// iSH-AOK's headless command API buffers output until a command exits. For an
/// interactive terminal that is a poor user experience, so commands mirror
/// stdout/stderr into the host-shared /host/.xforge-transfer directory while
/// they run. Swift polls that file and renders new bytes immediately.
@MainActor
struct TerminalView: View {
    @State private var output = ""
    @State private var input = ""
    @State private var running = false
    @State private var booting = false
    @State private var cwd = "/root"
    @State private var history: [String] = []
    @State private var historyIndex: Int?

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
                Text(prompt)
                    .foregroundStyle(.green)
                    .font(.system(.body, design: .monospaced))
                TextField(booting ? "booting Alpine…" : "command", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.go)
                    .onSubmit { run() }
                    .disabled(running || booting)
                if running || booting {
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
                .disabled(history.isEmpty || running || booting)

                Button { recall(offset: 1) } label: {
                    Label("Next command", systemImage: "chevron.down")
                }
                .disabled(history.isEmpty || running || booting)

                Button { output = "" } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .disabled(output.isEmpty)
            }
        }
        .onAppear(perform: loadHistory)
        .task { await bootAndDescribeGuest() }
    }

    private var prompt: String {
        cwd == "/root" ? "root@xforge:~#" : "root@xforge:\(cwd)#"
    }

    private static let banner = """
    XForge terminal
    Preparing the embedded Alpine rootfs…

    """

    /// Boot on entry so this screen is guaranteed to address the imported
    /// Alpine fakefs, not merely advertise that a guest exists.
    private func bootAndDescribeGuest() async {
        guard output.isEmpty, !booting else { return }
        booting = true
        output = "[xforge] booting embedded Alpine aarch64 rootfs…\n"
        let vm = XForgeEnvironment.makeVM()

        do {
            let wasBooted = vm.isBooted
            try await vm.boot()
            output += wasBooted
                ? "[xforge] guest already running; attached to existing rootfs\n"
                : "[xforge] rootfs mounted and guest booted\n"

            let collector = OutputBuffer()
            let probe = """
            printf '--- guest identity ---\\n'
            printf 'release: '; cat /etc/alpine-release 2>/dev/null || echo unknown
            printf 'kernel:  '; uname -a
            printf 'arch:    '; uname -m
            printf 'shell:   '; printf '%s\\n' "$0"
            printf 'pwd:     '; pwd
            printf 'rootfs:  '; mount 2>/dev/null | head -1 || true
            printf 'host:    '; test -d /host && echo mounted || echo missing
            printf 'dns:     '; tr '\\n' ' ' </etc/resolv.conf 2>/dev/null || true
            printf '\\n----------------------\\n'
            """
            let status = try await vm.run(probe, environment: nil) { collector.append($0) }
            output += collector.value
            if !output.hasSuffix("\n") { output += "\n" }
            output += "[xforge] Alpine terminal ready (probe exit \(status))\n\n"
        } catch {
            output += "[xforge] boot failed: \(error.localizedDescription)\n"
            output += "[xforge] verify the bundled Alpine archive and Engine log.\n"
        }

        booting = false
    }

    private func recall(offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = max(0, min(history.count, current + offset))
        historyIndex = next == history.count ? nil : next
        input = historyIndex.map { history[$0] } ?? ""
    }

    private func run() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running, !booting else { return }

        input = ""
        historyIndex = nil
        history.append(command)
        saveHistory()
        running = true
        output += "\(prompt) \(command)\n"

        Task {
            let vm = XForgeEnvironment.makeVM()
            let id = UUID().uuidString
            let transfer = XForgeEnvironment.hostShareDirectory
                .appendingPathComponent(".xforge-transfer", isDirectory: true)
            let liveURL = transfer.appendingPathComponent("terminal-\(id).log")
            let pwdURL = transfer.appendingPathComponent("terminal-\(id).pwd")
            let guestLive = "/host/.xforge-transfer/terminal-\(id).log"
            let guestPWD = "/host/.xforge-transfer/terminal-\(id).pwd"

            do {
                try FileManager.default.createDirectory(
                    at: transfer, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: liveURL)
                try? FileManager.default.removeItem(at: pwdURL)

                XForgeLog.note("terminal: cwd=\(cwd) command=\(command)")
                output += "[xforge] exec in Alpine; live stdout/stderr follows\n"

                let poller = Task { @MainActor in
                    await streamFile(liveURL)
                }

                // Redirection goes directly to realfs (/host), so Swift can read
                // output while run_guest_command_capture_shell is still blocked.
                // The command's exit status is preserved by the final exit.
                let wrapped = """
                cd \(shellQuoted(cwd)) 2>/dev/null || cd /root
                {
                    \(command)
                    __xf_rc=$?
                    pwd > \(shellQuoted(guestPWD))
                    exit "$__xf_rc"
                } > \(shellQuoted(guestLive)) 2>&1
                """
                let status = try await vm.run(wrapped, environment: nil) { _ in }

                poller.cancel()
                await poller.value

                if let newDirectory = try? String(contentsOf: pwdURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !newDirectory.isEmpty {
                    cwd = newDirectory
                }

                if !output.hasSuffix("\n") { output += "\n" }
                output += "[exit \(status)]\n"
            } catch {
                output += "[error] \(error.localizedDescription)\n"
            }

            try? FileManager.default.removeItem(at: liveURL)
            try? FileManager.default.removeItem(at: pwdURL)
            running = false
        }
    }

    /// Append newly-written bytes until cancelled, then perform one final drain.
    private func streamFile(_ url: URL) async {
        var consumed = 0

        func drain() {
            guard let data = try? Data(contentsOf: url), data.count > consumed else { return }
            let chunk = data.subdata(in: consumed..<data.count)
            consumed = data.count
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                output += text
            }
        }

        while !Task.isCancelled {
            drain()
            try? await Task.sleep(for: .milliseconds(150))
        }
        drain()
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

/// Thread-safe accumulator for the short boot probe.
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
