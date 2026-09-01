import SwiftUI

/// Manage the on-device build infrastructure. Each component shows its status and an
/// install action when missing. The Darwin SDK installs on-device; the embedded Linux
/// and Swift install once the VM bridge is connected.
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
                Text("A shell into the embedded Alpine aarch64 Linux. Appears once the VM bridge is connected.")
            }

            Section("Components") {
                ForEach(ToolchainManager.Component.allCases) { component in
                    HStack {
                        Image(systemName: component.icon)
                            .foregroundStyle(toolchain.isInstalled(component) ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(component.rawValue).font(.headline)
                            Text(detail(for: component))
                                .font(.caption).foregroundStyle(.secondary)
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
                        } else {
                            Label("Installed", systemImage: "checkmark")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }

            if let message = toolchain.message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section(footer: Text("The embedded Linux, Swift toolchain and Darwin SDK are fetched on first use. This can take several minutes and requires several gigabytes of storage.")) {
                Button(role: .destructive) {
                    toolchain.message = "Reset removes the downloaded toolchain. (Not yet implemented.)"
                } label: {
                    Label("Reset Toolchain", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Toolchain")
        .task { toolchain.refresh() }
    }

    private func detail(for component: ToolchainManager.Component) -> String {
        switch component {
        case .linux: return "Alpine aarch64 userspace"
        case .swift: return "Swift Linux toolchain (via gcompat)"
        case .xtool: return "xtool aarch64 binary"
        case .sdk: return "arm64-apple-ios · fetched on demand"
        }
    }
}
