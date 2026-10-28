import Foundation

/// Import a public GitHub repository at one revision as a project.
///
/// This is not `git clone`: iOS has no `git` and no process to run one in. GitHub
/// serves a ZIP of any revision over HTTPS, so the import downloads that archive,
/// unpacks it with `SnapshotArchiveExtractor` (bounded, no traversal, no symlinks),
/// and decides what the snapshot is — an Xcode project (read-only) or a SwiftPM
/// package (buildable, the path XForge already had).
///
/// History, submodules and LFS objects are not in the archive. That is stated in
/// the UI rather than papered over, and `ProjectOrigin` records exactly what was
/// fetched: the repository, the ref the user asked for and, best effort, the commit
/// the archive actually contains.
enum GitHubSnapshotImporter {
    /// Downloads are capped before anything is unpacked. A repository bigger than
    /// this is not a project snapshot this feature should try to import.
    static let maxArchiveBytes: Int64 = 256 * 1024 * 1024

    // MARK: - Progress

    enum Phase: Sendable, Equatable {
        case downloading
        case extracting
        case inspecting
        case installing

        var message: String {
            switch self {
            case .downloading: return "Downloading the repository archive…"
            case .extracting: return "Unpacking the snapshot…"
            case .inspecting: return "Looking for an Xcode project…"
            case .installing: return "Adding the project…"
            }
        }
    }

    // MARK: - Request / result

    struct Request: Sendable {
        var repository: GitHubRepository
        var organizationIdentifier: String = "com.example"
        /// A name the user typed. When `nil`, the repository name is sanitised and
        /// made unique; a typed name that is already taken is an error, not a rename.
        var preferredName: String?
        var existingNames: Set<String> = []
        /// The API call that pins the commit is best effort; tests turn it off.
        var resolveCommit: Bool = true

        init(repository: GitHubRepository,
             organizationIdentifier: String = "com.example",
             preferredName: String? = nil,
             existingNames: Set<String> = [],
             resolveCommit: Bool = true) {
            self.repository = repository
            self.organizationIdentifier = organizationIdentifier
            self.preferredName = preferredName
            self.existingNames = existingNames
            self.resolveCommit = resolveCommit
        }
    }

    struct Result: Sendable {
        let project: Project
        /// The freshly-read target list for an `.xcodeProject`, with URLs inside the
        /// installed directory. `nil` for a Swift package.
        let xcodeProject: XcodeProjectSummary?
        let extraction: SnapshotExtractionStats
    }

    // MARK: - Import

    static func importSnapshot(
        _ request: Request,
        progress: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> Result {
        let repository = request.repository
        let fileManager = FileManager.default

        progress(.downloading)
        let archiveURL = try await download(repository)
        defer { try? fileManager.removeItem(at: archiveURL) }

        // Staging lives beside the projects directory so the final step is a move
        // inside one volume, not a copy that can half-fail.
        let stagingDirectory = await XForgeEnvironment.stagingDirectory
        let stagingRoot = stagingDirectory.appendingPathComponent(
            "github-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        progress(.extracting)
        let raw = stagingRoot.appendingPathComponent("raw", isDirectory: true)
        let stats = try SnapshotArchiveExtractor.extract(archiveAt: archiveURL, to: raw)
        let snapshotRoot = SnapshotArchiveExtractor.unwrappedRoot(of: raw)

        progress(.inspecting)
        let contents = try GitHubSnapshotDetector.detect(in: snapshotRoot)

        // Name: typed names must be valid and free; derived names are made to fit.
        let preferred = request.preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let baseName: String
        if let preferred {
            baseName = try Project.validatedName(preferred)
            guard !request.existingNames.contains(where: {
                $0.compare(baseName, options: .caseInsensitive) == .orderedSame
            }) else {
                throw GitHubImportError.nameTaken(baseName)
            }
        } else {
            baseName = uniqueName(
                base: sanitizedProjectName(repository.name),
                existing: request.existingNames
            )
        }

        let kind: ProjectKind
        let snapshotSubpath: String?
        switch contents {
        case .swiftPackage:
            kind = .swiftPackage
            snapshotSubpath = nil
        case .xcodeProject(let relativePath, _):
            kind = .xcodeProject
            snapshotSubpath = relativePath
        }

        let organization = organizationIdentifier(
            requested: request.organizationIdentifier,
            contents: contents
        )
        let resolvedCommit = request.resolveCommit
            ? await GitHubRepository.resolveCommit(for: repository)
            : nil

        let project = Project(
            name: baseName,
            organizationIdentifier: organization,
            rootPath: Project.path(forValidatedName: baseName),
            kind: kind,
            origin: .githubArchive(
                repository: repository.slug,
                requestedRef: repository.ref,
                resolvedCommit: resolvedCommit,
                archiveURL: repository.archiveURL.absoluteString
            ),
            snapshotSubpath: snapshotSubpath
        )

        progress(.installing)
        let projectsDirectory = XForgeEnvironment.projectsDirectory
        try fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let destination = projectsDirectory.appendingPathComponent(baseName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw GitHubImportError.nameTaken(baseName)
        }

        do {
            try fileManager.moveItem(at: snapshotRoot, to: destination)
        } catch {
            throw GitHubImportError.couldNotInstall(error.localizedDescription)
        }

        // Read the project once more from its final location: the summary's URLs
        // must point at the installed snapshot, not at staging.
        var summary: XcodeProjectSummary?
        if kind == .xcodeProject {
            let projectDirectory = snapshotSubpath.map {
                destination.appendingPathComponent($0, isDirectory: true)
            } ?? destination
            do {
                summary = try XcodeProjectReader.read(at: projectDirectory)
            } catch {
                // Do not leave a project record (or a directory) that cannot be
                // opened: the import failed, so nothing is added.
                try? fileManager.removeItem(at: destination)
                throw GitHubImportError.xcodeProjectUnreadable(error.localizedDescription)
            }
        }

        XForgeLog.note("import: \(repository.slug) at \(repository.ref ?? "default branch") → \(baseName) (\(kind.rawValue))")
        return Result(project: project, xcodeProject: summary, extraction: stats)
    }

    // MARK: - Download

    /// Fetch the archive to a file this function owns.
    ///
    /// The status code is checked because `URLSession` treats a 404 as a successful
    /// download of GitHub's HTML error page; the ZIP signature is checked for the
    /// same reason.
    static func download(
        _ repository: GitHubRepository,
        session: URLSession = .shared
    ) async throws -> URL {
        var request = URLRequest(url: repository.archiveURL)
        request.timeoutInterval = 60
        request.setValue("XForge", forHTTPHeaderField: "User-Agent")

        let downloaded: (URL, URLResponse)
        do {
            downloaded = try await session.download(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw GitHubImportError.cancelled
        } catch {
            throw GitHubImportError.downloadFailed(error.localizedDescription)
        }
        let temporaryURL = downloaded.0
        let response = downloaded.1

        guard let http = response as? HTTPURLResponse else {
            throw GitHubImportError.downloadFailed("the server did not return HTTP")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 404:
            throw GitHubImportError.notFound(repository.slug)
        default:
            throw GitHubImportError.httpStatus(http.statusCode, repository.slug)
        }

        let fileManager = FileManager.default
        let owned = fileManager.temporaryDirectory.appendingPathComponent(
            "xforge-github-\(UUID().uuidString).zip"
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: owned)
        } catch {
            throw GitHubImportError.downloadFailed(error.localizedDescription)
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: owned.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > maxArchiveBytes {
            try? fileManager.removeItem(at: owned)
            throw GitHubImportError.downloadTooLarge(size.int64Value)
        }

        guard let handle = try? FileHandle(forReadingFrom: owned) else {
            try? fileManager.removeItem(at: owned)
            throw GitHubImportError.downloadFailed("the archive could not be read")
        }
        let magic = try? handle.read(upToCount: 4)
        try? handle.close()
        guard let magic, magic.count == 4,
              magic.starts(with: [0x50, 0x4B]) else {
            try? fileManager.removeItem(at: owned)
            throw GitHubImportError.notAZip
        }

        return owned
    }

    // MARK: - Naming

    /// Turn a repository name into a valid project name (`My-App` → `My-App`,
    /// `my.app` → `my-app`).
    static func sanitizedProjectName(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if scalar.isASCII,
               CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if result.count > 80 { result = String(result.prefix(80)) }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? "repository" : result
    }

    /// Append `-2`, `-3`… until the name is free. The comparison is
    /// case-insensitive because the destination filesystem usually is.
    static func uniqueName(base: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        for index in 2...999 {
            let candidate = "\(base.prefix(76))-\(index)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base.prefix(70))-\(UUID().uuidString.prefix(8))"
    }

    /// For an Xcode project, the bundle identifier already answers "who made this";
    /// its parent is a better organisation default than `com.example`.
    private static func organizationIdentifier(
        requested: String,
        contents: GitHubSnapshotContents
    ) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .xcodeProject(_, let summary) = contents,
              let bundleIdentifier = summary.applicationTargets.first?.bundleIdentifier
        else {
            return trimmed.isEmpty ? "com.example" : trimmed
        }
        let components = bundleIdentifier.split(separator: ".").map(String.init)
        guard components.count >= 3 else {
            return trimmed.isEmpty ? "com.example" : trimmed
        }
        return components.dropLast().joined(separator: ".")
    }
}

// MARK: - Detection

/// What a repository snapshot contains.
enum GitHubSnapshotContents: Sendable {
    /// A `Package.swift` at the snapshot root: importable and buildable.
    case swiftPackage
    /// An `.xcodeproj` somewhere in the snapshot. `relativePath` is the folder that
    /// holds it (`nil` when it is at the snapshot root).
    case xcodeProject(relativePath: String?, summary: XcodeProjectSummary)
}

enum GitHubSnapshotDetector {
    /// Decide what a snapshot is, reading the project file for real.
    ///
    /// Order matters and mirrors `ProjectImportInspector`: a `Package.swift` at the
    /// root is a Swift package first, because that is the import XForge can build.
    /// Otherwise the shallowest `.xcodeproj` is used; two at the same depth are
    /// ambiguous and rejected by name rather than guessed at.
    static func detect(in root: URL, maxDepth: Int = 4) throws -> GitHubSnapshotContents {
        let manifest = root.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: manifest.path) {
            return .swiftPackage
        }

        let found = findXcodeProjects(in: root, maxDepth: maxDepth)
        guard let depth = found.map({ $0.depth }).min() else {
            throw GitHubImportError.noProjectFound
        }
        let shallowest = found.filter { $0.depth == depth }
        guard shallowest.count == 1, let candidate = shallowest.first else {
            throw GitHubImportError.ambiguousXcodeProjects(
                shallowest.map({ $0.url.lastPathComponent }).sorted()
            )
        }

        let summary: XcodeProjectSummary
        do {
            summary = try XcodeProjectReader.read(at: candidate.url)
        } catch {
            throw GitHubImportError.xcodeProjectUnreadable(error.localizedDescription)
        }

        let directory = relativePath(of: candidate.url.deletingLastPathComponent(), in: root)
        return .xcodeProject(
            relativePath: (directory?.isEmpty == false) ? directory : nil,
            summary: summary
        )
    }

    /// Every `.xcodeproj` within `maxDepth`, with its depth (the root is 0).
    ///
    /// Build output and dependency folders are skipped: a `Pods` or `DerivedData`
    /// project file is not the repository's project.
    static func findXcodeProjects(in root: URL, maxDepth: Int = 4) -> [(url: URL, depth: Int)] {
        let fileManager = FileManager.default
        let skipped: Set<String> = [
            "Pods", "Carthage", "DerivedData", "node_modules", ".build", ".git", ".swiftpm",
        ]
        var found: [(url: URL, depth: Int)] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count {
            let (directory, depth) = queue[index]
            index += 1
            guard depth < maxDepth else { continue }

            let entries = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                if entry.pathExtension == "xcodeproj" {
                    found.append((entry, depth + 1))
                    continue
                }
                guard !skipped.contains(entry.lastPathComponent) else { continue }
                queue.append((entry, depth + 1))
            }
        }

        return found.sorted { lhs, rhs in
            lhs.depth == rhs.depth
                ? lhs.url.path < rhs.url.path
                : lhs.depth < rhs.depth
        }
    }

    /// `url` relative to `root`, `""` for the root itself, `nil` when outside it.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

// MARK: - Errors

enum GitHubImportError: LocalizedError, Equatable {
    case cancelled
    case downloadFailed(String)
    case httpStatus(Int, String)
    case notFound(String)
    case downloadTooLarge(Int64)
    case notAZip
    case noProjectFound
    case ambiguousXcodeProjects([String])
    case xcodeProjectUnreadable(String)
    case nameTaken(String)
    case couldNotInstall(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The import was cancelled."
        case .downloadFailed(let reason):
            return "Could not download the repository archive: \(reason)"
        case .httpStatus(let status, let repository):
            return "GitHub returned HTTP \(status) for \(repository)."
        case .notFound(let repository):
            return "GitHub could not find \(repository). Only public repositories can be imported."
        case .downloadTooLarge(let bytes):
            return "The archive is larger than "
                + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) "
                + "and was not imported."
        case .notAZip:
            return "GitHub did not return a ZIP archive. Check the repository and ref."
        case .noProjectFound:
            return "This repository has no .xcodeproj and no Package.swift at its root, "
                + "so there is nothing XForge can open."
        case .ambiguousXcodeProjects(let names):
            return "This repository contains \(names.count) Xcode projects at the same level "
                + "(\(names.joined(separator: ", "))); import the folder that contains the one you want."
        case .xcodeProjectUnreadable(let reason):
            return "The Xcode project could not be read: \(reason)"
        case .nameTaken(let name):
            return "A project named \(name) already exists. Rename it, or remove the existing one first."
        case .couldNotInstall(let reason):
            return "The snapshot could not be added to the projects folder: \(reason)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
