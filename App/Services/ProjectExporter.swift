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

    /// Archive `project` and return the host URL of the `.zip`.
    static func export(_ project: Project) throws -> URL {
        let name = try Project.validatedName(project.name)
        let root = project.rootURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ExportError.projectMissing(root)
        }

        let directory = exportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: destination)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let copy = staging.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try copyContents(of: root, to: copy)

        // `shouldKeepParent` on the *staging* directory keeps one top-level folder,
        // so unpacking the archive cannot scatter files wherever it is opened.
        try FileManager.default.zipItem(
            at: copy,
            to: destination,
            shouldKeepParent: true
        )
        XForgeLog.note("export: \(name) archived to \(destination.lastPathComponent)")
        return destination
    }

    /// Copy a project directory, skipping build output.
    private static func copyContents(of source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let excluded: Set<String> = [".xforge-build", ".build", ".swiftpm", ".git"]

        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard !excluded.contains(name) else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try copyContents(of: entry, to: target)
            } else {
                try fileManager.copyItem(at: entry, to: target)
            }
        }
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
