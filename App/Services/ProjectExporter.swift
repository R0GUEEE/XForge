import Foundation
import ZIPFoundation

/// Getting a project out of the app.
///
/// Projects are directories in the app's container, so an export is a ZIP of one
/// directory — no guest, no `tar` in a shell. The archive lands in
/// `<Documents>/exports`, which the Files app shows and the share sheet can hand on.
///
/// The walk skips build products: `.xforge-build` and `.build` are output, and an
/// export that carries a stale binary is worse than one that does not.
enum ProjectExporter {
    /// Where exported archives land: `<Documents>/exports`. Defined by
    /// `XForgeEnvironment`, which owns the storage rules.
    static var exportsDirectory: URL { XForgeEnvironment.exportsDirectory }

    /// Archive the project's active root and return a shareable ZIP.
    static func export(_ project: Project) throws -> URL {
        try exportDirectory(project.rootURL, folderName: project.name,
                            archiveName: project.name, includeHidden: false)
    }

    /// Archive the full imported repository snapshot, including `.xforge-generated`,
    /// so a generated Xcode project nested in a repository subfolder can still
    /// resolve its source references after unpacking.
    static func exportSnapshotForHandoff(_ project: Project) throws -> URL {
        try exportDirectory(
            project.snapshotRootURL,
            folderName: project.name,
            archiveName: "\(project.name)-Xcode-Handoff",
            includeHidden: true
        )
    }

    private static func exportDirectory(_ root: URL, folderName: String,
                                        archiveName: String, includeHidden: Bool) throws -> URL {
        let name = try Project.validatedName(folderName)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ExportError.projectMissing(root)
        }

        let directory = exportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(archiveName).zip")
        try? FileManager.default.removeItem(at: destination)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let copy = staging.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try copyContents(of: root, to: copy, includeHidden: includeHidden)

        try FileManager.default.zipItem(at: copy, to: destination, shouldKeepParent: true,
                                        compressionMethod: .deflate)
        XForgeLog.note("export: \(name) archived to \(destination.lastPathComponent)")
        return destination
    }

    /// Copy a project directory, skipping build output.
    private static func copyContents(of source: URL, to destination: URL,
                                     includeHidden: Bool) throws {
        let fileManager = FileManager.default
        let excluded: Set<String> = [".xforge-build", ".build", ".swiftpm", ".git", ".xforge-dependencies"]

        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard !excluded.contains(name) else { continue }
            if includeHidden && isSensitive(name) { continue }
            // Imported trees may contain links from Files-origin projects. Never
            // follow a link while creating a shareable archive: a repo could point
            // at unrelated data outside its snapshot.
            let attributes = try? fileManager.attributesOfItem(atPath: entry.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try copyContents(of: entry, to: target, includeHidden: includeHidden)
            } else {
                try fileManager.copyItem(at: entry, to: target)
            }
        }
    }

    private static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".env" || lower.hasPrefix(".env.")
            || [".netrc", ".npmrc", ".pypirc", ".ssh", ".aws", ".gnupg", ".kube"]
                .contains(lower)
    }

    enum ExportError: LocalizedError {
        case projectMissing(URL)

        var errorDescription: String? {
            switch self {
            case .projectMissing(let url):
                return "The project directory is missing: \(url.path)"
            }
        }
    }
}
