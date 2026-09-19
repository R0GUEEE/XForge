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
///
/// Everything heavy here happens off the main thread. The archive is 456 MB and
/// expands to about 1.4 GB; doing that inline (which is what the first version of
/// this did) freezes the app for minutes, and iOS kills an app that stays
/// unresponsive like that rather than politely waiting for it.
@MainActor
enum SDKInstaller {
    static let bundledDirectoryName = "darwin.artifactbundle"

    /// Free space the unpacked bundle needs, with room to spare.
    static let requiredFreeBytes: Int64 = 2_000_000_000

    /// Resolve → download → unpack → `swift sdk install` in the guest.
    /// Returns the unpacked bundle on the host.
    @discardableResult
    static func install(
        vm: LinuxVM,
        report: (String) -> Void = { _ in }
    ) async throws -> URL {
        report("Resolving the latest darwin SDK release…")
        let url = try await XForgeReleases.darwinSDKURL()
        XForgeLog.note("sdk: resolved \(url.absoluteString)")

        let archive = XForgeEnvironment.downloadsDirectory
            .appendingPathComponent(url.lastPathComponent)
        report("Downloading \(url.lastPathComponent)…")
        try await DownloadManager.download(url, to: archive) { _ in }
        let archiveSize = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int ?? 0
        XForgeLog.note("sdk: downloaded \(archiveSize) bytes")

        let shared = XForgeEnvironment.hostShareDirectory
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let bundle = shared.appendingPathComponent(bundledDirectoryName, isDirectory: true)

        // Fail with an explanation rather than a half-unpacked SDK: running out
        // of disk mid-unzip leaves a bundle that looks installed to `swift sdk
        // install` and fails much later, during a build.
        let free = XForgeEnvironment.availableBytes
        if free > 0, free < requiredFreeBytes {
            throw ToolchainError.notEnoughSpace(needed: requiredFreeBytes, free: free)
        }

        report("Unpacking the SDK (about 1.4 GB — this takes a while)…")
        XForgeLog.note("sdk: unpacking into \(shared.path)")
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.removeItem(at: bundle)
            try fm.unzipItem(at: archive, to: shared)
        }.value
        XForgeLog.note("sdk: unpacked")

        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("info.json").path) else {
            throw ToolchainError.sdkLayoutUnexpected
        }
        // The archive has done its job and is the largest single file in the
        // container; the unpacked bundle is what the guest installs from.
        try? FileManager.default.removeItem(at: archive)

        report("Installing the SDK inside the embedded Linux…")
        XForgeLog.note("sdk: swift sdk install /host/\(bundledDirectoryName)")
        try await vm.boot()
        let status = try await vm.run(
            "swift sdk install /host/\(bundledDirectoryName)",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw ToolchainError.sdkInstallFailed(status) }
        XForgeLog.note("sdk: installed in the guest")
        return bundle
    }
}
