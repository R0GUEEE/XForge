import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        List {
            preferencesSection
            storageSection
            diagnosticsSection
            aboutSection
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
        Section("Storage") {
            StorageRow(title: "Embedded Linux (Alpine aarch64)", detail: onDiskSize("embedded-linux"))
            StorageRow(title: "Swift toolchain", detail: onDiskSize("embedded-linux/opt/swift"))
            StorageRow(title: "Darwin SDK", detail: onDiskSize("embedded-linux/opt/darwin.artifactbundle"))
            StorageRow(title: "Build artifacts", detail: onDiskSize("staging"))
        }
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
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
