import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @EnvironmentObject private var terminal: TerminalSession
    @StateObject private var toolchain = ToolchainManager()
    /// On-disk sizes, filled off the main actor — never computed during `body`.
    @State private var sizes: [ToolchainManager.Component: Int64] = [:]
    @State private var artifactsSize: Int64 = 0

    var body: some View {
        List {
            Section {
                NavigationLink { ToolchainView() } label: {
                    Label("Toolchain & Alpine", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink { DownloadsView() } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    SandboxBrowserView(root: XForgeEnvironment.documentDirectory)
                } label: {
                    Label("Files (app sandbox)", systemImage: "folder")
                }
                NavigationLink { HistoryView() } label: {
                    Label("Build History", systemImage: "clock.arrow.circlepath")
                }
            } header: {
                Text("System & Files")
            } footer: {
                Text("Alpine, the compiler toolchain, SDKs, downloads and app files are managed here.")
            }

            preferencesSection
            storageSection
            diagnosticsSection
            aboutSection
        }
        .task {
            await toolchain.refresh()
            await loadSizes()
        }
    }

    /// Compute the storage sizes once, off the main actor.
    private func loadSizes() async {
        let components = ToolchainManager.Component.allCases
        let paths: [(ToolchainManager.Component, URL)] = components.map {
            ($0, storageURL(for: $0))
        }
        let staging = XForgeEnvironment.stagingDirectory
        let result = await Task.detached(priority: .utility) { () -> ([ToolchainManager.Component: Int64], Int64) in
            var map: [ToolchainManager.Component: Int64] = [:]
            for (component, url) in paths {
                map[component] = DirectorySize.bytes(at: url)
            }
            return (map, DirectorySize.bytes(at: staging))
        }.value
        sizes = result.0
        artifactsSize = result.1
    }

    /// Where a component's bytes live on the host.
    private func storageURL(for component: ToolchainManager.Component) -> URL {
        switch component {
        case .rootfs:
            return XForgeEnvironment.rootsDirectory
        case .swift, .xtool, .sdk:
            // Every tool and SDK lives in the imported Alpine fakefs.
            return RootfsInstaller.installedRoot(in: XForgeEnvironment.rootsDirectory)
        }
    }

    private var preferencesSection: some View {
        Section("Build Defaults") {
            TextField("Organization Identifier", text: $preferences.defaultOrgId)
                .keyboardType(.alphabet).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Minimum iOS", text: $preferences.defaultMinIOS)
                .keyboardType(.decimalPad)
            Picker("Configuration", selection: $preferences.defaultConfiguration) {
                ForEach(BuildConfiguration.allCases) { cfg in
                    Text(cfg.rawValue).tag(cfg)
                }
            }
            Toggle("iPhone-first layout", isOn: $preferences.showIPhoneOnlyLayout)
        }
    }

    private var storageSection: some View {
        Section {
            ForEach(ToolchainManager.Component.allCases) { component in
                StorageRow(
                    title: component.rawValue,
                    detail: storageDetail(for: component),
                    installed: toolchain.isInstalled(component),
                    installing: toolchain.isInstalling == component,
                    progress: toolchain.isInstalling == component ? toolchain.progress : nil,
                    progressLabel: toolchain.isInstalling == component ? toolchain.progressLabel : nil
                ) {
                    install(component)
                }
            }
            StorageRow(title: "Build artifacts",
                       detail: ByteCountFormatter.string(fromByteCount: artifactsSize, countStyle: .file),
                       installed: true) {}
        } header: {
            Text("Storage & Toolchain")
        } footer: {
            Text("The Alpine rootfs is bundled and installs offline. Swift, xtool and "
                 + "the darwin SDK are installed by commands inside the embedded Linux: "
                 + "Install hands the command to the Terminal tab, where you can watch it.")
        }
    }

    /// Hand a component's install command to the Terminal, after making sure the
    /// guest is running and the provisioning script is in it.
    private func install(_ component: ToolchainManager.Component) {
        Task {
            do {
                let vm = XForgeEnvironment.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                switch component {
                case .rootfs:
                    toolchain.message = "The Alpine rootfs is bundled in the app and "
                        + "already installed in the guest filesystem."
                case .swift:
                    try await SystemComponents.ensureInstallerScript(in: vm)
                    terminal.enqueue(SystemComponents.swiftInstallCommand, label: "Settings")
                    toolchain.message = "Swift toolchain: installing in the Terminal tab."
                case .xtool:
                    try await SystemComponents.ensureInstallerScript(in: vm)
                    terminal.enqueue(SystemComponents.xtoolInstallCommand, label: "Settings")
                    toolchain.message = "xtool: installing in the Terminal tab."
                case .sdk:
                    let url = try await XForgeReleases.darwinSDKURL()
                    terminal.enqueue(SystemComponents.darwinSDKDownloadCommand(from: url),
                                     label: "Settings")
                    toolchain.message = "Darwin SDK: downloading and installing in the Terminal tab."
                }
            } catch {
                toolchain.message = error.localizedDescription
            }
        }
    }

    private func storageDetail(for component: ToolchainManager.Component) -> String {
        let size = ByteCountFormatter.string(fromByteCount: sizes[component] ?? 0, countStyle: .file)
        switch (component, toolchain.isInstalled(component)) {
        case (.rootfs, true):
            return "Installed · \(size)"
        case (.rootfs, false):
            return "Bundled in the app · installs offline"
        case (.sdk, true):
            return "Installed in the guest · \(size) staged"
        case (.sdk, false):
            return "Downloads on demand (214 MB)"
        case (_, true):
            return "Installed in the embedded Linux"
        case (_, false):
            return component.livesInGuest && !toolchain.guestChecked
                ? "Not checked — tap Check on the Toolchain screen"
                : "Not installed"
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Device", value: "\(SystemInfo.deviceName) (\(SystemInfo.deviceModel))")
            LabeledContent("System", value: "\(SystemInfo.systemName) \(SystemInfo.systemVersion)")
            LabeledContent("App", value: "\(SystemInfo.appVersion) (\(SystemInfo.appBuild))")
            LabeledContent("Bundle ID", value: SystemInfo.bundleIdentifier)
            LabeledContent("Memory", value: SystemInfo.memory)
            LabeledContent("CPU", value: "\(SystemInfo.processorCount) cores")
            LabeledContent("Storage free", value: SystemInfo.storage.free + " of " + SystemInfo.storage.total)
            LabeledContent("Low Power Mode", value: SystemInfo.isLowPowerMode ? "On" : "Off")
            NavigationLink {
                EngineLogView()
            } label: {
                Label("Engine log", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The engine log holds the embedded Linux's own messages and "
                 + "XForge's install breadcrumbs — share it when something dies "
                 + "without an explanation.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: SystemInfo.appVersion)
            Link("Source", destination: URL(string: "https://github.com/R0GUEEE/XForge")!)
            Link("xtool", destination: URL(string: "https://github.com/xtool-org/xtool")!)
        } header: {
            Text("About")
        } footer: {
            Text("XForge builds iOS apps on-device with xtool — a cross-platform Xcode replacement.")
        }
    }
}

struct StorageRow: View {
    let title: String
    let detail: String
    var installed = true
    var installing = false
    /// 0…1 while this component installs, and what that fraction is measuring.
    var progress: Double?
    var progressLabel: String?
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(installed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !installed {
                    Button {
                        onInstall()
                    } label: {
                        if installing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Install", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(installing)
                }
            }

            // Under the row it belongs to, with what is happening right now: the
            // engine returns a guest command's output only when it finishes, so
            // this line is the only live feedback there is.
            if let progress, let progressLabel {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    HStack(spacing: 4) {
                        Text("\(Int(progress * 100))%")
                        Text(progressLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
        }
    }
}
