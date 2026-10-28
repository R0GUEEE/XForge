import Foundation

/// A SwiftPM package that can be built into an iOS app.
struct Project: Identifiable, Hashable, Codable, Sendable {
    /// Project directories live under `<Documents>/projects`; this is the stored
    /// prefix a project's `rootPath` is built from, kept so a project record and
    /// its directory can be checked against each other.
    static let projectsRoot = "projects"
    var id: UUID = UUID()
    var name: String
    var organizationIdentifier: String = "com.example"
    /// The project's stored path, relative to the app container (`projects/<name>`).
    var rootPath: String
    var createdAt: Date = Date()
    /// Configured Info.plist settings for the produced app (editable in the GUI).
    var appInfo: AppInfo?
    /// What this record points at. Decoded as `.swiftPackage` when absent, which is
    /// what every record written before Xcode-project import existed was.
    var kind: ProjectKind = .swiftPackage
    /// How the project got here. `nil` for records from before import metadata.
    var origin: ProjectOrigin?
    /// For an imported snapshot whose project lives in a subdirectory of the
    /// repository (a common Xcode layout), the project-relative path of that
    /// subdirectory. The whole snapshot is preserved on disk; only the root used
    /// for browsing/building is narrowed. `nil` means the repository root.
    var snapshotSubpath: String?

    var packageManifestPath: String { "\(rootPath)/Package.swift" }
    var ipaOutputPath: String { "\(rootPath)/.build/xforge-\(name).ipa" }

    /// The project directory in XForge's own container.
    ///
    /// Derived from `name` rather than stored: `rootPath` is the string this model
    /// carries around for display and for the safety check, and two stored
    /// locations for one project is how a build ends up reading a directory nobody
    /// created. `snapshotSubpath` is validated before use; an unsafe value falls
    /// back to the repository root rather than escaping it.
    var rootURL: URL {
        let base = XForgeEnvironment.projectsDirectory.appendingPathComponent(name, isDirectory: true)
        guard let snapshotSubpath,
              let safe = try? Self.validatedSubpath(snapshotSubpath) else { return base }
        return base.appendingPathComponent(safe, isDirectory: true)
    }

    /// The imported snapshot's root, ignoring `snapshotSubpath`.
    var snapshotRootURL: URL {
        XForgeEnvironment.projectsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    var isXcodeProject: Bool { kind == .xcodeProject }

    /// A repository-relative subdirectory: no absolute paths, no `..`, no empty
    /// components and no backslashes.
    static func validatedSubpath(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+ @()[]"))
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\u{0}"),
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw ProjectValidationError.unsafePath
        }
        return trimmed
    }

    static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty, name.count <= 80,
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProjectValidationError.invalidName
        }
        return name
    }

    static func path(forValidatedName name: String) -> String {
        "\(projectsRoot)/\(name)"
    }

    var hasSafeRootPath: Bool {
        rootPath == Self.path(forValidatedName: name)
    }
}

enum ProjectValidationError: LocalizedError {
    case invalidName
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Project names may contain only letters, numbers, hyphens, and underscores."
        case .unsafePath:
            return "The project path is outside XForge's projects directory."
        }
    }
}

extension Project {
    /// Explicit keys: the synthesized `CodingKeys` is private and this decoding lives
    /// in an extension. Naming them also documents that these are the stored fields.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case organizationIdentifier
        case rootPath
        case createdAt
        case appInfo
        case kind
        case origin
        case snapshotSubpath
    }

    /// Decode a record written by any version of the app.
    ///
    /// Synthesized `Codable` does *not* apply a property's default when the key is
    /// missing, so a stored project from before `kind`/`origin` existed would fail
    /// to decode and vanish from the list. Everything added after the first release
    /// is therefore `decodeIfPresent`, and the initial fields keep their old
    /// meaning.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        organizationIdentifier = try container.decodeIfPresent(
            String.self, forKey: .organizationIdentifier
        ) ?? "com.example"
        rootPath = try container.decode(String.self, forKey: .rootPath)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        appInfo = try container.decodeIfPresent(AppInfo.self, forKey: .appInfo)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .swiftPackage
        origin = try container.decodeIfPresent(ProjectOrigin.self, forKey: .origin)
        snapshotSubpath = try container.decodeIfPresent(String.self, forKey: .snapshotSubpath)
    }
}


enum BuildConfiguration: String, Codable, CaseIterable, Identifiable {
    case debug
    case release
    var id: String { rawValue }
}

/// Build events streamed back from an executor to the UI.
enum BuildEvent: Sendable {
    case plan(String)
    case output(String)
    case artifact(URL)
    case finished
    case failed(String)
}

/// Pluggable build backend. There is one implementation — the in-process
/// toolchain (`NativeBuildExecutor`) — and the seam is kept so a future backend
/// (a remote build server, say) does not have to rewrite the pipeline.
@MainActor
protocol BuildExecutor {
    /// Verify the user-installed base toolchain + xtool without installing it.
    func bootstrap() async throws -> AsyncThrowingStream<BuildEvent, Error>
    /// Install the `darwin` Swift SDK bundle (fetched on demand).
    func installSDK(from source: SDKSource) async throws
    /// Create a new project from a template.
    func createProject(named name: String, organizationIdentifier: String) async throws -> Project
    /// Resolve package dependencies.
    func resolve(_ project: Project) async throws -> AsyncThrowingStream<BuildEvent, Error>
    /// Build the package and produce a signed `.ipa`.
    func build(_ project: Project, configuration: BuildConfiguration) async throws -> AsyncThrowingStream<BuildEvent, Error>
}

enum SDKSource {
    /// A prebuilt `darwin.artifactbundle` we host (built in CI from Xcode).
    case hostedRemote(URL)

    /// The SDK that shipped inside this app bundle (`BundledDarwinSDK`).
    ///
    /// Not a network fetch and deliberately not a *fallback* for one: when a build
    /// carries an SDK, that SDK is what gets installed, and a failure to install it
    /// fails the stage instead of quietly downloading a different artifact.
    case bundled
}
