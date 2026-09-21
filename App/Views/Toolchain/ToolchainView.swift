import SwiftUI
import UniformTypeIdentifiers

/// Manage the on-device build infrastructure.
///
/// Every component lives in the embedded Alpine system, and every one of them is
/// installed *by running a command inside it*. That is what this screen sets up:
/// it puts the user's files where the guest can reach them and hands the right
/// command to the Terminal, where the install runs and reports what it is doing.
///
///  - **Alpine rootfs** — bundled in the app; "installing" it is a local import.
///  - **Swift / xtool** — the commands swift.org and xtool document, run in the
///    guest (see `SystemComponents`).
///  - **Darwin SDK** — either your own `Xcode.xip`, copied into the guest's
///    storage and installed there with `xtool sdk install`, or XForge's prebuilt
///    bundle, downloaded and installed inside the guest.
struct ToolchainView: View {
    @EnvironmentObject private var terminal: TerminalSession
    @StateObject private var toolchain = ToolchainManager()
    @State private var importingXIP = false
    @State private var importingRootfs = false
    @State private var confirmingDownload = false
    @State private var preparing: String?

    var body: some View {
        Form {
            Section {
                ForEach(ToolchainManager.Component.allCases) { component in
                    row(component)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Installs run in the Terminal tab, so you can watch them — and "
                     + "answer anything they ask — while they work.")
            }

            Section {
                Button {
                    Task { await toolchain.refresh(probeGuest: true) }
                } label: {
                    Label("Check the embedded Linux", systemImage: "arrow.clockwise")
                }
                .disabled(toolchain.activity != nil || preparing != nil)
            } footer: {
                Text("Green = present. Guest components are verified inside the "
                     + "embedded Linux, which this boots if it is not running.")
            }

            Section {
                Button {
                    importingXIP = true
                } label: {
                    Label("Install the Darwin SDK from an Xcode.xip…",
                          systemImage: "doc.badge.plus")
                }
                Button {
                    confirmingDownload = true
                } label: {
                    Label("Install the prebuilt Darwin SDK…", systemImage: "arrow.down.circle")
                }
            } header: {
                Text("Darwin SDK")
            } footer: {
                Text("With an Xcode.xip: the file is copied into the Alpine system's own "
                     + "storage and then installed there with "
                     + "`xtool sdk install \"path/to/xip\"`. Without one, XForge's "
                     + "prebuilt darwin.artifactbundle is fetched and installed inside "
                     + "the guest instead.")
            }

            Section {
                Button {
                    importingRootfs = true
                } label: {
                    Label("Import an Alpine rootfs archive…",
                          systemImage: "shippingbox.and.arrow.backward")
                }
                .disabled(toolchain.isInstalling != nil || toolchain.isGuestBooted)
            } header: {
                Text("Offline Imports")
            } footer: {
                Text("Choose an Alpine aarch64 .tar.gz minirootfs. A custom import "
                     + "replaces the provisioned root, so it may not include XForge's "
                     + "bundled build tools. Quit and reopen XForge first if Linux is running.")
            }

            if let activity = toolchain.activity ?? preparing {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
            isPresented: $importingXIP,
            allowedContentTypes: [UTType(filenameExtension: "xip") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await installFromXIP(url) }
        }
        .fileImporter(
            isPresented: $importingRootfs,
            allowedContentTypes: [.archive, .gzip, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await toolchain.importRootfs(from: url) }
        }
        .confirmationDialog("Install the prebuilt Darwin SDK?",
                            isPresented: $confirmingDownload) {
            Button("Download and install in the Terminal") {
                Task { await installPrebuiltSDK() }
            }
        } message: {
            Text("About 457 MB is downloaded inside the guest and installed there. "
                 + "It runs in the Terminal tab.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ component: ToolchainManager.Component) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: component.icon)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.rawValue).font(.subheadline.weight(.semibold))
                    Text(component.blurb).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(component)
            }

            HStack(spacing: 12) {
                ForEach(actions(for: component), id: \.title) { action in
                    Button(action.title) { action.run() }
                        .font(.footnote)
                        .disabled(toolchain.isInstalling != nil || preparing != nil)
                }
            }
            .padding(.leading, 32)
        }
        .padding(.vertical, 2)
    }

    private struct RowAction {
        let title: String
        let run: () -> Void
    }

    private func actions(for component: ToolchainManager.Component) -> [RowAction] {
        switch component {
        case .rootfs:
            // The bundled rootfs installs itself; a custom archive is the
            // "Offline Imports" section below.
            return []
        case .swift:
            return [RowAction(title: "Install in Terminal") {
                installInTerminal(.swift)
            }]
        case .xtool:
            return [RowAction(title: "Install in Terminal") {
                installInTerminal(.xtool)
            }]
        case .sdk:
            return [
                RowAction(title: "From an Xcode.xip…") { importingXIP = true },
                RowAction(title: "Prebuilt download…") { confirmingDownload = true },
            ]
        }
    }

    @ViewBuilder
    private func statusBadge(_ component: ToolchainManager.Component) -> some View {
        if toolchain.isInstalled(component) {
            Label("Installed", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .font(.footnote.bold())
                .foregroundStyle(.green)
        } else if component.livesInGuest && !toolchain.guestChecked {
            Text("?").font(.footnote.bold()).foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.dashed")
                .font(.footnote.bold())
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    /// Prepare the guest and hand the component's install command to the Terminal.
    private func installInTerminal(_ component: SystemComponents.Component) {
        Task {
            preparing = "Preparing the guest for \(component.title)…"
            defer { preparing = nil }
            do {
                let vm = XForgeEnvironment.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                try await SystemComponents.ensureInstallerScript(in: vm)
                terminal.enqueue(command(for: component), label: "Toolchain")
                toolchain.message = "\(component.title): running in the Terminal tab."
            } catch {
                toolchain.message = error.localizedDescription
            }
        }
    }

    private func command(for component: SystemComponents.Component) -> String {
        switch component {
        case .glibc:
            return SystemComponents.scriptCommand(.glibc)
        case .xtool:
            return SystemComponents.xtoolInstallCommand
        case .swift:
            return SystemComponents.swiftInstallCommand
        case .darwinSDK:
            // Always driven by a file or a download, never by a bare tap.
            return SystemComponents.scriptCommand(.xtool)
        }
    }

    /// Copy the user's Xcode.xip into the guest's storage, then install it there.
    private func installFromXIP(_ url: URL) async {
        preparing = "Copying \(url.lastPathComponent) into the guest…"
        defer { preparing = nil }
        do {
            let command = try await toolchain.installSDKFromXcode(xip: url)
            terminal.enqueue(command, label: "Toolchain")
        } catch {
            toolchain.message = error.localizedDescription
        }
    }

    /// Download XForge's prebuilt Darwin SDK bundle inside the guest and install it.
    private func installPrebuiltSDK() async {
        preparing = "Resolving the latest Darwin SDK release…"
        defer { preparing = nil }
        do {
            let url = try await XForgeReleases.darwinSDKURL()
            let vm = XForgeEnvironment.makeVM()
            await vm.prepareRootfs()
            try await vm.boot()
            terminal.enqueue(SystemComponents.darwinSDKDownloadCommand(from: url),
                             label: "Toolchain")
            toolchain.message = "Downloading and installing the Darwin SDK in the Terminal tab."
        } catch {
            toolchain.message = error.localizedDescription
        }
    }
}
