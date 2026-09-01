import Foundation
import Combine
import ZIPFoundation

/// Manages the on-device build toolchain: probes what's installed on disk and offers
/// install actions for missing pieces. The Darwin SDK can be installed on the host
/// (download + unzip); the embedded Linux / Swift / xtool live in the guest and will
/// install via the VM bridge once it's wired.
@MainActor
final class ToolchainManager: ObservableObject {
    enum Component: String, CaseIterable, Identifiable {
        case linux = "Embedded Linux"
        case swift = "Swift Toolchain"
        case xtool = "xtool"
        case sdk = "Darwin SDK"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .linux: return "apple.terminal"
            case .swift: return "swift"
            case .xtool: return "hammer"
            case .sdk: return "externaldrive.connected.to.line.below"
            }
        }
    }

    @Published private(set) var installed: Set<Component> = []
    @Published private(set) var isInstalling: Component?
    @Published var message: String?

    func refresh() {
        var set: Set<Component> = []
        if exists("etc/alpine-release") { set.insert(.linux) }
        if exists("opt/usr/bin/swift") { set.insert(.swift) }
        if exists("usr/local/bin/xtool") { set.insert(.xtool) }
        if exists("opt/darwin.artifactbundle/info.json") { set.insert(.sdk) }
        installed = set
    }

    func isInstalled(_ component: Component) -> Bool {
        installed.contains(component)
    }

    func install(_ component: Component) async {
        isInstalling = component
        defer { isInstalling = nil }
        do {
            switch component {
            case .sdk:
                message = "Downloading Darwin SDK…"
                try await installSDK()
                message = "Darwin SDK installed."
            case .linux, .swift, .xtool:
                message = "\(component.rawValue) installs inside the embedded Linux once the VM bridge is connected."
            }
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - SDK (host-side)

    private func installSDK() async throws {
        let url = URL(string: "https://github.com/R0GUEEE/XForge/releases/latest/download/darwin.artifactbundle.zip")!
        let dest = XForgeEnvironment.embeddedRoot.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("darwin.artifactbundle.zip")
        try? FileManager.default.removeItem(at: tmp)

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ToolchainError.downloadFailed
        }
        try data.write(to: tmp)

        let sdkDir = dest.appendingPathComponent("darwin.artifactbundle")
        try? FileManager.default.removeItem(at: sdkDir)
        try FileManager.default.unzipItem(at: tmp, to: dest)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func exists(_ subpath: String) -> Bool {
        let root = XForgeEnvironment.embeddedRoot
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(subpath).path)
    }
}

enum ToolchainError: LocalizedError {
    case downloadFailed
    var errorDescription: String? { "Failed to download the Darwin SDK." }
}
