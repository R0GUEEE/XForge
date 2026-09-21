import Foundation
import Combine

/// Manages the on-device build toolchain.
///
/// The pieces live in two places, and this type is careful to check the right one:
///
/// - **Alpine rootfs** — bundled inside the app and imported into iSH-AOK's fakefs
///   on first boot. Nothing is downloaded; "installing" it just performs the import.
/// - **Swift / xtool / darwin SDK** — inside the guest Linux, reached over the VM
///   bridge. Installing them means running commands *in the guest*; this type
///   checks what is there and stages the files those commands need, while the
///   commands themselves run in the Terminal (`SystemComponents` holds them).
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

        /// Every component is stored in the embedded Alpine guest. The rootfs is
        /// imported into iSH-AOK fakefs; Swift, xtool, and SDKs install below it.
        var livesInGuest: Bool { true }
    }

    @Published private(set) var installed: Set<Component> = []
    @Published private(set) var isInstalling: Component?
    @Published private(set) var guestChecked = false
    @Published private(set) var activity: String?
    @Published var message: String?

    /// 0…1 while a host-side preparation (staging a file into the guest) runs.
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressLabel: String?

    private let vm: LinuxVM

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
            // `swift sdk list` is a glibc binary being asked a question, so its
            // stderr is piped rather than sent to /dev/null: this engine kills a
            // forked guest program whose output points at /dev/null, and the
            // answer here decides whether the SDK row reads "installed".
            command = "command -v swift >/dev/null 2>&1 && swift sdk list 2>&1 | grep -qi darwin"
        }
        do {
            let status = try await vm.run(command, environment: nil) { _ in }
            return status == 0
        } catch {
            return false
        }
    }

    // MARK: - Getting files into the guest

    /// Copy the user's `Xcode.xip` into the guest's own storage and return the
    /// command that installs it there.
    ///
    /// The `.xip` is never unpacked on the host. The guest keeps the file in its
    /// own filesystem (`/root/xforge/xip`), and `xtool sdk install <path>` — run
    /// in the Terminal, where the user can watch it — does the extraction and the
    /// SDK post-processing inside Alpine. The returned string is the command to
    /// hand to `TerminalSession`.
    func installSDKFromXcode(xip: URL) async throws -> String {
        isInstalling = .sdk
        defer { isInstalling = nil }
        XForgeLog.prepare()
        let keepAwake = InstallAssertion.begin(reason: "stage Xcode.xip for the guest")
        defer { keepAwake.end() }
        beginProgress(.sdk)
        defer { endProgress() }

        try await vm.boot()
        activity = "Copying \(xip.lastPathComponent) into the guest…"
        let guestPath = try await SystemComponents.stageXIP(xip, in: vm) { [weak self] line in
            self?.advanceProgress(0.5, line)
            XForgeLog.note("sdk: \(line)")
        }
        activity = nil
        advanceProgress(1.0, "Ready to install inside the guest")
        message = "\(xip.lastPathComponent) is in the guest at \(guestPath). "
            + "Its install is running in the Terminal."
        return SystemComponents.darwinSDKInstallCommand(guestXIPPath: guestPath)
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

    // MARK: - Progress

    private func beginProgress(_ component: Component) {
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
        message = "Removed the imported rootfs, the staged SDK and downloads. "
            + "Quit and reopen XForge to boot a fresh guest."
    }
}

enum ToolchainError: LocalizedError {
    case sdkLayoutUnexpected
    case sdkInstallFailed(Int32, String)
    case notEnoughSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .sdkLayoutUnexpected:
            return "The downloaded Darwin SDK archive did not contain darwin.artifactbundle/info.json."
        case .sdkInstallFailed(let status, let output):
            return "`swift sdk install` failed inside the guest (exit \(status)). "
                + (output.isEmpty ? "See Settings → Diagnostics → Engine log." : String(output.suffix(400)))
        case .notEnoughSpace(let needed, let free):
            let formatter = ByteCountFormatter()
            return "Not enough free space: this needs about "
                + "\(formatter.string(fromByteCount: needed)) and "
                + "\(formatter.string(fromByteCount: free)) is free."
        }
    }
}
