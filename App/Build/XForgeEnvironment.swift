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

    /// Where build artifacts are staged before export.
    static var stagingDirectory: URL {
        documentDirectory.appendingPathComponent("staging", isDirectory: true)
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

    /// Construct the build executor. `Local` uses the embedded Linux VM.
    static func makeExecutor(for project: Project? = nil) -> BuildExecutor {
        let vm: LinuxVM = EmbeddedLinuxVM(root: embeddedRoot)
        return EmbeddedLinuxExecutor(vm: vm, stagingDir: stagingDirectory)
    }
}
