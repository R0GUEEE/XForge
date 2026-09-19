import SwiftUI

/// A real shell into the embedded Alpine aarch64 Linux.
///
/// Commands run in the iSH-AOK guest over the VM bridge and their merged
/// stdout/stderr is shown here.
@MainActor
struct TerminalView: View {
    @State private var output = ""
    @State private var input = ""
    @State private var running = false

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
                Text("$").foregroundStyle(.green).font(.system(.body, design: .monospaced))
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
            ToolbarItem(placement: .primaryAction) {
                Button { output = "" } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .disabled(output.isEmpty)
            }
        }
    }

    private static let banner = """
    XForge terminal — commands run in the embedded Alpine aarch64 Linux.
    The first command boots the guest (it imports the bundled rootfs).

    Try: uname -a · cat /etc/alpine-release · swift --version

    """

    private func run() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running else { return }
        input = ""
        running = true
        output += "xforge@alpine:~$ \(command)\n"

        Task {
            let buffer = OutputBuffer()
            do {
                let vm = XForgeEnvironment.makeVM()
                if !vm.isBooted {
                    output += "[booting the embedded Linux — the first boot imports the rootfs…]\n"
                }
                let status = try await vm.run(command, environment: nil) { chunk in
                    buffer.append(chunk)
                }
                let text = buffer.value
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
