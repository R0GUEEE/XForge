import Foundation

/// Reading and writing a project's files.
///
/// This replaces `GuestProjectFiles`, which listed and copied files through the
/// embedded Linux. A project is now an ordinary directory in the app's container,
/// so the whole thing is `FileManager` — but the *relative-path* discipline stays:
/// every path is resolved against the project root and rejected if it escapes,
/// because these paths come from editable text in the UI.
@MainActor
enum ProjectFiles {
    struct File: Identifiable, Hashable {
        let id: String
        let name: String
        let relativePath: String
        var contents: String
    }

    /// Files that are never project content: build products and editor state.
    private static let excludedDirectories: Set<String> = [".xforge-build", ".git", ".build", ".swiftpm"]

    static func load(project: Project, sourcesOnly: Bool) async throws -> [File] {
        let root = sourcesOnly
            ? project.rootURL.appendingPathComponent("Sources", isDirectory: true)
            : project.rootURL
        return try await loadFiles(under: root, project: project)
    }

    static func load(relativePath: String, project: Project) async throws -> File {
        let url = try resolve(relativePath: relativePath, in: project)
        return try read(url, relativePath: relativePath)
    }

    static func save(_ contents: String, file: File, project: Project) async throws {
        let url = try resolve(relativePath: file.relativePath, in: project)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write a file that may not exist yet, creating intermediate directories.
    static func write(_ contents: String, relativePath: String, project: Project) throws {
        let url = try resolve(relativePath: relativePath, in: project)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func createDirectory(relativePath: String, project: Project) throws {
        let url = try resolve(relativePath: relativePath, in: project)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func delete(relativePath: String, project: Project) throws {
        let url = try resolve(relativePath: relativePath, in: project)
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private static func loadFiles(under root: URL, project: Project) async throws -> [File] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let relative = relativePath(of: url, in: project) else { continue }
            // Text only: the editor cannot show a binary, and a project full of
            // build products should not be read into memory to find that out.
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append(File(
                id: relative,
                name: url.lastPathComponent,
                relativePath: relative,
                contents: contents
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private static func read(_ url: URL, relativePath: String) throws -> File {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return File(
            id: relativePath,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            contents: contents
        )
    }

    /// A project-relative path for `url`, or nil when it is outside the project.
    private static func relativePath(of url: URL, in project: Project) -> String? {
        let root = project.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// Resolve a user-supplied relative path inside the project.
    ///
    /// `..` is rejected rather than merely normalized: an editor that can write
    /// outside its own project is a sandbox escape with a nice UI, and the
    /// standardized path check catches the symlink-free cases the textual check
    /// would miss.
    private static func resolve(relativePath: String, in project: Project) throws -> URL {
        guard isSafe(relativePath: relativePath) else {
            throw ProjectFileError.unsafeRelativePath
        }
        let root = project.rootURL
        let url = root.appendingPathComponent(relativePath)
        guard relativePath(of: url, in: project) != nil else {
            throw ProjectFileError.unsafeRelativePath
        }
        return url
    }

    static func isSafe(relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.split(separator: "/").contains("..")
            && !relativePath.contains("\n")
    }
}

enum ProjectFileError: LocalizedError {
    case unsafeRelativePath
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsafeRelativePath:
            return "That path is outside the project."
        case .unreadable(let path):
            return "Could not read \(path) as text."
        }
    }
}
