import Foundation

/// Recursive on-disk size of a directory.
///
/// Deliberately a plain `nonisolated` function so callers can run it off the main
/// actor: walking the imported rootfs is tens of thousands of file stats, and doing
/// that during a SwiftUI `body` evaluation can freeze — or watchdog-kill — the app.
enum DirectorySize {
    static func bytes(at url: URL, limit: Int = 400_000) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }
        // No `.skipsHiddenFiles`: in the guest rootfs the interesting things *are*
        // hidden — the Swift toolchain is /root/.local/share/swiftly, the SDK is
        // /root/.swiftpm/swift-sdks, the caches are /root/.cache — so skipping
        // hidden entries reported a few MB for a download that is several GB, and
        // reported almost none of the rootfs's own size. (Symlinks are not
        // followed by this enumerator, so counting them cannot loop.)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > limit { break }
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
