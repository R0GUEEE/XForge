import Foundation
import Combine

/// Manages the on-device build toolchain.
///
/// The pieces live in two places, and this type is careful to check the right one:
///
/// - **Alpine rootfs** — bundled inside the app and imported into iSH-AOK's fakefs
///   on first boot. Nothing is downloaded; "installing" it just performs the import.
/// - **Swift / xtool / darwin SDK** — inside the guest Linux, reached over the VM
///   bridge. Installing them runs XForge's provisioning script *in the guest*, one
///   step at a time so the screen can show progress: the script is
///   `EmbeddedLinux/install-toolchain.sh`, and the same file can be run by hand in
///   the Terminal (`sh /root/install-toolchain.sh`).
@MainActor
final class ToolchainManager: ObservableObject {
    enum Component: String, CaseIterable, Identifiable {
        case rootfs = "Alpine Rootfs"
        case swift = "Swift Toolchain"
        case xtool = "xtool"
        case sdk = "Darwin SDK"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .rootfs: return "shippingbox"
            case .swift: return "swift"
            case .xtool: return "hammer"
            case .sdk: return "externaldrive.connected.to.line.below"
            }
        }

        var blurb: String {
            switch self {
            case .rootfs: return "Alpine aarch64 userspace · bundled in the app"
            case .swift: return "Swift toolchain, installed with swiftly"
            case .xtool: return "xtool aarch64 (glibc, via the compatibility layer)"
            case .sdk: return "arm64-apple-ios Swift SDK"
            }
        }

        /// Whether the component lives inside the guest Linux (vs. on the host).
        var livesInGuest: Bool { self != .rootfs }
    }

    /// The steps `install-toolchain.sh` runs, in order. Installing the Swift
    /// toolchain or xtool walks these; each is a separate command in the guest,
    /// which is what makes a progress bar possible at all (the engine's command
    /// primitive only returns output when a command finishes).
    enum ProvisionStep: String, CaseIterable {
        case deps, glibc, xtool, swiftly, swift, verify

        var title: String {
            switch self {
            case .deps: return "Installing base packages"
            case .glibc: return "Installing the glibc compatibility layer"
            case .xtool: return "Installing xtool"
            case .swiftly: return "Installing swiftly (the Swift installer)"
            case .swift: return "Installing the Swift toolchain"
            case .verify: return "Checking that the tools run"
            }
        }
    }

    /// What the guest said about a tool when the provisioning finished.
    enum ToolVerdict: Equatable {
        case ok(String)
        case broken(String)
        case missing

        var isUsable: Bool { if case .ok = self { return true }; return false }
    }

    @Published private(set) var installed: Set<Component> = []
    @Published private(set) var isInstalling: Component?
    @Published private(set) var guestChecked = false
    @Published private(set) var activity: String?
    @Published var message: String?

    /// 0…1 while an install is running, so the row can show a real bar.
    @Published private(set) var progress: Double = 0
    /// What that fraction is measuring ("Installing xtool", "Downloading …").
    @Published private(set) var progressLabel: String?
    /// Per-tool result, straight from the script's own verification step.
    @Published private(set) var toolVerdicts: [String: ToolVerdict] = [:]

    private let vm: LinuxVM

    /// Pinned xtool aarch64 AppImage (matches the XKit version in project.yml).
    static let xtoolDownloadURL = "https://github.com/xtool-org/xtool/releases/download/1.17.0/xtool-aarch64.AppImage"

    init(vm: LinuxVM? = nil) {
        self.vm = vm ?? XForgeEnvironment.makeVM()
    }

    func isInstalled(_ component: Component) -> Bool { installed.contains(component) }

    /// Exposed for the import UI: iSH-AOK cannot replace a mounted rootfs.
    var isGuestBooted: Bool { vm.isBooted }

    // MARK: - Status

    /// Refresh component status.
    ///
    /// Host-side facts are always checked. Guest-side components are only probed
    /// when `probeGuest` is true (or the guest is already running), because probing
    /// boots the embedded Linux — which imports the rootfs the first time.
    func refresh(probeGuest: Bool = false) async {
        var found: Set<Component> = []

        // RootTabView starts this at launch, but Settings can be presented before
        // that task has completed. Await the same idempotent preparation here so
        // the row reflects the actual bundled rootfs rather than a stale snapshot.
        if !RootfsInstaller.isInstalled(in: XForgeEnvironment.rootsDirectory) {
            activity = "Preparing the bundled Alpine rootfs…"
            await vm.prepareRootfs()
            activity = nil
        }
        if RootfsInstaller.isInstalled(in: XForgeEnvironment.rootsDirectory) {
            found.insert(.rootfs)
        }

        if probeGuest || vm.isBooted {
            activity = vm.isBooted ? "Checking the embedded Linux…" : "Starting the embedded Linux…"
            defer { activity = nil }
            do {
                XForgeLog.prepare()
                XForgeLog.note("refresh: probing the guest")
                try await vm.boot()
                for component in [Component.swift, .xtool, .sdk] {
                    if await guestHas(component) { found.insert(component) }
                }
                guestChecked = true
            } catch {
                XForgeLog.note("refresh: guest probe failed: \(error.localizedDescription)")
                message = "Could not check the embedded Linux: \(error.localizedDescription)"
                // Keep whatever we already knew rather than reporting everything missing.
                found.formUnion(guestKnown)
            }
        } else {
            found.formUnion(guestKnown)
        }

        guestKnown = found.subtracting([.rootfs])
        installed = found
    }

    /// Last known guest-side state, so an un-probed refresh doesn't lose it.
    private var guestKnown: Set<Component> = []

    /// True when the guest reports the component present (exit status 0).
    private func guestHas(_ component: Component) async -> Bool {
        let command: String
        switch component {
        case .rootfs:
            return RootfsInstaller.isInstalled(in: XForgeEnvironment.rootsDirectory)
        case .swift:
            command = "command -v swift >/dev/null 2>&1"
        case .xtool:
            command = "command -v xtool >/dev/null 2>&1"
        case .sdk:
            command = "command -v swift >/dev/null 2>&1 && swift sdk list 2>/dev/null | grep -qi darwin"
        }
        do {
            let status = try await vm.run(command, environment: nil) { _ in }
            return status == 0
        } catch {
            return false
        }
    }

    // MARK: - Install

    func install(_ component: Component) async {
        isInstalling = component
        defer { isInstalling = nil }
        XForgeLog.prepare()
        XForgeLog.note("install: \(component.rawValue) requested")
        // Provisioning downloads and unpacks inside the guest for many minutes,
        // and the SDK unpacks ~1.4 GB on the host. If the screen locks mid-way
        // iOS suspends the app and the install dies half-done, leaving the kind
        // of broken state the next attempt then has to work around.
        let keepAwake = InstallAssertion.begin(reason: "install \(component.rawValue)")
        defer { keepAwake.end() }
        beginProgress(component)
        do {
            switch component {
            case .rootfs:
                activity = "Installing the bundled Alpine rootfs…"
                // Booting *is* the install: the import of the bundled archive
                // happens on the emulator's own thread, inside the bridge.
                advanceProgress(0.4, "Importing the bundled rootfs into fakefs")
                try await vm.boot()
                advanceProgress(1.0, "Done")
                message = "Alpine rootfs installed from the copy bundled in the app."

            case .swift, .xtool:
                activity = "Provisioning in the guest…"
                XForgeLog.note("install: guest-side provisioning for \(component.rawValue)")
                try await provisionGuest()

            case .sdk:
                activity = "Downloading the Darwin SDK…"
                XForgeLog.note("install: darwin SDK")
                try await installSDK()
            }
            activity = nil
            endProgress()
            await refresh(probeGuest: true)
        } catch {
            activity = nil
            endProgress()
            XForgeLog.note("install: \(component.rawValue) FAILED: \(error.localizedDescription)")
            message = error.localizedDescription
        }
    }

    /// Replace the bundled rootfs with an Alpine `.tar.gz` chosen from Files.
    /// iSH-AOK cannot switch roots after it has booted, so this is intentionally
    /// limited to a fresh app launch.
    func importRootfs(from archive: URL) async {
        guard !vm.isBooted else {
            message = "Quit and reopen XForge before replacing the Alpine rootfs. The running Linux guest cannot switch roots."
            return
        }

        isInstalling = .rootfs
        defer { isInstalling = nil }
        beginProgress(.rootfs)
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        do {
            activity = "Importing \(archive.lastPathComponent)…"
            advanceProgress(0.2, "Validating and importing the selected Alpine rootfs")
            _ = try RootfsInstaller.install(
                archive: archive,
                into: XForgeEnvironment.rootsDirectory
            )
            advanceProgress(1.0, "Done")
            message = "Alpine rootfs imported from \(archive.lastPathComponent)."
            installed.insert(.rootfs)
        } catch {
            message = error.localizedDescription
        }
        activity = nil
        endProgress()
    }

    /// Install a locally supplied Darwin SDK archive. The zip must contain a
    /// `darwin.artifactbundle` directory, at its root or in one enclosing folder.
    func installSDKFromArchive(zip: URL) async {
        isInstalling = .sdk
        defer { isInstalling = nil }
        beginProgress(.sdk)
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        do {
            guard zip.pathExtension.lowercased() == "zip" else {
                throw ToolchainError.sdkArchiveUnsupported
            }
            try await vm.boot()
            let guestDirectory = "/root/.cache/xforge-sdk-import"
            let guestArchive = guestDirectory + "/darwin-sdk.zip"
            advanceProgress(0.15, "Copying \(zip.lastPathComponent) into Alpine")
            _ = try await vm.run("rm -rf \(GuestShell.quote(guestDirectory)) && mkdir -p \(GuestShell.quote(guestDirectory))", environment: nil) { _ in }
            try await vm.copyIn(hostURL: zip, to: guestArchive)

            advanceProgress(0.6, "Installing the Darwin SDK from the local archive")
            let script = """
            set -eu
            cache=\(GuestShell.quote(guestDirectory))
            unpack="$cache/unpacked"
            unzip -q "$cache/darwin-sdk.zip" -d "$unpack"
            bundle="$(find "$unpack" -type d -name darwin.artifactbundle -print -quit)"
            test -n "$bundle"
            test -f "$bundle/info.json"
            swift sdk install "$bundle"
            rm -rf "$cache"
            swift sdk list
            """
            let output = OutputCollector()
            let status = try await vm.run(script, environment: nil) { output.append($0) }
            guard status == 0 else {
                if output.value.contains("info.json") || output.value.contains("darwin.artifactbundle") {
                    throw ToolchainError.sdkLayoutUnexpected
                }
                throw ToolchainError.sdkInstallFailed(status)
            }
            advanceProgress(1.0, "Done")
            message = "Darwin SDK installed from \(zip.lastPathComponent)."
        } catch {
            message = error.localizedDescription
        }
        activity = nil
        endProgress()
        await refresh(probeGuest: true)
    }

    /// Install the Darwin SDK from an `Xcode.xip` the user picked, instead of the
    /// prebuilt bundle XForge publishes.
    ///
    /// `xtool sdk build` is what turns an Xcode install into the SDK bundle, and it
    /// needs both xtool and a Swift toolchain in the guest — and the xip staged
    /// where the guest can read it, which is the shared folder at `/host`.
    func installSDKFromXcode(xip: URL) async {
        isInstalling = .sdk
        defer { isInstalling = nil }
        XForgeLog.prepare()
        let keepAwake = InstallAssertion.begin(reason: "install darwin SDK from Xcode")
        defer { keepAwake.end() }
        beginProgress(.sdk)
        do {
            try await stageXcodeForGuest(xip)
            advanceProgress(0.5, "Building the darwin SDK inside the guest with xtool")

            let guestXip = "/host/\(Self.hostShareName(for: xip))"
            let guestOutput = "/root/.cache/xforge-sdk-build"
            let output = OutputCollector()
            let status = try await vm.run(
                "rm -rf \(GuestShell.quote(guestOutput)) && "
                + "mkdir -p \(GuestShell.quote(guestOutput)) && "
                + "cd /root && xtool sdk build \(GuestShell.quote(guestXip)) "
                + GuestShell.quote(guestOutput),
                environment: nil
            ) { chunk in
                output.append(chunk)
                let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { XForgeLog.note("guest: " + text) }
            }
            guard status == 0 else {
                throw ToolchainError.sdkBuildFailed(status, output.tail)
            }

            advanceProgress(0.9, "Installing the built SDK in the guest")
            let installStatus = try await vm.run(
                "swift sdk install \(GuestShell.quote(guestOutput + "/darwin.artifactbundle")) "
                + "&& rm -rf \(GuestShell.quote(guestOutput))",
                environment: nil
            ) { chunk in
                XForgeLog.note("guest: " + chunk.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard installStatus == 0 else { throw ToolchainError.sdkInstallFailed(installStatus) }

            advanceProgress(1.0, "Done")
            message = "Darwin SDK built from \(xip.lastPathComponent) and installed."
        } catch {
            XForgeLog.note("install: SDK from Xcode FAILED: \(error.localizedDescription)")
            message = error.localizedDescription
        }
        endProgress()
        await refresh(probeGuest: true)
    }

    /// Copy the user's `Xcode.xip` into the folder the guest sees at `/host`.
    private func stageXcodeForGuest(_ source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let share = XForgeEnvironment.hostShareDirectory
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let staging = share.appendingPathComponent(Self.hostShareName(for: source))

        let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64 ?? 0
        if size > 0, size + 1_000_000_000 > XForgeEnvironment.availableBytes {
            throw ToolchainError.notEnoughSpace(needed: size + 1_000_000_000,
                                                free: XForgeEnvironment.availableBytes)
        }

        advanceProgress(0.05, "Copying \(source.lastPathComponent) into the guest's shared folder")
        XForgeLog.note("sdk: copying \(source.lastPathComponent) (\(size) bytes) to \(staging.path)")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.copyItem(at: source, to: staging)
        XForgeLog.note("sdk: staged at \(staging.path)")
    }

    static func hostShareName(for url: URL) -> String {
        url.pathExtension.lowercased() == "xip" ? "Xcode-import.xip" : "Xcode-import"
    }

    /// Run the in-guest provisioning script (Swift toolchain, xtool and the glibc
    /// layer they need), one step at a time.
    private func provisionGuest() async throws {
        // Every guest-side component installs *into the embedded Alpine rootfs*:
        // import it first if it is not already there, then boot from it.
        await vm.prepareRootfs()
        try await vm.boot()

        guard let script = Bundle.main.url(forResource: "install-toolchain", withExtension: "sh") else {
            throw ToolchainError.scriptMissing
        }
        let guestPath = "/root/install-toolchain.sh"
        try await vm.copyIn(hostURL: script, to: guestPath)

        let steps = ProvisionStep.allCases
        beginProgress(.swift, steps: steps.count)

        for (index, step) in steps.enumerated() {
            advanceProgress(Double(index) / Double(steps.count), step.title)
            XForgeLog.note("provision: \(step.rawValue)")

            let collector = OutputCollector()
            // These steps download hundreds of megabytes inside the guest and can
            // take many minutes each; the engine returns a command's output only
            // when it finishes, so the log gets it step by step.
            let status = try await vm.run(
                "sh \(GuestShell.quote(guestPath)) \(GuestShell.quote(step.rawValue))",
                environment: ["PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
            ) { chunk in
                collector.append(chunk)
                let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { XForgeLog.note("guest: " + text) }
            }

            if step == .verify {
                recordVerdicts(from: collector.value)
            }
            guard status == 0 || step == .verify else {
                throw ToolchainError.provisioningFailed(status, step: step.title,
                                                       output: collector.tail)
            }
            advanceProgress(Double(index + 1) / Double(steps.count), step.title)
        }

        endProgress()
        if toolVerdicts.values.contains(where: { !$0.isUsable }) {
            message = "Installed in the guest rootfs. Some tools do not run in it yet — "
                + "see Settings → Diagnostics → Engine log."
        } else {
            message = "Swift and xtool are installed in the embedded Linux."
        }
    }

    /// Parse the verification step's `XFORGE-VERIFY <tool> <kind> <detail>` lines.
    private func recordVerdicts(from output: String) {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0].contains("XFORGE-VERIFY") else { continue }
            let tool = String(parts[1])
            let detail = String(parts[3])
            switch String(parts[2]) {
            case "ok": toolVerdicts[tool] = .ok(detail)
            case "broken": toolVerdicts[tool] = .broken(detail)
            default: toolVerdicts[tool] = .missing
            }
        }
    }

    /// Download, extract, and install the Darwin Swift SDK inside Alpine.
    private func installSDK() async throws {
        try await SDKInstaller.install(vm: vm) { [weak self] fraction, label in
            guard let self else { return }
            self.activity = label
            self.advanceProgress(fraction, label)
        }
        message = "Darwin SDK installed. `swift sdk list` now offers darwin."
    }

    // MARK: - Progress

    private func beginProgress(_ component: Component, steps: Int = 3) {
        progress = 0
        progressLabel = "Starting \(component.rawValue)"
    }

    private func advanceProgress(_ fraction: Double, _ label: String) {
        progress = max(0, min(1, fraction))
        progressLabel = label
        XForgeLog.note("progress: \(Int(progress * 100))% — \(label)")
    }

    private func endProgress() {
        progress = 0
        progressLabel = nil
    }

    // MARK: - Reset

    /// Remove the imported rootfs, the staged SDK and downloaded archives.
    func reset() async {
        isInstalling = nil
        activity = nil
        endProgress()
        let fm = FileManager.default
        try? fm.removeItem(at: XForgeEnvironment.rootsDirectory)
        try? fm.removeItem(at: XForgeEnvironment.downloadsDirectory)
        installed = []
        guestKnown = []
        guestChecked = false
        toolVerdicts = [:]
        message = "Removed the imported rootfs, the staged SDK and downloads. "
            + "Quit and reopen XForge to boot a fresh guest."
    }
}

enum ToolchainError: LocalizedError {
    case scriptMissing
    case provisioningFailed(Int32, step: String, output: String)
    case sdkLayoutUnexpected
    case sdkInstallFailed(Int32)
    case sdkBuildFailed(Int32, String)
    case sdkArchiveUnsupported
    case notEnoughSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return "install-toolchain.sh is not bundled in the app."
        case .provisioningFailed(let status, let step, let output):
            var text = "Installing failed at “\(step)” (exit \(status))."
            if output.lowercased().contains("dns:") || output.lowercased().contains("bad address") {
                text += " The guest could not resolve anything: allow XForge local network "
                    + "access in Settings → Privacy & Security → Local Network."
            }
            return text + " The Engine log has the guest's own output."
        case .sdkLayoutUnexpected:
            return "The downloaded Darwin SDK archive did not contain darwin.artifactbundle/info.json."
        case .sdkInstallFailed(let status):
            return "`swift sdk install` failed inside the guest (exit \(status))."
        case .sdkBuildFailed(let status, let output):
            return "`xtool sdk build` failed in the guest (exit \(status)). "
                + (output.isEmpty ? "" : String(output.suffix(400)))
        case .sdkArchiveUnsupported:
            return "Choose a .zip archive containing darwin.artifactbundle."
        case .notEnoughSpace(let needed, let free):
            let formatter = ByteCountFormatter()
            return "Not enough free space: this needs about "
                + "\(formatter.string(fromByteCount: needed)) and "
                + "\(formatter.string(fromByteCount: free)) is free."
        }
    }
}

/// Thread-safe string accumulator for output delivered from a `@Sendable` callback.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    /// Last few lines — what an error message should show.
    var tail: String {
        let all = value.split(separator: "\n").suffix(6).joined(separator: "\n")
        return all
    }
}
