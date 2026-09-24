import Foundation

/// Application-level wiring: where the app's directories are, how a build executor
/// is constructed for a project, and where staged artifacts land.
@MainActor
enum XForgeEnvironment {
    /// App sandbox root.
    ///
    /// `nonisolated`: it is a pure lookup in `FileManager`, and the native
    /// toolchain path (`NativeSDK`, which runs off the main actor) resolves
    /// sandbox directories while compiling. Same for `nativeSDKDirectory`.
    nonisolated static var documentDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Host-side downloads (SDK archives, toolchain bundles).
    static var downloadsDirectory: URL {
        documentDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// Host-side Darwin SDK used by the native compiler path.
    nonisolated static var nativeSDKDirectory: URL {
        documentDirectory.appendingPathComponent("native-sdk", isDirectory: true)
    }

    /// Projects live in the app's own container.
    ///
    /// They used to live inside the embedded Linux filesystem (`/root/projects`),
    /// which is why `Project.rootPath` still carries a guest-shaped string. Now
    /// that the toolchain runs in-process, a project is a directory of files this
    /// process can open, and this is the one place that decides where.
    nonisolated static var projectsDirectory: URL {
        documentDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    /// Diagnostics (`XForgeLog` writes the engine log here).
    static var logsDirectory: URL { XForgeLog.directory }

    /// Where build artifacts are staged before export.
    static var stagingDirectory: URL {
        documentDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    /// Free space in the app's container, in bytes (0 when it cannot be read).
    static var availableBytes: Int64 {
        let values = try? documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Create the app's own directories and keep what should not be backed up out
    /// of iCloud backup.
    ///
    /// Everything XForge generates lives in `Documents`, which iOS backs up and
    /// (because the app declares `UIFileSharingEnabled`) shows in the Files app.
    /// Backing up gigabytes of downloaded or regenerable data is exactly what the
    /// iOS data storage guidelines forbid — it bloats every backup and can get an
    /// app rejected — so:
    ///
    ///  - the downloads, the staged artifacts and the log are excluded: each is
    ///    produced again by downloading, rebuilding or running.
    ///
    /// Projects are *not* excluded. They used to be inside the guest filesystem,
    /// which had to be kept out of backup as a whole and took the user's work with
    /// it; now that they are plain directories in the container, they are backed up
    /// like any other document.
    static func prepareStorage() {
        let fm = FileManager.default
        let excluded = [downloadsDirectory, nativeSDKDirectory, stagingDirectory, logsDirectory]
        for directory in excluded {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
        }
        // Exports are the user's work leaving the app, so they are left alone:
        // backed up, and visible in the Files app.
        try? fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
    }

    /// Where `ProjectExporter` writes project archives (`<Documents>/exports`).
    /// Kept here rather than in the exporter so the storage rules live in one file.
    ///
    /// `nonisolated` like `documentDirectory`: `ProjectExporter` is a plain enum and
    /// forwards this path, so isolating it here made that forwarding a concurrency
    /// error (surfaced by the unit-test build).
    nonisolated static var exportsDirectory: URL {
        documentDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    /// Best-effort: a container that refuses the flag is not a reason to fail
    /// anything the user asked for, and the flag is re-applied on every launch.
    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        do {
            try mutable.setResourceValues(values)
        } catch {
            XForgeLog.note("storage: could not exclude \(url.lastPathComponent) from backup: \(error.localizedDescription)")
        }
    }

    /// List built `.ipa` artifacts currently staged for export/install.
    static func stagedArtifacts() -> [BuildArtifact] {
        let dir = stagingDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "ipa" }
            .compactMap { url -> BuildArtifact? in
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                    return nil
                }
                return BuildArtifact(url: url, name: url.lastPathComponent, size: Int64(size), date: date)
            }
            .sorted { $0.date > $1.date }
    }

    /// Construct the build executor: the toolchain linked into this process.
    ///
    /// There is exactly one implementation now. It used to choose between the
    /// embedded Linux and a "remote" backend that never existed; both the choice
    /// and the guest it offered are gone.
    static func makeExecutor(for project: Project? = nil) -> BuildExecutor {
        NativeBuildExecutor(stagingDirectory: stagingDirectory)
    }
}
