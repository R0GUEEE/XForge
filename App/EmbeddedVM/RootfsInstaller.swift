import Foundation

/// Installs the bundled Alpine aarch64 root filesystem into the app container
/// the first time the guest boots.
///
/// The archive ships *inside the app* (see `project.yml` and
/// `EmbeddedLinux/fetch-rootfs.sh`), so nothing is downloaded after install. On
/// first use it is imported into iSH-AOK's `fakefs` format — a `data/` tree plus
/// a `meta.db` SQLite database — and every later launch reuses that root.
enum RootfsInstaller {
    /// Base name of the bundled archive (the exact file the user pointed at).
    static let archiveName = "alpine-minirootfs-3.23.3-aarch64"
    static let archiveExtension = "tar.xz"
    /// Directory name of the installed root inside `<Documents>/embedded-linux/roots`.
    static let rootName = "alpine"

    static func bundledArchiveURL() -> URL? {
        Bundle.main.url(forResource: archiveName, withExtension: archiveExtension)
    }

    static func installedRoot(in rootsDirectory: URL) -> URL {
        rootsDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    static func isInstalled(in rootsDirectory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: installedRoot(in: rootsDirectory).appendingPathComponent("meta.db").path)
    }

    /// Returns the ready-to-boot fakefs root, importing from the bundled archive
    /// the first time.
    @discardableResult
    static func installIfNeeded(into rootsDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let root = installedRoot(in: rootsDirectory)
        if fm.fileExists(atPath: root.appendingPathComponent("meta.db").path) {
            return root
        }

        guard let archive = bundledArchiveURL() else {
            throw RootfsError.archiveMissing(
                "\(archiveName).\(archiveExtension) is not bundled in the app. "
                + "Run EmbeddedLinux/fetch-rootfs.sh before building, or rebuild via CI.")
        }

        try fm.createDirectory(at: rootsDirectory, withIntermediateDirectories: true)

        // `fakefs_import` requires its destination not to exist, so import into a
        // staging directory and move it into place atomically afterwards.
        let staging = rootsDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: staging)

        let rc = archive.path.withCString { archivePath in
            staging.path.withCString { destPath in
                xf_ish_import_rootfs(archivePath, destPath)
            }
        }
        guard rc == 0 else {
            try? fm.removeItem(at: staging)
            let detail = String(cString: xf_ish_last_error())
            throw RootfsError.importFailed(detail.isEmpty ? "errno \(rc)" : detail)
        }

        try fm.moveItem(at: staging, to: root)
        return root
    }
}

enum RootfsError: LocalizedError {
    case archiveMissing(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveMissing(let m): return m
        case .importFailed(let m): return "Could not install the root filesystem: \(m)"
        }
    }
}
