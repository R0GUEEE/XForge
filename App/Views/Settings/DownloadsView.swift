import SwiftUI

/// Guest-backed provisioning controls.
///
/// The app never downloads build tooling into a host-side cache: every component
/// is installed by a command inside the embedded Alpine filesystem, and those
/// commands run in the Terminal tab so their output is visible. This screen
/// shows what is present and hands the command over.
struct DownloadsView: View {
    @EnvironmentObject private var terminal: TerminalSession
    @StateObject private var toolchain = ToolchainManager()

    var body: some View {
        List {
            Section {
                LinuxProvisioningRow(
                    component: .swift,
                    installed: toolchain.isInstalled(.swift),
                    isBusy: toolchain.isInstalling != nil
                ) {
                    install(SystemComponents.swiftInstallCommand, "Swift toolchain")
                }

                LinuxProvisioningRow(
                    component: .xtool,
                    installed: toolchain.isInstalled(.xtool),
                    isBusy: toolchain.isInstalling != nil
                ) {
                    install(SystemComponents.xtoolInstallCommand, "xtool")
                }

                LinuxProvisioningRow(
                    component: .sdk,
                    installed: toolchain.isInstalled(.sdk),
                    isBusy: toolchain.isInstalling != nil
                ) {
                    installPrebuiltSDK()
                }
            } header: {
                Text("Alpine Toolchain")
            } footer: {
                Text("Each install is an ordinary Linux command run inside the "
                     + "embedded Alpine filesystem, shown in the Terminal tab.")
            }

            if let message = toolchain.message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("The Alpine terminal is the Terminal tab, where these installs "
                     + "run: use it to inspect them with swift --version, "
                     + "xtool --version and swift sdk list.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Linux Toolchain")
        .task {
            await toolchain.refresh(probeGuest: true)
        }
    }

    /// Boot the guest, make sure the provisioning script is in it, and hand the
    /// command to the shared terminal.
    private func install(_ command: String, _ what: String) {
        Task {
            do {
                let vm = XForgeEnvironment.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                try await SystemComponents.ensureInstallerScript(in: vm)
                terminal.enqueue(command, label: "Settings")
                toolchain.message = "\(what): running in the Terminal tab."
            } catch {
                toolchain.message = error.localizedDescription
            }
        }
    }

    private func installPrebuiltSDK() {
        Task {
            do {
                let url = try await XForgeReleases.darwinSDKURL()
                let vm = XForgeEnvironment.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                // The command runs the guest's script first, to remove the SDK the
                // rootfs already carries: same preparation as the other installs.
                try await SystemComponents.ensureInstallerScript(in: vm)
                terminal.enqueue(SystemComponents.darwinSDKDownloadCommand(from: url),
                                 label: "Settings")
                toolchain.message = "Darwin SDK: downloading and installing in the Terminal tab."
            } catch {
                toolchain.message = error.localizedDescription
            }
        }
    }
}

private struct LinuxProvisioningRow: View {
    let component: ToolchainManager.Component
    let installed: Bool
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

            if !installed {
                Button("Install", action: install)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            }
        }
    }
}
