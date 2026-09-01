import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @StateObject private var toolchain = ToolchainManager()

    var body: some View {
        List {
            Section {
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
                Text("Files & Downloads")
            } footer: {
                Text("Downloads land here and forward to the embedded Linux shell at /root/downloads.")
            }

            preferencesSection
            storageSection
            diagnosticsSection
            aboutSection
        }
        .task { toolchain.refresh() }
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
                    installing: toolchain.isInstalling == component
                ) {
                    Task { await toolchain.install(component) }
                }
            }
            StorageRow(title: "Build artifacts", detail: onDiskSize("staging"), installed: true) {}
        } header: {
            Text("Storage & Toolchain")
        } footer: {
            Text("Install any missing piece here. The Darwin SDK downloads on-device; the embedded Linux and Swift install once the VM is connected.")
        }
    }

    private func storageDetail(for component: ToolchainManager.Component) -> String {
        let subpath: String
        switch component {
        case .linux: subpath = "embedded-linux"
        case .swift: subpath = "embedded-linux/opt/usr"
        case .xtool: subpath = "embedded-linux/usr/local/bin"
        case .sdk: subpath = "embedded-linux/opt/darwin.artifactbundle"
        }
        let size = directorySize(at: XForgeEnvironment.documentDirectory.appendingPathComponent(subpath))
        return toolchain.isInstalled(component)
            ? "Installed · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            : "Not installed"
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Device", value: "\(SystemInfo.deviceName) (\(SystemInfo.deviceModel))")
            LabeledContent("System", value: "\(SystemInfo.systemName) \(SystemInfo.systemVersion)")
            LabeledContent("App", value: "\(SystemInfo.appVersion) (\(SystemInfo.appBuild))")
            LabeledContent("Bundle ID", value: SystemInfo.bundleIdentifier)
            LabeledContent("Memory", value: SystemInfo.memory)
            LabeledContent("CPU", value: "\(SystemInfo.processorCount) cores")
            LabeledContent("Storage free", value: SystemInfo.storage.free + " of " + SystemInfo.storage.total)
            LabeledContent("Low Power Mode", value: SystemInfo.isLowPowerMode ? "On" : "Off")
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

    private func onDiskSize(_ subdir: String) -> String {
        let root = XForgeEnvironment.documentDirectory
        let url = root.appendingPathComponent(subdir)
        let size = directorySize(at: url)
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Recursive on-disk size of a directory.
    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

struct StorageRow: View {
    let title: String
    let detail: String
    var installed = true
    var installing = false
    let onInstall: () -> Void

    var body: some View {
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
    }
}
