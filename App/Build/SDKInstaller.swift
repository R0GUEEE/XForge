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
/// Everything heavy happens off the main thread, and every stage reports a
/// fraction: the archive is 456 MB and expands to about 1.4 GB, which is minutes
/// of work with nothing else to show for it.
@MainActor
enum SDKInstaller {
    static let bundledDirectoryName = "darwin.artifactbundle"

    /// Free space the unpacked bundle needs, with room to spare.
    static let requiredFreeBytes: Int64 = 2_000_000_000

    /// Resolve → download → unpack → `swift sdk install` in the guest.
    /// `advance` reports (fraction, what is happening) for the progress bar. It is
    /// called only from the main actor, between stages, because the engine returns
    /// a guest command's output only when it finishes and a byte-level callback
    /// would have to cross isolation domains to be useful.
    @discardableResult
    static func install(
        vm: LinuxVM,
        advance: (Double, String) -> Void
    ) async throws -> URL {
        advance(0.02, "Resolving the latest darwin SDK release…")
        let url = try await XForgeReleases.darwinSDKURL()
        XForgeLog.note("sdk: resolved \(url.absoluteString)")

        let archive = XForgeEnvironment.downloadsDirectory
            .appendingPathComponent(url.lastPathComponent)
        // The download is the longest single stage, and the one that has actually
        // failed on a device ("The network connection was lost"), so it gets the
        // biggest share of the bar and real byte progress.
        advance(0.05, "Downloading \(url.lastPathComponent) (about 456 MB)…")
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

        advance(0.62, "Unpacking the SDK (about 1.4 GB — this takes a while)…")
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
        try? FileManager.default.removeItem(at: archive)

        advance(0.9, "Installing the SDK inside the embedded Linux…")
        XForgeLog.note("sdk: swift sdk install /host/\(bundledDirectoryName)")
        try await vm.boot()
        let status = try await vm.run(
            "swift sdk install /host/\(bundledDirectoryName)",
            environment: nil
        ) { chunk in
            XForgeLog.note("guest: " + chunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard status == 0 else { throw ToolchainError.sdkInstallFailed(status) }
        advance(1.0, "Done")
        XForgeLog.note("sdk: installed in the guest")
        return bundle
    }
}
