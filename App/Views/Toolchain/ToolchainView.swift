import SwiftUI
import UniformTypeIdentifiers

/// Manage the build toolchain.
///
/// Two halves, and the screen is honest about which one is missing:
///
///  - **the compiler**, linked into this build of the app
///    (`Support/NativeToolchain.generated.xcconfig`, written by
///    `NativeToolchain/prepare-xcode.sh`). It cannot be installed at runtime —
///    either the libraries are in the binary or they are not — so this reports
///    what is there;
///  - **the Darwin SDK**, a bundle in the app's container, downloaded or imported
///    here.
///
/// The smoke test compiles a real file through the linked compiler and links it,
/// which is the only way to know the toolchain works before a build depends on it.
struct ToolchainView: View {
    @State private var sdkPath: String?
    @State private var sdkError: String?
    @State private var importing = false
    @State private var working = false
    @State private var message: String?
    @State private var smokeResult: String?
    @State private var confirmingDownload = false

    private var capabilities: NativeToolchainCapabilities { .current }

    var body: some View {
        Form {
            Section {
                row("clang", present: capabilities.hasClang)
                row("ld64.lld (Mach-O linker)", present: capabilities.hasLLDMachO)
                row("swift-frontend", present: capabilities.hasSwiftFrontend)
            } header: {
                Text("Compiler")
            } footer: {
                Text(capabilities.hasClang
                     ? "Linked into this build: \(capabilities.backendDescription)"
                     : "Not linked into this build. The native compiler has to be in the binary, "
                       + "so install the toolchain bundle and rebuild (NativeToolchain/install-bundle.sh).")
            }

            Section {
                if sdkPath != nil {
                    LabeledContent("SDK", value: "installed")
                    LabeledContent("Path", value: sdkPath ?? "")
                } else {
                    Text("Not installed. A build cannot compile anything without it.")
                        .foregroundStyle(.secondary)
                }
                if let sdkError {
                    Text(sdkError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Darwin SDK")
            } footer: {
                Text("The SDK is xtool's darwin.artifactbundle: the iPhoneOS headers, the "
                     + "tbd stubs and the static Swift runtime, read straight out of the "
                     + "app's container. About 460 MB.")
            }

            Section {
                Button {
                    confirmingDownload = true
                } label: {
                    Label(working ? "Working…" : "Download the Darwin SDK", systemImage: "arrow.down.circle")
                }
                .disabled(working)

                Button {
                    importing = true
                } label: {
                    Label("Install from a bundle in Files…", systemImage: "doc.badge.plus")
                }
                .disabled(working)

                if sdkPath != nil {
                    Button(role: .destructive) {
                        removeSDK()
                    } label: {
                        Label("Remove the SDK", systemImage: "trash")
                    }
                    .disabled(working)
                }
            } header: {
                Text("Actions")
            }

            Section {
                Button {
                    Task { await runSmokeTest() }
                } label: {
                    Label("Compile and link a test file", systemImage: "checkmark.seal")
                }
                .disabled(working || !capabilities.canCompile || sdkPath == nil)

                if let smokeResult {
                    Text(smokeResult)
                        .font(.footnote)
                        .foregroundStyle(smokeResult.hasPrefix("✓") ? .green : .red)
                }
            } header: {
                Text("Verify")
            } footer: {
                Text("Compiles a C file with clang and links it with ld64.lld, in this process, "
                     + "against the installed SDK. This is what a real build does.")
            }

            if let message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Toolchain")
        .task { refresh() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            install(from: url)
        }
        .confirmationDialog(
            "Download the Darwin SDK?",
            isPresented: $confirmingDownload
        ) {
            Button("Download") { Task { await downloadSDK() } }
        } message: {
            Text("About 460 MB, downloaded into the app's container.")
        }
    }

    // MARK: - Rows

    private func row(_ title: String, present: Bool) -> some View {
        HStack {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? .green : .secondary)
            Text(title)
            Spacer()
            Text(present ? "linked" : "missing")
                .font(.caption)
                .foregroundStyle(present ? .green : .secondary)
        }
    }

    // MARK: - Actions

    private func refresh() {
        do {
            let layout = try NativeSDK.layout()
            sdkPath = layout.sdkRoot.path
            sdkError = nil
        } catch {
            sdkPath = nil
            sdkError = NativeSDK.isInstalled ? error.localizedDescription : nil
        }
    }

    private func downloadSDK() async {
        working = true
        message = nil
        defer { working = false }
        do {
            try await NativeSDK.installLatestPrebuilt()
            refresh()
            message = "Darwin SDK installed."
        } catch {
            sdkError = error.localizedDescription
        }
    }

    private func install(from url: URL) {
        working = true
        message = nil
        defer { working = false }
        do {
            try NativeSDK.install(from: url)
            refresh()
            message = "Darwin SDK installed from \(url.lastPathComponent)."
        } catch {
            sdkError = error.localizedDescription
        }
    }

    private func removeSDK() {
        do {
            try NativeSDK.remove()
            refresh()
            message = "Darwin SDK removed."
        } catch {
            sdkError = error.localizedDescription
        }
    }

    private func runSmokeTest() async {
        working = true
        smokeResult = nil
        defer { working = false }
        do {
            let layout = try NativeSDK.layout()
            let object = try await Task.detached(priority: .userInitiated) {
                try NativeToolchain.smokeCompile(sdk: layout.sdkRoot)
            }.value
            let size = (try? object.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            smokeResult = "✓ \(object.lastPathComponent) (\(size) bytes)"
        } catch {
            smokeResult = error.localizedDescription
        }
    }
}
