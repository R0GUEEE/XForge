import Foundation

/// Installs the Darwin Swift SDK entirely inside the embedded Alpine rootfs.
///
/// iOS resolves release metadata and displays progress, but the archive download,
/// extraction, validation, and Swift SDK installation are Linux commands. Temporary
/// files live under /root/.cache and the installed SDK lives in SwiftPM's guest-side
/// SDK directory; /host is never used as an installation location.
@MainActor
enum SDKInstaller {
    static let guestCacheDirectory = "/root/.cache/xforge-sdk"
    static let guestBundlePath = guestCacheDirectory + "/darwin.artifactbundle"

    /// Conservative free-space requirement for the archive, expanded bundle, and
    /// installed copy. The fakefs root lives in the app container, so host capacity
    /// is also the capacity available to Alpine.
    static let requiredFreeBytes: Int64 = 2_000_000_000

    static func install(
        vm: LinuxVM,
        remoteURL: URL? = nil,
        advance: (Double, String) -> Void
    ) async throws {
        advance(0.02, "Checking the Alpine Swift SDK installation…")
        try await vm.boot()

        let alreadyInstalled = try await vm.run(
            "swift sdk list 2>&1 | grep -qi darwin",
            environment: nil
        ) { _ in }
        if alreadyInstalled == 0 {
            advance(1.0, "Darwin SDK is already installed in Alpine")
            XForgeLog.note("sdk: darwin is already installed in the guest rootfs")
            return
        }

        let free = XForgeEnvironment.availableBytes
        if free > 0, free < requiredFreeBytes {
            throw ToolchainError.notEnoughSpace(needed: requiredFreeBytes, free: free)
        }

        advance(0.05, "Resolving the latest Darwin SDK release…")
        let url: URL
        if let remoteURL {
            url = remoteURL
        } else {
            url = try await XForgeReleases.darwinSDKURL()
        }
        XForgeLog.note("sdk: Alpine will download \(url.absoluteString)")

        let archiveName = url.lastPathComponent.isEmpty ? "darwin-sdk.zip" : url.lastPathComponent
        let archivePath = guestCacheDirectory + "/" + archiveName
        let script = """
        set -eu
        cache=\(GuestShell.quote(guestCacheDirectory))
        archive=\(GuestShell.quote(archivePath))
        bundle=\(GuestShell.quote(guestBundlePath))

        command -v curl >/dev/null 2>&1
        command -v unzip >/dev/null 2>&1
        command -v swift >/dev/null 2>&1

        mkdir -p "$cache"
        rm -f "$archive"
        rm -rf "$bundle"

        echo "Downloading Darwin SDK inside Alpine..."
        curl -fL --retry 3 --progress-bar \
            \(GuestShell.quote(url.absoluteString)) -o "$archive"

        echo "Extracting Darwin SDK inside the rootfs..."
        unzip -q "$archive" -d "$cache"
        test -f "$bundle/info.json"

        echo "Installing Darwin SDK into the Alpine SwiftPM store..."
        swift sdk install "$bundle"

        rm -f "$archive"
        rm -rf "$bundle"
        swift sdk list
        """

        advance(0.1, "Downloading and installing the SDK inside Alpine…")
        let output = OutputCollector()
        let status = try await vm.run(script, environment: nil) { chunk in
            output.append(chunk)
            let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                XForgeLog.note("guest: " + text)
            }
        }
        guard status == 0 else {
            let tail = output.tail
            if tail.contains("info.json") {
                throw ToolchainError.sdkLayoutUnexpected
            }
            throw ToolchainError.sdkInstallFailed(status)
        }

        let verified = try await vm.run(
            "swift sdk list 2>&1 | grep -qi darwin",
            environment: nil
        ) { _ in }
        guard verified == 0 else {
            throw ToolchainError.sdkInstallFailed(verified)
        }

        advance(1.0, "Darwin SDK installed in Alpine")
        XForgeLog.note("sdk: installed and verified in the guest rootfs")
    }
}
