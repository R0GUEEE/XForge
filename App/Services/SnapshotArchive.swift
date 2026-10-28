import Foundation
import ZIPFoundation

/// Bounds for a repository snapshot.
///
/// A GitHub archive is attacker-controlled input even when the repository is
/// public: a ZIP can name `../../Library/Preferences/x`, contain a symlink to
/// `/`, or claim a 4 GB entry. Every one of those is rejected here before a byte
/// is written outside the staging directory.
struct SnapshotExtractionLimits: Sendable, Equatable {
    /// Entries, directories included.
    var maxEntries: Int = 20_000
    /// Total uncompressed bytes for the whole snapshot.
    var maxTotalBytes: Int64 = 768 * 1024 * 1024
    /// Uncompressed bytes for a single file.
    var maxEntryBytes: Int64 = 256 * 1024 * 1024
    var maxPathLength: Int = 512
    var maxPathComponents: Int = 32

    static let `default` = SnapshotExtractionLimits()
}

struct SnapshotExtractionStats: Sendable, Equatable {
    var files: Int = 0
    var directories: Int = 0
    var skipped: Int = 0
    var bytes: Int64 = 0
}

/// Unpacks a downloaded repository archive into a directory, refusing anything
/// that could escape it.
///
/// `Archive.extract(_:to:)` is deliberately not used: its safety rules belong to
/// ZIPFoundation and can change with the dependency, while the rules this feature
/// promises (no `..`, no absolute paths, no symlinks, bounded size) have to be
/// enforced by XForge. Entries are read one at a time and written to a path that
/// was validated and re-checked against the destination root.
enum SnapshotArchiveExtractor {
    /// Extract `archiveAt` into `destination`, which is created.
    ///
    /// Synchronous and non-isolated: the caller runs it off the main actor so the
    /// UI keeps rendering while a large repository is unpacked.
    static func extract(archiveAt archiveURL: URL,
                        to destination: URL,
                        limits: SnapshotExtractionLimits = .default) throws -> SnapshotExtractionStats {
        let fileManager = FileManager.default

        if let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > limits.maxTotalBytes {
            throw SnapshotArchiveError.archiveTooLarge(size.int64Value)
        }

        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw SnapshotArchiveError.notAZip
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let rootPath = destination.standardizedFileURL.path
        var stats = SnapshotExtractionStats()

        for entry in archive {
            stats.files += 0 // keep the compiler from inferring the loop body below
            let isDirectory = entry.type == .directory || entry.path.hasSuffix("/")
            let rawPath = entry.path

            if isIgnored(rawPath) {
                stats.skipped += 1
                continue
            }

            if entry.type == .symlink {
                throw SnapshotArchiveError.symlinkEntry(rawPath)
            }
            guard entry.type == .file || entry.type == .directory else {
                throw SnapshotArchiveError.unsupportedEntryType(rawPath)
            }

            let relative = try validatedRelativePath(
                rawPath,
                isDirectory: isDirectory,
                limits: limits
            )

            stats.files += isDirectory ? 0 : 1
            stats.directories += isDirectory ? 1 : 0
            if stats.files + stats.directories > limits.maxEntries {
                throw SnapshotArchiveError.tooManyEntries(limits.maxEntries)
            }

            let target = destination.appendingPathComponent(relative, isDirectory: isDirectory)
            let targetPath = target.standardizedFileURL.path
            // A second check, on the resolved path: the textual validation above is
            // the rule, this is the assertion that the rule actually held.
            guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
                throw SnapshotArchiveError.unsafeEntryPath(rawPath)
            }

            if isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            let declaredSize = Int64(entry.uncompressedSize)
            guard declaredSize <= limits.maxEntryBytes else {
                throw SnapshotArchiveError.entryTooLarge(relative)
            }
            guard stats.bytes + declaredSize <= limits.maxTotalBytes else {
                throw SnapshotArchiveError.archiveTooLarge(stats.bytes + declaredSize)
            }

            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: target.path, contents: nil) else {
                throw SnapshotArchiveError.cannotWrite(relative)
            }

            let handle = try FileHandle(forWritingTo: target)
            var written: Int64 = 0
            do {
                try archive.extract(entry, consumer: { chunk in
                    written += Int64(chunk.count)
                    guard written <= limits.maxEntryBytes else {
                        throw SnapshotArchiveError.entryTooLarge(relative)
                    }
                    guard stats.bytes + written <= limits.maxTotalBytes else {
                        throw SnapshotArchiveError.archiveTooLarge(stats.bytes + written)
                    }
                    try handle.write(contentsOf: chunk)
                })
            } catch {
                try? handle.close()
                try? fileManager.removeItem(at: target)
                throw error
            }
            try handle.close()
            stats.bytes += written
        }

        return stats
    }

    /// Archive metadata and Finder droppings are not repository content.
    static func isIgnored(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first else { return true }
        if first == "__MACOSX" { return true }
        if components.last == ".DS_Store" { return true }
        return false
    }

    /// Validate an archive entry path and return it in normalised form.
    ///
    /// Rejected rather than normalised, because silently turning `a/../b` into `b`
    /// hides that the archive tried to leave its own tree.
    static func validatedRelativePath(_ raw: String,
                                      isDirectory: Bool = false,
                                      limits: SnapshotExtractionLimits = .default) throws -> String {
        var path = raw
        if isDirectory, path.hasSuffix("/") {
            path.removeLast()
        }

        guard !path.isEmpty,
              path.count <= limits.maxPathLength,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains("\u{0}"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SnapshotArchiveError.unsafeEntryPath(raw)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= limits.maxPathComponents else {
            throw SnapshotArchiveError.unsafeEntryPath(raw)
        }
        // `C:`/`C:/x` is an absolute path on another platform; a colon has no place
        // in a repository path anyway.
        if components[0].contains(":") {
            throw SnapshotArchiveError.unsafeEntryPath(raw)
        }

        for component in components {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  component.count <= 255 else {
                throw SnapshotArchiveError.unsafeEntryPath(raw)
            }
        }

        return components.joined(separator: "/")
    }

    /// GitHub's archives wrap everything in one `<repo>-<ref>/` folder. Import
    /// should not make the user browse through it, so the single top-level
    /// directory becomes the snapshot root.
    static func unwrappedRoot(of directory: URL) -> URL {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), entries.count == 1,
            let only = entries.first,
            (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return directory
        }
        return only
    }
}

enum SnapshotArchiveError: LocalizedError, Equatable {
    case notAZip
    case unsafeEntryPath(String)
    case symlinkEntry(String)
    case unsupportedEntryType(String)
    case tooManyEntries(Int)
    case entryTooLarge(String)
    case archiveTooLarge(Int64)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "The downloaded file is not a ZIP archive."
        case .unsafeEntryPath(let path):
            return "The archive contains an unsafe path (“\(path)”) and was not imported."
        case .symlinkEntry(let path):
            return "The archive contains a symbolic link (“\(path)”). Links are not extracted."
        case .unsupportedEntryType(let path):
            return "The archive contains an entry that is not a file or folder (“\(path)”)."
        case .tooManyEntries(let limit):
            return "The archive contains more than \(limit) entries and was not imported."
        case .entryTooLarge(let path):
            return "The archive entry “\(path)” is too large to import."
        case .archiveTooLarge(let bytes):
            return "The archive expands to more than \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case .cannotWrite(let path):
            return "Could not write “\(path)” into the project folder."
        }
    }
}
