import SwiftUI

@MainActor
struct NativeToolchainView: View {
    @State private var status = ""
    @State private var busy = false
    @State private var sdkSummary = "Not installed"

    var body: some View {
        List {
            Section("Compiler") {
                LabeledContent(
                    "Backend",
                    value: NativeToolchain.isAvailable ? "Native LLVM" : "Not linked"
                )
                LabeledContent("Version", value: NativeToolchain.version)

                if NativeToolchain.isAvailable {
                    Label("Clang and LLD run in-process", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Install the native toolchain bundle before generating the Xcode project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Darwin SDK") {
                LabeledContent("Status", value: sdkSummary)

                Button {
                    installSDK()
                } label: {
                    Label("Download Native Darwin SDK", systemImage: "arrow.down.circle")
                }
                .disabled(busy)

                if NativeSDK.isInstalled {
                    Button(role: .destructive) {
                        removeSDK()
                    } label: {
                        Label("Remove Native SDK", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }

            Section("Validation") {
                Button {
                    runSmokeTest()
                } label: {
                    Label("Compile Native C Smoke Test", systemImage: "hammer")
                }
                .disabled(busy || !NativeToolchain.isAvailable || !NativeSDK.isInstalled)

                if !status.isEmpty {
                    Text(status)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Native Toolchain")
        .task { refreshSDKStatus() }
    }

    private func refreshSDKStatus() {
        guard NativeSDK.isInstalled else {
            sdkSummary = "Not installed"
            return
        }
        do {
            let layout = try NativeSDK.layout()
            sdkSummary = layout.sdkRoot.lastPathComponent
        } catch {
            sdkSummary = "Invalid"
            status = error.localizedDescription
        }
    }

    private func installSDK() {
        busy = true
        status = "Resolving Darwin SDK release…"
        Task {
            defer { busy = false }
            do {
                try await NativeSDK.installLatestPrebuilt()
                refreshSDKStatus()
                status = "Native Darwin SDK installed."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func removeSDK() {
        do {
            try NativeSDK.remove()
            refreshSDKStatus()
            status = "Native Darwin SDK removed."
        } catch {
            status = error.localizedDescription
        }
    }

    private func runSmokeTest() {
        busy = true
        status = "Compiling in-process…"
        Task {
            defer { busy = false }
            do {
                let layout = try NativeSDK.layout()
                let object = try NativeToolchain.smokeCompile(sdk: layout.sdkRoot)
                let attributes = try FileManager.default.attributesOfItem(atPath: object.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                status = "Success: \(object.lastPathComponent) (\(size) bytes)"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
