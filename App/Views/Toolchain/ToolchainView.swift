import SwiftUI
import UniformTypeIdentifiers

/// Manage the on-device build infrastructure.
///
/// The Alpine rootfs is bundled in the app (installing it is a local import, no
/// network); the Swift toolchain, xtool and the darwin SDK live inside the guest
/// Linux and are provisioned by `EmbeddedLinux/install-toolchain.sh`, which the
/// same screen also runs by hand — it is copied to `/root/install-toolchain.sh`,
/// so the Terminal can drive it too.
struct ToolchainView: View {
    @StateObject private var toolchain = ToolchainManager()
    @State private var importingXcode = false

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
                Text("A real shell into the embedded Alpine aarch64 Linux. The tools "
                     + "installed here are in its rootfs, so `swift --version` and "
                     + "`xtool --version` work there.")
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

                Button {
                    importingXcode = true
                } label: {
                    Label("Install the Darwin SDK from an Xcode.xip…",
                          systemImage: "doc.badge.plus")
                }
                .disabled(toolchain.isInstalling != nil)
            } footer: {
                Text("The Darwin SDK is normally downloaded prebuilt (214 MB). Building "
                     + "it from your own Xcode.xip runs `xtool sdk build` inside the guest "
                     + "instead — it needs xtool and Swift there, and room for the "
                     + "extracted Xcode.")
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
        .fileImporter(
            isPresented: $importingXcode,
            allowedContentTypes: [UTType(filenameExtension: "xip") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await toolchain.installSDKFromXcode(xip: url) }
        }
    }

    private func row(_ component: ToolchainManager.Component) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: component.icon)
                    .foregroundStyle(toolchain.isInstalled(component) ? .green : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.rawValue).font(.headline)
                    Text(component.blurb).font(.caption).foregroundStyle(.secondary)
                    statusLine(component)
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

            // The bar for whichever component is installing right now, under the
            // row it belongs to, with what it is doing at that moment.
            if toolchain.isInstalling == component, let label = toolchain.progressLabel {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: toolchain.progress)
                        .progressViewStyle(.linear)
                    HStack(spacing: 4) {
                        Text("\(Int(toolchain.progress * 100))%")
                        Text(label)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
                .transition(.opacity)

                if !toolchain.installOutput.isEmpty {
                    ScrollView {
                        Text(String(toolchain.installOutput.suffix(12_000)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 30)
                }
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ component: ToolchainManager.Component) -> some View {
        if toolchain.isInstalled(component) {
            Label("Installed", systemImage: "checkmark")
                .font(.caption).foregroundStyle(.green)
        } else if component.livesInGuest && !toolchain.guestChecked {
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not installed").font(.caption).foregroundStyle(.orange)
        }

        // What the guest's own verification said about each tool, so "installed"
        // and "runs" are never confused for each other.
        ForEach(verdictRows(for: component), id: \.self) { line in
            Label(line.text, systemImage: line.icon)
                .font(.caption)
                .foregroundStyle(line.color)
        }
    }

    private struct VerdictLine: Hashable {
        let text: String
        let icon: String
        let color: Color
    }

    private func verdictRows(for component: ToolchainManager.Component) -> [VerdictLine] {
        let names: [String]
        switch component {
        case .swift: names = ["swift", "swiftly"]
        case .xtool: names = ["xtool"]
        default: names = []
        }
        return names.compactMap { name in
            guard let verdict = toolchain.toolVerdicts[name] else { return nil }
            switch verdict {
            case .ok(let detail):
                return VerdictLine(text: "\(name): \(detail)", icon: "checkmark.seal",
                                   color: .green)
            case .broken(let detail):
                return VerdictLine(text: "\(name) is installed but does not run here (\(detail))",
                                   icon: "exclamationmark.triangle", color: .orange)
            case .missing:
                return VerdictLine(text: "\(name): not installed", icon: "xmark.circle",
                                   color: .orange)
            }
        }
    }
}
