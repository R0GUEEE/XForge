import SwiftUI

/// Settings: the toolchain, the app's files, build defaults and diagnostics.
///
/// Everything here used to be a *guest* concern — install Alpine, install Swift in
/// it, watch the engine log, size the fakefs. The toolchain is now linked into the
/// app and the SDK is a folder, so what is left is what the user can actually act on.
@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        List {
            Section {
                NavigationLink { ToolchainView() } label: {
                    Label("Toolchain & SDK", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink { NativeToolchainView() } label: {
                    Label("Native Compiler", systemImage: "cpu")
                }
                NavigationLink {
                    SandboxBrowserView(root: XForgeEnvironment.documentDirectory)
                } label: {
                    Label("Files (app sandbox)", systemImage: "folder")
                }
                NavigationLink { HistoryView() } label: {
                    Label("Build History", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { XForgeLogView() } label: {
                    Label("Log", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("System & Files")
            } footer: {
                Text("Projects, downloads, built IPAs and the log all live in the app's "
                     + "container, visible in the Files app.")
            }

            preferencesSection
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
            LabeledContent("Compiler", value: NativeToolchainCapabilities.current.backendDescription)
        } header: {
            Text("Diagnostics")
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
            Text("XForge builds iOS apps on-device with xtool's libraries — no Mac, no Linux guest.")
        }
    }
}

/// XForge's own log, with the share sheet.
///
/// It used to be the *engine's* log — the embedded Linux's kernel messages, which
/// was where a crash left its last trace. The compiler runs in this process now, so
/// what is left is XForge's own breadcrumbs plus whatever the build console showed.
struct XForgeLogView: View {
    @State private var text = ""
    @State private var size: Int64 = 0

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Log",
                    systemImage: "doc.text",
                    message: "Nothing has been written yet."
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: XForgeLog.url) {
                        Label("Share log", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        XForgeLog.clear()
                        load()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { load() }
    }

    private func load() {
        text = XForgeLog.text()
        size = XForgeLog.byteCount()
    }
}
