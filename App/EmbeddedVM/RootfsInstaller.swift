import Foundation
import ZIPFoundation

/// Installs the bundled Alpine aarch64 root filesystem into the app container
/// ahead of first use — at launch, with the first boot as the fallback.
///
/// The archive ships *inside the app*, so nothing is downloaded after install.
///
/// **The archive is already a fakefs**, not a plain tarball: it contains a
/// `data/` tree and a `meta.db` SQLite database, converted on the build machine
/// by the engine's own `tools/fakefsify` (see `EmbeddedLinux/build-rootfs.sh`).
/// That is deliberate, and it is what the engine's reference implementation does:
/// the conversion touches thousands of files, and doing it here means first
/// launch is a plain unzip instead of a multi-minute import on a phone.
///
/// The root is a full Alpine userspace. The published root also carries the build
/// toolchain — xtool, swiftly, the Swift toolchain and the Darwin SDK — installed
/// at build time by `EmbeddedLinux/install-toolchain.sh`, run in a chroot of the
/// root before the fakefs conversion (see `EmbeddedLinux/build-rootfs.sh`). A root
/// built without it (`XFORGE_PROVISION=none`) is provisioned *by the guest*
/// instead, on demand, with the same script — see the Toolkit screen.
enum RootfsInstaller {
    /// The ZIP of the pre-converted fakefs, built by `EmbeddedLinux/build-rootfs.sh`.
    static let archiveName = "alpine-rootfs"
    static let archiveExtension = "zip"

    /// Directory name of the installed root inside `<Documents>/embedded-linux/roots`.
    /// The Alpine version is in the name so a distribution bump starts clean.
    static let rootName = "alpine-3.21"

    /// Roots from earlier layouts that must not be reused. XForge used to import a
    /// tarball at runtime (`alpine-3.24.2`) and, before that, a different root
    /// entirely (`alpine`). They are removed only once the replacement is valid.
    static let legacyRootNames = ["alpine", "alpine-3.24.2", "alpine-3.23.3"]

    /// The ZIP holds `alpine-rootfs/` at its top level (the builder packs the
    /// directory, so the paths are relative and unzip into Documents directly).
    private static let archiveEntryPrefix = "alpine-rootfs"

    /// The manifest the builder writes into every root, relative to `data/`.
    /// Its `stamp:` line names the revision — see `EmbeddedLinux/build-rootfs.sh`.
    private static let manifestPath = "usr/local/share/xforge/rootfs-manifest.txt"

    static func bundledArchiveURL() -> URL? {
        Bundle.main.url(forResource: archiveName, withExtension: archiveExtension)
    }

    /// Whether the installed root is a different revision from the one bundled in
    /// this build of the app, and therefore has to be replaced.
    ///
    /// Only a root that carries a manifest — which is every root XForge has ever
    /// installed itself — can be compared, so anything unidentified is left in
    /// place rather than replaced by something that might be worse.
    private static func installedRootIsStale(_ root: URL) -> Bool {
        let manifest = root.appendingPathComponent("data/\(manifestPath)")
        guard let installed = stamp(inManifestAt: manifest) else { return false }
        guard let bundled = bundledStamp() else { return false }
        return installed != bundled
    }

    /// The revision named by the manifest inside the bundled ZIP, read straight
    /// out of the archive so asking the question costs no unpacking.
    private static func bundledStamp() -> String? {
        guard let archiveURL = bundledArchiveURL(),
              let zip = try? Archive(url: archiveURL, accessMode: .read),
              let entry = zip["\(archiveEntryPrefix)/\(manifestPath)"] else {
            return nil
        }
        var contents = Data()
        guard (try? zip.extract(entry, consumer: { contents.append($0) })) != nil else {
            return nil
        }
        guard let text = String(data: contents, encoding: .utf8) else { return nil }
        return stamp(inManifestText: text)
    }

    private static func stamp(inManifestAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return stamp(inManifestText: text)
    }

    private static func stamp(inManifestText text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("stamp:") {
            let value = line.dropFirst("stamp:".count)
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func installedRoot(in rootsDirectory: URL) -> URL {
        rootsDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    /// A root is usable when both halves of the fakefs are present and non-empty:
    /// the `data/` tree and the `meta.db` database that indexes it.
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

    /// Returns the ready-to-boot fakefs root, unpacking the bundled archive the
    /// first time — or when the bundled archive is a newer revision than the one
    /// already installed.
    @discardableResult
    static func installIfNeeded(into rootsDirectory: URL,
                                progress: RootfsImportProgress? = nil) throws -> URL {
        let root = installedRoot(in: rootsDirectory)
        if isInstalled(in: rootsDirectory) {
            if installedRootIsStale(root) {
                // The guest's own setup lives in the root — its /etc/inittab, its
                // default shell, its profile. Without this check, a device that
                // had booted once would keep the first root it ever installed and
                // never see any of that change.
                XForgeLog.note("rootfs: the installed root is not the bundled revision; reinstalling")
            } else {
                removeLegacyRoots(in: rootsDirectory, fileManager: .default)
                return root
            }
        }

        guard let archive = bundledArchiveURL() else {
            throw RootfsError.archiveMissing(
                "No Alpine rootfs is bundled in the app (looked for "
                + "\(archiveName).\(archiveExtension)). Run EmbeddedLinux/build-rootfs.sh "
                + "before building, or rebuild via CI.")
        }

        XForgeLog.note("rootfs: unpacking the bundled \(archive.lastPathComponent)")
        return try install(archive: archive, into: rootsDirectory, progress: progress)
    }

    /// Unpack a rootfs ZIP. The existing root is retained until the new archive
    /// has completely unpacked and passed fakefs validation.
    ///
    /// `progress` is called from the unpacking thread with a 0..1 fraction.
    @discardableResult
    static func install(archive: URL, into rootsDirectory: URL,
                        progress: RootfsImportProgress? = nil) throws -> URL {
        let fm = FileManager.default
        let root = installedRoot(in: rootsDirectory)
        guard archive.pathExtension.lowercased() == archiveExtension else {
            throw RootfsError.importFailed(
                "Choose an \(archiveName).\(archiveExtension) rootfs archive.")
        }

        try fm.createDirectory(at: rootsDirectory, withIntermediateDirectories: true)

        // Unpack into a staging directory and move it into place afterwards, so a
        // failure part-way cannot leave a half-populated root that later looks
        // installed. (The old import path needed the same care; an interrupted
        // staging directory is as large as the whole root filesystem.)
        let staging = rootsDirectory.appendingPathComponent(
            ".import-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        progress?.report(fraction: 0, message: "Opening \(archive.lastPathComponent)")

        guard let zip = try? Archive(url: archive, accessMode: .read) else {
            try? fm.removeItem(at: staging)
            throw RootfsError.importFailed(
                "\(archive.lastPathComponent) could not be opened — it is not a readable ZIP.")
        }

        // ZIPFoundation walks entries in order; progress is entry count, which is
        // the honest denominator here (entries are small and uniform enough).
        let entries = Array(zip)
        let total = max(entries.count, 1)
        var index = 0

        for entry in entries {
            index += 1
            // Strip the leading `alpine-rootfs/` so the ZIP unpacks to
            // `staging/data`, `staging/meta.db` — the layout `mount_root` wants.
            let relative = stripArchivePrefix(entry.path)
            if relative.isEmpty { continue }
            let destination = staging.appendingPathComponent(relative)

            do {
                if entry.type == .directory {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                // `.overwrite` keeps a re-unpack into a dirty staging dir honest.
                _ = try zip.extract(entry, to: destination, skipCRC32: false)
            } catch {
                try? fm.removeItem(at: staging)
                throw RootfsError.importFailed(
                    "unpacking \(relative) failed: \(error.localizedDescription)")
            }

            if index % 64 == 0 || index == total {
                progress?.report(fraction: Double(index) / Double(total), message: relative)
            }
        }

        guard isValidImportedRoot(staging, fileManager: fm) else {
            try? fm.removeItem(at: staging)
            throw RootfsError.importFailed(
                "the unpacked rootfs is missing its data directory or metadata database")
        }

        // Safe to remove the old root only now: `staging` has already passed
        // validation, so a failure cannot leave the app with no root at all.
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.moveItem(at: staging, to: root)
        removeLegacyRoots(in: rootsDirectory, fileManager: fm)
        progress?.report(fraction: 1, message: nil)
        XForgeLog.note("rootfs: ready at \(root.lastPathComponent)")
        return root
    }

    /// Drops the builder's top-level directory from an archive entry path.
    private static func stripArchivePrefix(_ path: String) -> String {
        var relative = path
        let prefix = archiveEntryPrefix + "/"
        if relative == archiveEntryPrefix { return "" }
        if relative.hasPrefix(prefix) {
            relative.removeFirst(prefix.count)
        }
        return relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func removeLegacyRoots(in rootsDirectory: URL, fileManager fm: FileManager) {
        for name in legacyRootNames where name != rootName {
            let stale = rootsDirectory.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: stale.path) {
                XForgeLog.note("rootfs: removing the superseded \(name) root")
                try? fm.removeItem(at: stale)
            }
        }
    }

    /// Validates an unpacked fakefs: the `data/` tree plus a non-empty `meta.db`.
    private static func isValidImportedRoot(_ directory: URL, fileManager fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.appendingPathComponent("data").path,
                            isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let metadata = directory.appendingPathComponent("meta.db")
        guard fm.fileExists(atPath: metadata.path),
              let attributes = try? fm.attributesOfItem(atPath: metadata.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return false
        }
        return true
    }

    enum RootfsError: LocalizedError {
        case archiveMissing(String)
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .archiveMissing(let detail): return detail
            case .importFailed(let detail): return detail
            }
        }
    }
}

/// Reports the progress of a rootfs unpack.
///
/// Deliberately a plain `@unchecked Sendable` type and NOT a `@MainActor` one:
/// it is called from the unpacking thread, and a main-actor type cannot be
/// referenced from a non-isolated closure under Swift 6's strict concurrency.
/// `report` does its own hop if the caller needs one.
final class RootfsImportProgress: @unchecked Sendable {
    /// One update per this much progress.
    private static let step = 0.005

    private let lock = NSLock()
    private var lastPublished: Double = -1
    private let onUpdate: @Sendable (Double, String?) -> Void

    init(onUpdate: @escaping @Sendable (Double, String?) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Called from the unpacking thread. `fraction` is clamped to 0...1.
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
