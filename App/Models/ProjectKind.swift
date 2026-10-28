import Foundation

/// What a project record points at.
///
/// XForge started with one kind of project: a SwiftPM package it can compile
/// in-process. An imported `.xcodeproj` is kept as a *second* kind so it can live
/// in the Projects list, be browsed, and be exported, without any screen
/// pretending it can be built. `ProjectKind` is stored in `Project`, so the
/// distinction survives relaunch; records written before this existed decode as
/// `.swiftPackage` (see `Project.init(from:)`).
enum ProjectKind: String, Codable, Hashable, Sendable {
    /// A directory with a `Package.swift` — the only kind with a build path.
    case swiftPackage
    /// An Xcode project (`.xcodeproj`) imported read-only. Nothing builds it.
    case xcodeProject

    var displayName: String {
        switch self {
        case .swiftPackage: return "Swift package"
        case .xcodeProject: return "Xcode project"
        }
    }

    /// The one place that answers "can XForge build this?".
    var isBuildable: Bool { self == .swiftPackage }
}

/// Where a project came from, when it was not created in XForge.
///
/// For a GitHub import this is deliberately precise about what was fetched: an
/// archive of one revision, not a clone. `resolvedCommit` is the immutable
/// identity when GitHub's API could be asked; `requestedRef` is what the user
/// typed and may have moved since.
struct ProjectOrigin: Codable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case created
        case files
        case githubArchive
    }

    var source: Source
    /// `owner/repository`, as resolved from the URL.
    var repository: String?
    /// Branch, tag or commit the user asked for. `nil` means the default branch.
    var requestedRef: String?
    /// Commit SHA the archive actually contains, when it could be resolved.
    var resolvedCommit: String?
    var archiveURL: String?
    var importedAt: Date

    static func created() -> ProjectOrigin {
        ProjectOrigin(source: .created, importedAt: Date())
    }

    static func filesImport() -> ProjectOrigin {
        ProjectOrigin(source: .files, importedAt: Date())
    }

    static func githubArchive(repository: String,
                              requestedRef: String?,
                              resolvedCommit: String?,
                              archiveURL: String?,
                              importedAt: Date = Date()) -> ProjectOrigin {
        ProjectOrigin(
            source: .githubArchive,
            repository: repository,
            requestedRef: requestedRef,
            resolvedCommit: resolvedCommit,
            archiveURL: archiveURL,
            importedAt: importedAt
        )
    }

    /// `owner/repo@abc1234` — short enough for a row, still identifies the code.
    var shortDescription: String? {
        guard let repository else { return nil }
        switch source {
        case .githubArchive:
            if let resolvedCommit, resolvedCommit.count >= 7 {
                return "\(repository)@\(resolvedCommit.prefix(7))"
            }
            if let requestedRef { return "\(repository)@\(requestedRef)" }
            return repository
        case .files:
            return repository
        case .created:
            return nil
        }
    }
}
