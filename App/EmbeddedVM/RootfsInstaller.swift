import Foundation

/// Reports the progress of a rootfs import.
///
/// `fakefs_import` calls back once per archive entry — thousands of times — from
/// its own thread, so this must be cheap to call and must do its own hop to the
/// main actor rather than making the importer wait on one.
///
/// Deliberately a plain `@unchecked Sendable` type and NOT a `@MainActor` one:
/// the callback arrives from inside a `@Sendable` C closure, and a main-actor
/// type cannot be referenced from one at all under Swift 6's strict concurrency
/// (that is a compile error, not a warning).
final class RootfsImportProgress: @unchecked Sendable {
    /// One update per this much progress. The raw callback fires per entry, so
    /// unthrottled it would publish tens of thousands of updates and swamp the
    /// main queue while the import is trying to read gigabytes.
    private static let step = 0.005

    private let lock = NSLock()
    private var lastPublished: Double = -1
    private let onUpdate: @Sendable (Double, String?) -> Void

    init(onUpdate: @escaping @Sendable (Double, String?) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Called from the importing thread. `fraction` is clamped to 0...1.
    func report(fraction: Double, message: String?) {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        lock.lock()
        // Always let the final update through, so the row can reach 100%.
        let isLast = clamped >= 1
        if !isLast && clamped - lastPublished < Self.step {
            lock.unlock()
            return
        }
        lastPublished = clamped
        lock.unlock()
        onUpdate(clamped, message)
    }
}

/// Boxes the progress reporter for the C callback's `void *` cookie.
///
/// The reporter is held here rather than passed directly so the callback can
/// recover it with an unmanaged pointer, and so the lifetime is explicit at the
/// call site (the C side only borrows it for the duration of the import).
final class ProgressBox {
    let progress: RootfsImportProgress?

    init(_ progress: RootfsImportProgress?) {
        self.progress = progress
    }

    var pointer: UnsafeMutableRawPointer? {
        progress == nil ? nil : Unmanaged.passUnretained(self).toOpaque()
    }
}

/// C trampoline for `fakefs_import`'s progress callback.
private func xfImportProgressCallback(
    cookie: UnsafeMutableRawPointer?,
    fraction: Double,
    message: UnsafePointer<CChar>?
) -> Int32 {
    guard let cookie else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(cookie).takeUnretainedValue()
    guard let progress = box.progress else { return 0 }
    progress.report(fraction: fraction, message: message.map { String(cString: $0) })
    return 0
}

/// Installs the bundled Alpine aarch64 root filesystem into the app container
/// ahead of first use — at launch, with the first boot as the fallback.
///
/// The archive ships *inside the app* (see `project.yml` and
/// `EmbeddedLinux/fetch-rootfs.sh`), so nothing is downloaded after install. On
/// first use it is imported into the engine's `fakefs` format — a `data/` tree
/// plus a `meta.db` SQLite database — and every later launch reuses that root.
///
/// The import is the slow part of a first launch (the payload is hundreds of
/// megabytes), so `install(archive:into:progress:)` reports it: `fakefs_import`
/// calls back once per archive entry, and `RootfsImportProgress` throttles that
/// into something a progress row can follow.
enum RootfsInstaller {
    /// Base name of the bundled archive. This is built from Alpine's minirootfs
    /// with XForge's guest build dependencies and toolchain installed.
    static let archiveName = "alpine-minirootfs-3.24.2-aarch64-provisioned"
    static let archiveExtension = "tar.gz"
    /// Directory name of the installed root inside `<Documents>/embedded-linux/roots`.
    static let rootName = "alpine-3.24.2"
    /// Roots from releases that must not be reused after the base distribution
    /// changes. They are removed only after the replacement root is valid.
    static let legacyRootNames = ["alpine"]

    /// XForge boots the provisioned Alpine userspace shipped in the app. The
    /// payload is imported directly into the embedded terminal's fakefs, so
    /// installed components never target the iOS host filesystem.
    static let bundledArchiveNames = [
        archiveName,
    ]

    static func bundledArchiveURL() -> URL? {
        for name in bundledArchiveNames {
            if let url = Bundle.main.url(forResource: name, withExtension: archiveExtension) {
                return url
            }
        }
        return nil
    }

    static func installedRoot(in rootsDirectory: URL) -> URL {
        rootsDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    static func isInstalled(in rootsDirectory: URL) -> Bool {
        let fm = FileManager.default
        let root = installedRoot(in: rootsDirectory)
        let metadata = root.appendingPathComponent("meta.db")
        let data = root.appendingPathComponent("data", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: data.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.fileExists(atPath: metadata.path),
              let attributes = try? fm.attributesOfItem(atPath: metadata.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return false
        }
        return true
    }

    /// Returns the ready-to-boot fakefs root, importing from the bundled archive
    /// the first time.
    @discardableResult
    static func installIfNeeded(into rootsDirectory: URL,
                                progress: RootfsImportProgress? = nil) throws -> URL {
        let root = installedRoot(in: rootsDirectory)
        if isInstalled(in: rootsDirectory) {
            removeLegacyRoots(in: rootsDirectory, fileManager: .default)
            return root
        }

        guard let archive = bundledArchiveURL() else {
            throw RootfsError.archiveMissing(
                "No Alpine rootfs is bundled in the app (looked for "
                + bundledArchiveNames.map { "\($0).\(archiveExtension)" }.joined(separator: ", ")
                + "). Run EmbeddedLinux/fetch-rootfs.sh before building, or rebuild via CI.")
        }

        XForgeLog.note("rootfs: importing the bundled \(archive.lastPathComponent)")
        return try install(archive: archive, into: rootsDirectory, progress: progress)
    }

    /// Import a user-selected rootfs archive. The existing root is retained until
    /// the new archive has completely imported and passed fakefs validation.
    ///
    /// `progress` is called from the importing thread with a 0..1 fraction and
    /// the archive entry being unpacked, and may be called very often.
    @discardableResult
    static func install(archive: URL, into rootsDirectory: URL,
                        progress: RootfsImportProgress? = nil) throws -> URL {
        let fm = FileManager.default
        let root = installedRoot(in: rootsDirectory)
        guard archive.pathExtension.lowercased() == "gz" else {
            throw RootfsError.importFailed("Choose an Alpine .tar.gz minirootfs archive.")
        }

        try fm.createDirectory(at: rootsDirectory, withIntermediateDirectories: true)

        // `fakefs_import` requires its destination not to exist, so import into a
        // staging directory and move it into place atomically afterwards.
        let staging = rootsDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)

        let box = ProgressBox(progress)
        let rc = archive.path.withCString { archivePath in
            staging.path.withCString { destPath in
                xf_ish_import_rootfs(archivePath, destPath, xfImportProgressCallback, box.pointer)
            }
        }
        withExtendedLifetime(box) {}
        guard rc == 0 else {
            try? fm.removeItem(at: staging)
            let detail = String(cString: xf_ish_last_error())
            throw RootfsError.importFailed(detail.isEmpty ? "errno \(rc)" : detail)
        }
        guard isValidImportedRoot(staging, fileManager: fm) else {
            try? fm.removeItem(at: staging)
            throw RootfsError.importFailed(
                "the imported fakefs is missing its data directory or metadata database")
        }

        // A stale partial import may exist even when `isInstalled` is false. It
        // is safe to remove only now: `staging` has already passed validation.
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.moveItem(at: staging, to: root)
        removeLegacyRoots(in: rootsDirectory, fileManager: fm)
        return root
    }

    private static func removeLegacyRoots(in rootsDirectory: URL, fileManager fm: FileManager) {
        for name in legacyRootNames where name != rootName {
            let legacy = rootsDirectory.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            do {
                try fm.removeItem(at: legacy)
                XForgeLog.note("rootfs: removed legacy root \(name)")
            } catch {
                XForgeLog.note("rootfs: could not remove legacy root \(name): \(error.localizedDescription)")
            }
        }
    }

    private static func isValidImportedRoot(_ root: URL, fileManager fm: FileManager) -> Bool {
        let metadata = root.appendingPathComponent("meta.db")
        let data = root.appendingPathComponent("data", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: data.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.fileExists(atPath: metadata.path),
              let attributes = try? fm.attributesOfItem(atPath: metadata.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
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
