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
    @StateObject private var importState = SDKImportState()

    /// What the picker offers: a built bundle (a folder, or a zip of one) or Apple's
    /// `Xcode.xip`, which the app turns into one. `.xip` has no system type, so it is
    /// declared here by extension — without it the file is greyed out in Files and
    /// the one import this screen exists for cannot be started.
    private static var importableTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        if let xip = UTType(filenameExtension: "xip", conformingTo: .data) {
            types.append(xip)
        }
        return types
    }

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
                     + "app's container. About 460 MB downloaded, or built here from an "
                     + "Xcode.xip — which the picker copies into the container first, so "
                     + "an 11 GB xip needs roughly 12 GB free, plus about 1.5 GB for the "
                     + "bundle. Extraction takes a few minutes.")
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
                    Label("Install from an Xcode.xip or a bundle…", systemImage: "doc.badge.plus")
                }
                .disabled(working)

                if importState.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: importState.fraction)
                        Text(importState.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
                Text("Compiles a C file with clang, links it into an arm64 executable with "
                     + "ld64.lld, and — when the Swift frontend is linked — compiles a Swift "
                     + "file too. All in this process, against the installed SDK.")
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
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await install(from: url) }
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

    /// Install whatever was picked, off the main actor, with progress.
    ///
    /// The work is minutes of blocking decompression, so it runs in a detached task.
    /// Its progress comes back through a stream rather than a closure that writes to
    /// this view's state: the closure handed to the detached task is `@Sendable`, and
    /// capturing the view in one is the sort of thing that compiles until it does not
    /// — the receiver is a `@MainActor` type, which is `Sendable`, so it can be
    /// captured freely. Same shape as the build pipeline's stage streams.
    private func install(from url: URL) async {
        working = true
        message = nil
        sdkError = nil

        // The object, not the property wrapper: this is what the consumer task
        // captures, so that no closure here has to capture the view.
        let state = importState
        state.begin("Reading \(url.lastPathComponent)…")

        let (updates, continuation) = AsyncStream<DarwinSDKBuilder.Progress>.makeStream()
        let consumer = Task { @MainActor in
            for await update in updates {
                state.update(fraction: update.fraction, status: update.message)
            }
            state.finish()
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                try NativeSDK.installImported(from: url) { continuation.yield($0) }
            }.value
            refresh()
            message = "Darwin SDK installed from \(url.lastPathComponent)."
        } catch is CancellationError {
            message = "Import cancelled."
        } catch {
            sdkError = error.localizedDescription
        }

        continuation.finish()
        await consumer.value
        state.finish()
        working = false

        // The picker's copy of the archive is the app's to delete, and for an
        // `Xcode.xip` it is most of the free space on the device.
        await Task.detached(priority: .utility) {
            NativeSDK.discardImportCopy(at: url)
        }.value
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

    /// Compile *and* link, in this process, against the installed SDK.
    ///
    /// A smoke test that only compiles cannot tell a working toolchain from one
    /// whose objects the linker rejects, and the linker is the half that carries
    /// the platform version and the entry point. The Swift frontend is exercised
    /// too when it is linked, so the moment the frontend libraries arrive this
    /// screen proves the whole chain rather than half of it.
    private func runSmokeTest() async {
        working = true
        smokeResult = nil
        defer { working = false }
        do {
            let layout = try NativeSDK.layout()
            smokeResult = try await Task.detached(priority: .userInitiated) { () -> String in
                // Matches the default target of `NativeToolchain.compileC`
                // (`arm64-apple-ios17.0.0`), which is also XForge's own floor.
                let minimumIOSVersion = "17.0"
                var lines: [String] = []

                let object = try NativeToolchain.smokeCompile(sdk: layout.sdkRoot)
                lines.append("✓ clang: \(object.lastPathComponent)")

                let executable = object
                    .deletingLastPathComponent()
                    .appendingPathComponent("xforge-smoke")
                let linked = try NativeToolchain.linkMachO(arguments: [
                    "-arch", "arm64",
                    "-platform_version", "ios", minimumIOSVersion, minimumIOSVersion,
                    "-syslibroot", layout.sdkRoot.path,
                    "-o", executable.path,
                    "-lSystem",
                    object.path
                ])
                guard linked.succeeded else {
                    throw NativeToolchainError.link(linked.diagnostics)
                }
                let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                lines.append("✓ ld64.lld: \(executable.lastPathComponent) (\(size) bytes)")

                if NativeToolchain.isSwiftAvailable {
                    let swiftObject = try NativeToolchain.smokeCompileSwift(sdk: layout)
                    lines.append("✓ swift-frontend: \(swiftObject.lastPathComponent)")
                } else {
                    lines.append("· swift-frontend: not linked, so not tested")
                }
                return lines.joined(separator: "\n")
            }.value
        } catch {
            smokeResult = error.localizedDescription
        }
    }
}

/// Progress of a Darwin SDK import, as the screen renders it.
///
/// A reference type and a plain `ObservableObject` — the shape the rest of the app
/// uses for state a long job updates — rather than two `@State` fields, because the
/// consumer of the progress stream has to hold *something* across an actor boundary:
/// this object is `@MainActor`, and therefore `Sendable`, while the view is not.
/// Holding the view in a task's closure is the kind of capture that compiles until
/// it does not.
@MainActor
final class SDKImportState: ObservableObject {
    @Published private(set) var fraction: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false

    func begin(_ status: String) {
        fraction = 0
        self.status = status
        isRunning = true
    }

    func update(fraction: Double, status: String) {
        self.fraction = fraction
        self.status = status
    }

    func finish() {
        isRunning = false
    }
}
