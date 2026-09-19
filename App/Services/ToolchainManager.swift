import Foundation
import Combine

/// Manages the on-device build toolchain.
///
/// The pieces live in two places, and this type is careful to check the right one:
///
/// - **Alpine rootfs** — bundled inside the app and imported into iSH-AOK's fakefs
///   on first boot. Nothing is downloaded; "installing" it just performs the import.
/// - **Swift / xtool / darwin SDK** — inside the guest Linux, reached over the VM
///   bridge. Installing them runs the provisioning script in the guest (the SDK is
///   staged on the host and shared in at `/host`, since it is hundreds of MB).
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
            case .swift: return "Swift Linux toolchain (glibc, under gcompat)"
            case .xtool: return "xtool aarch64 binary"
            case .sdk: return "arm64-apple-ios Swift SDK"
            }
        }

        /// Whether the component lives inside the guest Linux (vs. on the host).
        var livesInGuest: Bool { self != .rootfs }
    }

    @Published private(set) var installed: Set<Component> = []
    @Published private(set) var isInstalling: Component?
    @Published private(set) var guestChecked = false
    @Published private(set) var activity: String?
    @Published var message: String?

    private let vm: LinuxVM

    /// Pinned xtool aarch64 AppImage (matches the XKit version in project.yml).
    static let xtoolDownloadURL = "https://github.com/xtool-org/xtool/releases/download/1.17.0/xtool-aarch64.AppImage"

    init(vm: LinuxVM? = nil) {
        self.vm = vm ?? XForgeEnvironment.makeVM()
    }

    func isInstalled(_ component: Component) -> Bool { installed.contains(component) }

    // MARK: - Status

    /// Refresh component status.
    ///
    /// Host-side facts are always checked. Guest-side components are only probed
    /// when `probeGuest` is true (or the guest is already running), because probing
    /// boots the embedded Linux — which imports the rootfs the first time.
    func refresh(probeGuest: Bool = false) async {
        var found: Set<Component> = []

        if RootfsInstaller.isInstalled(in: XForgeEnvironment.rootsDirectory) {
            found.insert(.rootfs)
        }

        if probeGuest || vm.isBooted {
            activity = vm.isBooted ? "Checking the embedded Linux…" : "Starting the embedded Linux…"
            defer { activity = nil }
            do {
                try await vm.boot()
                for component in [Component.swift, .xtool, .sdk] where await guestHas(component) {
                    found.insert(component)
                }
                guestChecked = true
            } catch {
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
        do {
            switch component {
            case .rootfs:
                activity = "Installing the bundled Alpine rootfs…"
                _ = try RootfsInstaller.installIfNeeded(into: XForgeEnvironment.rootsDirectory)
                message = "Alpine rootfs installed from the copy bundled in the app."

            case .swift, .xtool:
                activity = "Provisioning \(component.rawValue) inside the embedded Linux…"
                try await provisionGuest()

            case .sdk:
                activity = "Downloading the Darwin SDK…"
                try await installSDK()
            }
            activity = nil
            await refresh(probeGuest: true)
        } catch {
            activity = nil
            message = error.localizedDescription
        }
    }

    /// Run the in-guest provisioning script (Swift toolchain + xtool).
    private func provisionGuest() async throws {
        try await vm.boot()

        guard let script = Bundle.main.url(forResource: "install-toolchain", withExtension: "sh") else {
            throw ToolchainError.scriptMissing
        }
        let guestPath = "/root/install-toolchain.sh"
        try await vm.copyIn(hostURL: script, to: guestPath)

        let status = try await vm.run(
            "chmod +x \(guestPath) && sh \(guestPath)",
            environment: ["PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
        ) { _ in }
        guard status == 0 else {
            throw ToolchainError.provisioningFailed(status)
        }
        message = "Provisioned the Swift toolchain and xtool inside the embedded Linux."
    }

    /// Download the darwin Swift SDK, unzip it into the shared directory, and
    /// install it in the guest.
    private func installSDK() async throws {
        try await SDKInstaller.install(vm: vm) { [weak self] text in
            self?.activity = text
        }
        message = "Darwin SDK installed. `swift sdk list` now offers darwin."
    }

    // MARK: - Reset

    /// Remove the imported rootfs, the staged SDK and downloaded archives.
    func reset() async {
        isInstalling = nil
        activity = nil
        let fm = FileManager.default
        try? fm.removeItem(at: XForgeEnvironment.rootsDirectory)
        try? fm.removeItem(at: XForgeEnvironment.hostShareDirectory.appendingPathComponent("darwin.artifactbundle"))
        try? fm.removeItem(at: XForgeEnvironment.downloadsDirectory)
        installed = []
        guestKnown = []
        guestChecked = false
        message = "Removed the imported rootfs, the staged SDK and downloads. "
            + "Quit and reopen XForge to boot a fresh guest."
    }
}

enum ToolchainError: LocalizedError {
    case scriptMissing
    case provisioningFailed(Int32)
    case sdkLayoutUnexpected
    case sdkInstallFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return "install-toolchain.sh is not bundled in the app."
        case .provisioningFailed(let status):
            return "In-guest provisioning failed (exit \(status)). The guest needs network access "
                + "to fetch the Swift toolchain; open the Terminal and run "
                + "`sh /root/install-toolchain.sh` to see the full output."
        case .sdkLayoutUnexpected:
            return "The downloaded Darwin SDK archive did not contain darwin.artifactbundle/info.json."
        case .sdkInstallFailed(let status):
            return "`swift sdk install` failed inside the guest (exit \(status))."
        }
    }
}
