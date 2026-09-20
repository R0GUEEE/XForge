import SwiftUI

/// Guest-backed provisioning controls.
///
/// The app never downloads build tooling into a host-side cache. Each action below
/// delegates to `ToolchainManager`, which runs the downloader and installer in the
/// embedded Alpine filesystem.
struct DownloadsView: View {
    @StateObject private var toolchain = ToolchainManager()

    var body: some View {
        List {
            Section {
                LinuxProvisioningRow(
                    component: .swift,
                    installed: toolchain.isInstalled(.swift),
                    isInstalling: toolchain.isInstalling == .swift,
                    isBusy: toolchain.isInstalling != nil
                ) {
                    Task { await toolchain.install(.swift) }
                }

                LinuxProvisioningRow(
                    component: .xtool,
                    installed: toolchain.isInstalled(.xtool),
                    isInstalling: toolchain.isInstalling == .xtool,
                    isBusy: toolchain.isInstalling != nil
                ) {
                    Task { await toolchain.install(.xtool) }
                }

                LinuxProvisioningRow(
                    component: .sdk,
                    installed: toolchain.isInstalled(.sdk),
                    isInstalling: toolchain.isInstalling == .sdk,
                    isBusy: toolchain.isInstalling != nil
                ) {
                    Task { await toolchain.install(.sdk) }
                }
            } header: {
                Text("Alpine Toolchain")
            } footer: {
                Text("Swift, xtool, and the Darwin SDK are downloaded, unpacked, and installed inside the embedded Alpine filesystem. The iOS app only displays progress.")
            }

            if let progressLabel = toolchain.progressLabel {
                Section("Guest Activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: toolchain.progress)
                            .progressViewStyle(.linear)
                        Text(progressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = toolchain.message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    TerminalView()
                } label: {
                    Label("Open Alpine Terminal", systemImage: "terminal")
                }
            } footer: {
                Text("Use the terminal to inspect the installed tools with swift --version, xtool --version, and swift sdk list.")
            }
        }
        .navigationTitle("Linux Toolchain")
        .task {
            await toolchain.refresh(probeGuest: true)
        }
    }
}

private struct LinuxProvisioningRow: View {
    let component: ToolchainManager.Component
    let installed: Bool
    let isInstalling: Bool
    let isBusy: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: component.icon)
                .foregroundStyle(installed ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(component.rawValue)
                Text(component.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if installed {
                    Label("Installed in Alpine", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if !installed {
                Button("Install", action: install)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            }
        }
    }
}
