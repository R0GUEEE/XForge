import SwiftUI

/// Manage the on-device build infrastructure: embedded Linux, Swift toolchain,
/// xtool, and the `darwin` Swift SDK.
struct ToolchainView: View {
    @State private var status = ToolchainStatus()
    @State private var isRefreshing = false
    @State private var isInstallingSDK = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Embedded Linux") {
                statusRow(title: "Linux userspace",
                          detail: status.embeddedLinuxInstalled ? "Installed" : "Not installed",
                          ok: status.embeddedLinuxInstalled)
            }

            Section("Swift Toolchain") {
                statusRow(title: "Swift",
                          detail: status.swiftVersion ?? "Not detected",
                          ok: status.swiftVersion != nil)
                statusRow(title: "xtool",
                          detail: status.xtoolVersion ?? "Not detected",
                          ok: status.xtoolVersion != nil)
            }

            Section("Darwin Swift SDK") {
                statusRow(title: "SDK",
                          detail: status.sdkInstalled ? (status.sdkVersion ?? "Installed") : "Not installed",
                          ok: status.sdkInstalled)

                if !status.sdkInstalled {
                    Button {
                        Task { await installSDK() }
                    } label: {
                        Label(isInstallingSDK ? "Installing…" : "Download & Install SDK",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(isInstallingSDK)
                }
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(isRefreshing ? "Checking…" : "Check Toolchain", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)

                if let message {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section(footer: Text("The embedded Linux, Swift toolchain and darwin SDK are fetched on first use. This can take several minutes and requires several gigabytes of storage.")) {
                Button(role: .destructive) {
                    message = "Reset removes the downloaded toolchain. (Not yet implemented.)"
                } label: {
                    Label("Reset Toolchain", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Toolchain")
        .task { await refresh() }
    }

    private func statusRow(title: String, detail: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // TODO: probe the embedded VM for swift/xtool/SDK versions.
        message = "Toolchain check will query the embedded Linux once the VM bridge is wired."
    }

    private func installSDK() async {
        isInstallingSDK = true
        defer { isInstallingSDK = false }
        message = "SDK install streams from the hosted darwin-SDK release into the embedded Linux."
        // TODO: kick off SDK download + `swift sdk install` in the VM.
    }
}
