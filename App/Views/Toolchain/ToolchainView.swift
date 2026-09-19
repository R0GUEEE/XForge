import SwiftUI

/// Manage the on-device build infrastructure.
///
/// The Alpine rootfs is bundled in the app (installing it is a local import, no
/// network); the Swift toolchain, xtool and the darwin SDK live inside the guest
/// Linux and are provisioned over the VM bridge.
struct ToolchainView: View {
    @StateObject private var toolchain = ToolchainManager()

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    TerminalView()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                        .font(.headline)
                }
            } header: {
                Text("Interactive Shell")
            } footer: {
                Text("A real shell into the embedded Alpine aarch64 Linux.")
            }

            Section {
                ForEach(ToolchainManager.Component.allCases) { component in
                    row(component)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Green = present. Guest components (Swift, xtool, the SDK) are "
                     + "verified inside the embedded Linux — tap Check to probe it.")
            }

            Section {
                Button {
                    Task { await toolchain.refresh(probeGuest: true) }
                } label: {
                    Label("Check the embedded Linux", systemImage: "arrow.clockwise")
                }
                .disabled(toolchain.isInstalling != nil || toolchain.activity != nil)
            }

            if let message = toolchain.message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section(footer: Text("Reset removes the imported rootfs, the staged darwin SDK "
                                 + "and any downloads. The app re-imports the bundled rootfs "
                                 + "on the next boot.")) {
                Button(role: .destructive) {
                    Task { await toolchain.reset() }
                } label: {
                    Label("Reset Toolchain", systemImage: "trash")
                }
                .disabled(toolchain.isInstalling != nil)
            }

            Section(footer: Text("If something dies without an explanation, share the log: "
                                 + "the engine's own messages and XForge's install "
                                 + "breadcrumbs are both in it.")) {
                NavigationLink {
                    EngineLogView()
                } label: {
                    Label("Engine log", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .navigationTitle("Toolchain")
        .task { await toolchain.refresh() }
    }

    private func row(_ component: ToolchainManager.Component) -> some View {
        HStack(alignment: .top) {
            Image(systemName: component.icon)
                .foregroundStyle(toolchain.isInstalled(component) ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.rawValue).font(.headline)
                Text(component.blurb).font(.caption).foregroundStyle(.secondary)
                if toolchain.isInstalled(component) {
                    Label("Installed", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.green)
                } else if component.livesInGuest && !toolchain.guestChecked {
                    Text("Not checked").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not installed").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !toolchain.isInstalled(component) {
                Button {
                    Task { await toolchain.install(component) }
                } label: {
                    if toolchain.isInstalling == component {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(toolchain.isInstalling != nil)
            }
        }
    }
}
