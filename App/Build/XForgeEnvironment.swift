import Foundation

/// Application-level wiring: where the embedded Linux lives, how a build executor is
/// constructed for a project, and where staged artifacts land.
@MainActor
enum XForgeEnvironment {
    /// App sandbox root.
    static var documentDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// App sandbox subdirectory holding the embedded Linux userspace.
    static var embeddedRoot: URL {
        documentDirectory.appendingPathComponent("embedded-linux", isDirectory: true)
    }

    /// Installed iSH-AOK `fakefs` root filesystems. The bundled Alpine rootfs is
    /// imported here on first boot and reused afterwards.
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
    /// iSH-AOK can only boot one guest per process, so every screen (Terminal,
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
    /// iSH-AOK runs a real aarch64 Linux guest in-process; its "gadget JIT"
    /// needs no JIT entitlement, so it works in a sideloaded app.
    static func makeEmulator() -> LinuxEmulator {
        ISHAOKEmulator(rootsDirectory: rootsDirectory, hostDirectory: hostShareDirectory)
    }
}
