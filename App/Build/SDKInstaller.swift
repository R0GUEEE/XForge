import Foundation
import ZIPFoundation

/// Installs the `darwin` Swift SDK into the embedded Linux.
///
/// The bundle is published under XForge's own `darwin-sdk-*` release series, so it
/// is resolved through the GitHub API (`releases/latest/download/…` does not find
/// it — `latest` points at the newest release of any kind). It is downloaded on
/// the host, unpacked into the directory shared with the guest at `/host`, and
/// installed there with `swift sdk install`: the bundle is hundreds of megabytes,
/// so it never travels through the guest command pipe.
@MainActor
enum SDKInstaller {
    static let bundledDirectoryName = "darwin.artifactbundle"

    /// Resolve → download → unpack → `swift sdk install` in the guest.
    /// Returns the unpacked bundle on the host.
    @discardableResult
    static func install(
        vm: LinuxVM,
        report: (String) -> Void = { _ in }
    ) async throws -> URL {
        report("Resolving the latest darwin SDK release…")
        let url = try await XForgeReleases.darwinSDKURL()

        report("Downloading \(url.lastPathComponent)…")
        let archive = XForgeEnvironment.downloadsDirectory
            .appendingPathComponent(url.lastPathComponent)
        try await DownloadManager.download(url, to: archive) { _ in }

        report("Unpacking the SDK…")
        let shared = XForgeEnvironment.hostShareDirectory
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let bundle = shared.appendingPathComponent(bundledDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.unzipItem(at: archive, to: shared)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("info.json").path) else {
            throw ToolchainError.sdkLayoutUnexpected
        }

        report("Installing the SDK inside the embedded Linux…")
        try await vm.boot()
        let status = try await vm.run(
            "swift sdk install /host/\(bundledDirectoryName)",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw ToolchainError.sdkInstallFailed(status) }
        return bundle
    }
}
