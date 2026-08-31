import Foundation

/// Application-level wiring: where the embedded Linux lives, how a build executor is
/// constructed for a project, and where staged artifacts land.
enum XForgeEnvironment {
    /// App sandbox subdirectory holding the embedded Linux userspace.
    static var embeddedRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("embedded-linux", isDirectory: true)
    }

    /// Where build artifacts are staged before export.
    static var stagingDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("staging", isDirectory: true)
    }

    /// Construct the build executor. `Local` uses the embedded Linux VM.
    static func makeExecutor(for project: Project) -> BuildExecutor {
        let vm: LinuxVM = EmbeddedLinuxVM(root: embeddedRoot)
        return EmbeddedLinuxExecutor(vm: vm, stagingDir: stagingDirectory)
    }
}
