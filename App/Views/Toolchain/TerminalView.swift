import SwiftUI

/// A full-screen terminal into the embedded Linux. Until the VM bridge is
/// implemented, it echoes commands and shows the backend status; the input
/// line is wired to `runInGuest` (forwarded to the VM) as soon as the bridge lands.
struct TerminalView: View {
    @State private var output = ""
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty
                        ? "xforge@alpine:~$  (embedded Linux not connected yet)\n"
                        : output)
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
                Button { run() } label: {
                    Label("Run", systemImage: "return")
                }
            }
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        output += "xforge@alpine:~$ \(trimmed)\n"
        output += "The embedded Linux terminal is not connected yet.\n"
        output += "It will be available once the Alpine aarch64 VM bridge is wired.\n"
    }
}
