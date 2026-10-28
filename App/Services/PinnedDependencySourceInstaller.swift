import Foundation
import CryptoKit

/// Downloads exact lockfile-pinned public GitHub sources without running SwiftPM.
/// This only stages source trees; the current native build does not compile/link
/// dependency modules, so this service never reports these packages as buildable.
enum PinnedDependencySourceInstaller {
    static let maximumPackagesPerRun = 24
    static let maximumAggregateExtractedBytes: Int64 = 512 * 1024 * 1024
    static let limits = SnapshotExtractionLimits(
        maxEntries: 10_000,
        maxTotalBytes: 192 * 1024 * 1024,
        maxEntryBytes: 48 * 1024 * 1024,
        maxPathLength: 512,
        maxPathComponents: 32
    )

    enum Progress: Sendable, Equatable {
        case package(Int, Int, String)
        case completed(Int, Int, String)
        var message: String {
            switch self {
            case .package(let n, let total, let name): return "Downloading \(n)/\(total): \(name)…"
            case .completed(let n, let total, let name): return "Fetched \(n)/\(total): \(name)"
            }
        }
    }

    struct Result: Sendable, Equatable {
        let installed: [String]
        let alreadyPresent: [String]
        let extractedBytes: Int64
        let notes: [String]
    }

    struct Marker: Codable, Equatable, Sendable {
        let identity: String
        let repository: String
        let revision: String
        let archiveSHA256: String
        let sourceTreeSHA256: String?
        let archiveBytes: Int64
        let extractedBytes: Int64
        let fetchedAt: Date
    }

    enum InstallError: LocalizedError {
        case tooManyPackages(Int)
        case aggregateLimitExceeded
        case destinationCollision(String)
        case unexpectedArchiveRoot(String)
        case archiveRevisionMismatch(identity: String, expected: String, actualRoot: String)
        case invalidPin(String)
        case unsafeCachedFile(String)
        case cachedTreeTooLarge

        var errorDescription: String? {
            switch self {
            case .tooManyPackages(let count): return "The lockfile has \(count) package pins; source installation is capped at \(maximumPackagesPerRun) packages per run."
            case .aggregateLimitExceeded: return "Dependency source snapshots exceed the 512 MiB per-run extraction budget."
            case .destinationCollision(let name): return "Dependency destination \(name) already contains different source data; it was left untouched."
            case .unexpectedArchiveRoot(let name): return "The archive for \(name) did not contain a single repository root."
            case .archiveRevisionMismatch(let identity, let expected, let root): return "The GitHub archive for \(identity) did not identify the pinned commit \(expected.prefix(12)); archive root was \(root). Refusing to store it as a pinned source."
            case .invalidPin(let name): return "The pin for \(name) is not an immutable supported public GitHub commit."
            case .unsafeCachedFile(let path): return "The fetched dependency cache contains a symbolic link or unsafe file path (\(path)); it was not built. Remove and fetch the source again."
            case .cachedTreeTooLarge: return "The cached dependency source exceeds the source verification size limit."
            }
        }
    }

    static func installPinnedSources(
        for project: Project,
        pins: [ResolvedPackagePin],
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        guard pins.count <= maximumPackagesPerRun else { throw InstallError.tooManyPackages(pins.count) }
        let projectRoot = project.isXcodeProject ? project.snapshotRootURL : project.rootURL
        let root = projectRoot.appendingPathComponent(".xforge-dependencies", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(resourceValues)
        var installed: [String] = []
        var existing: [String] = []
        var notes: [String] = []
        var aggregate: Int64 = 0

        for (index, pin) in pins.enumerated() {
            try Task.checkCancellation()
            guard pin.kind == .remoteSourceControl, isCommit(pin.revision),
                  let repo = try? GitHubRepository.parse(pin.location, explicitRef: pin.revision) else {
                notes.append("\(pin.identity): only immutable GitHub remoteSourceControl pins can be fetched")
                continue
            }
            let revision = pin.revision.lowercased()
            let slug = "\(GitHubSnapshotImporter.sanitizedProjectName(pin.identity))-\(revision.prefix(12))"
            let destination = root.appendingPathComponent(slug, isDirectory: true)
            if let marker = readMarker(destination), marker.revision == revision,
               marker.repository == repo.slug {
                guard let treeHash = marker.sourceTreeSHA256,
                      (try? sourceTreeSHA256(at: destination)) == treeHash else {
                    throw InstallError.destinationCollision(slug)
                }
                existing.append(pin.identity)
                continue
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                throw InstallError.destinationCollision(slug)
            }
            progress(.package(index + 1, pins.count, pin.identity))
            let archive = try await GitHubSnapshotImporter.download(repo)
            defer { try? FileManager.default.removeItem(at: archive) }
            let archiveBytes = fileSize(archive)
            let archiveHash = try fileSHA256(archive)
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            let raw = staging.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let stats = try await Task.detached(priority: .utility) {
                try SnapshotArchiveExtractor.extract(archiveAt: archive, to: raw, limits: limits)
            }.value
            aggregate += stats.bytes
            guard aggregate <= maximumAggregateExtractedBytes else { throw InstallError.aggregateLimitExceeded }
            let sourceRoot = SnapshotArchiveExtractor.unwrappedRoot(of: raw)
            guard sourceRoot != raw else { throw InstallError.unexpectedArchiveRoot(pin.identity) }
            guard Self.archiveRootMatches(revision: revision, rootName: sourceRoot.lastPathComponent) else {
                throw InstallError.archiveRevisionMismatch(identity: pin.identity,
                                                           expected: revision,
                                                           actualRoot: sourceRoot.lastPathComponent)
            }
            let sourceTreeHash = try sourceTreeSHA256(at: sourceRoot)
            let marker = Marker(identity: pin.identity, repository: repo.slug, revision: revision,
                                archiveSHA256: archiveHash, sourceTreeSHA256: sourceTreeHash,
                                archiveBytes: archiveBytes, extractedBytes: stats.bytes, fetchedAt: Date())
            try JSONEncoder().encode(marker).write(to: sourceRoot.appendingPathComponent(".xforge-dependency.json"), options: .atomic)
            try FileManager.default.moveItem(at: sourceRoot, to: destination)
            installed.append(pin.identity)
            progress(.completed(index + 1, pins.count, pin.identity))
        }
        return Result(installed: installed, alreadyPresent: existing, extractedBytes: aggregate, notes: notes)
    }

    static func archiveRootMatches(revision: String, rootName: String) -> Bool {
        rootName.lowercased().hasSuffix(revision.lowercased())
    }

    /// Re-hash the extracted files at install and plan time. The archive digest is
    /// provenance; this tree digest detects edits after fetch before compiler input
    /// is trusted. File paths are ordered and included in the digest as well.
    static func sourceTreeSHA256(at root: URL) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: []
        ) else { throw InstallError.unsafeCachedFile(root.lastPathComponent) }
        var files: [(String, URL, Int64)] = []
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".xforge-dependency.json" { continue }
            let relative = GitHubSnapshotDetector.relativePath(of: url, in: root) ?? url.lastPathComponent
            guard (try? SnapshotArchiveExtractor.validatedRelativePath(relative)) != nil else {
                throw InstallError.unsafeCachedFile(relative)
            }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw InstallError.unsafeCachedFile(relative)
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            bytes += size
            guard bytes <= limits.maxTotalBytes, files.count < limits.maxEntries else {
                throw InstallError.cachedTreeTooLarge
            }
            files.append((relative, url, size))
        }
        files.sort { $0.0 < $1.0 }
        var digest = SHA256()
        for (relative, url, _) in files {
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: url)
            do {
                while true {
                    let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    digest.update(data: chunk)
                }
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readMarker(_ directory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".xforge-dependency.json")) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
