import SwiftUI
import UniformTypeIdentifiers

/// Install built .ipa files to a connected device (via XKit/usbmuxd) or export
/// for SideStore/AltStore sideloading.
struct InstallView: View {
    @ObservedObject var device: XKitDeviceService
    @State private var errorText: String?
    @State private var isScanning = false
    @State private var showingPicker = false
    @State private var pickedIPA: URL?
    @State private var installProgress: Double = 0
    @State private var installedApps: [InstalledApp] = []

    var body: some View {
        List {
            Section("Devices") {
                if device.devices.isEmpty {
                    if isScanning {
                        HStack { ProgressView(); Text("Scanning for devices…") }
                    } else {
                        Text("No devices connected.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(device.devices) { dev in
                    NavigationLink {
                        deviceDetail(dev)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(dev.name).font(.headline)
                            Text("\(dev.model) · iOS \(dev.osVersion) · \(dev.id.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    Label(isScanning ? "Scanning…" : "Scan for Devices", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(isScanning)
            }
        }
        .navigationTitle("Install")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPicker = true
                } label: {
                    Label("Install IPA", systemImage: "arrow.down.app")
                }
                .disabled(device.devices.isEmpty)
            }
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.item]
        ) { result in
            if case .success(let url) = result { pickedIPA = url }
        }
        .task { await scan() }
    }

    @ViewBuilder
    private func deviceDetail(_ dev: ConnectedDevice) -> some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: dev.name)
                LabeledContent("Model", value: dev.model)
                LabeledContent("iOS", value: dev.osVersion)
                LabeledContent("UDID", value: dev.id)
            }
            Section("Install") {
                if let pickedIPA {
                    LabeledContent("Package", value: pickedIPA.lastPathComponent)
                    if installProgress > 0 && installProgress < 1 {
                        ProgressView(value: installProgress)
                    }
                    Button("Install on \(dev.name)") {
                        Task { await install(pickedIPA, to: dev) }
                    }
                    .buttonStyle(.borderedProminent)
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.footnote)
                    }
                } else {
                    Text("Pick an .ipa to install.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Installed Apps") {
                ForEach(installedApps) { app in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Launch") {
                            Task { _ = try? await device.launch(app.bundleIdentifier, on: dev) }
                        }
                        .buttonStyle(.bordered)
                        Button("Remove", role: .destructive) {
                            Task { _ = try? await device.uninstall(app.bundleIdentifier, from: dev) }
                        }
                    }
                }
                if installedApps.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                }
                Button("Refresh List") {
                    Task { _ = try? await refreshApps(dev) }
                }
            }
        }
        .navigationTitle(dev.name)
    }

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            try await device.refreshDevices()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func install(_ ipa: URL, to dev: ConnectedDevice) async {
        do {
            installProgress = 0
            try await device.install(ipaURL: ipa, to: dev) { installProgress = $0 }
            try await refreshApps(dev)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshApps(_ dev: ConnectedDevice) async throws {
        installedApps = try await device.installedApps(on: dev)
    }
}
