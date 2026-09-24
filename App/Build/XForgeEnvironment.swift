import Foundation

/// Application-level wiring: where the embedded Linux lives, how a build executor is
/// constructed for a project, and where staged artifacts land.
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

    /// App sandbox subdirectory holding the embedded Linux userspace.
    static var embeddedRoot: URL {
        documentDirectory.appendingPathComponent("embedded-linux", isDirectory: true)
    }

    /// Installed ish-arm64 `fakefs` root filesystems. The bundled Alpine rootfs is
    /// imported here at launch and reused afterwards (the first boot imports it
    /// as a fallback).
    static var rootsDirectory: URL {
        embeddedRoot.appendingPathComponent("roots", isDirectory: true)
    }

    /// Whether the bundled Alpine rootfs has already been imported.
    static var isRootfsInstalled: Bool {
        RootfsInstaller.isInstalled(in: rootsDirectory)
    }

    /// Directory shared into the guest at `/host` (read-write, realfs). Large
    /// artifacts are staged here by the host instead of being pushed through the
    /// guest command pipe.
    static var hostShareDirectory: URL {
        embeddedRoot.appendingPathComponent("host", isDirectory: true)
    }

    /// Host-side downloads (SDK archives, toolchain bundles).
    static var downloadsDirectory: URL {
        documentDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// Host-side Darwin SDK used by the native compiler path.
    nonisolated static var nativeSDKDirectory: URL {
        documentDirectory.appendingPathComponent("native-sdk", isDirectory: true)
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
    ///  - the downloads, staged artifacts and engine log are excluded: each is
    ///    produced again by downloading, rebuilding or running;
    ///  - **the guest filesystem is excluded too.** It is the bundled rootfs
    ///    imported into fakefs, and with `XFORGE_PROVISION=all` that is several
    ///    gigabytes of Alpine, Swift, xtool and the SDK. The user's projects live
    ///    *inside* it — nothing here can separate one from the other — so this is
    ///    a real trade-off: projects are no longer in device backups. The way out
    ///    is `ProjectExporter` ("Export project" on a project's screen, and the
    ///    archive appears in `Documents/exports`, which *is* backed up), plus the
    ///    `/host` share and the Terminal for anything else.
    ///
    /// See Docs/DESIGN.md, "What is backed up", for why the two cannot be split.
    static func prepareStorage() {
        let fm = FileManager.default
        let excluded = [embeddedRoot, downloadsDirectory, nativeSDKDirectory, stagingDirectory, logsDirectory]
        for directory in excluded {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
        }
        // Exports are the user's work leaving the guest, so they are left alone:
        // backed up, and visible in the Files app.
        try? fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
    }

    /// Where `ProjectExporter` writes project archives (`<Documents>/exports`).
    /// Kept here rather than in the exporter so the storage rules live in one file.
    static var exportsDirectory: URL {
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

    /// The single embedded Linux VM for the whole app.
    ///
    /// ish-arm64 can only boot one guest per process, so every screen (Terminal,
    /// Toolchain, Build) must share this instance rather than creating its own.
    private static var sharedVM: LinuxVM?

    static func makeVM() -> LinuxVM {
        if let sharedVM { return sharedVM }
        for dir in [embeddedRoot, rootsDirectory, hostShareDirectory, downloadsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let vm = EmbeddedLinuxVM(root: embeddedRoot,
                                 hostShare: hostShareDirectory,
                                 emulator: makeEmulator())
        sharedVM = vm
        return vm
    }

    /// Construct the build executor. `Local` uses the embedded Linux VM.
    static func makeExecutor(for project: Project? = nil) -> BuildExecutor {
        EmbeddedLinuxExecutor(vm: makeVM(), stagingDir: stagingDirectory)
    }

    /// The in-process Linux emulator that runs the embedded Alpine guest.
    /// ish-arm64 runs a real aarch64 Linux guest in-process; its threaded-code
    /// interpreter dispatches guest instructions to pre-compiled "gadgets", so it
    /// needs no JIT entitlement and works in a sideloaded app.
    static func makeEmulator() -> LinuxEmulator {
        ISHEmulator(rootsDirectory: rootsDirectory, hostDirectory: hostShareDirectory)
    }
}
