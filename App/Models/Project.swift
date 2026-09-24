import Foundation

/// A SwiftPM package that can be built into an iOS app.
struct Project: Identifiable, Hashable, Codable {
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

    var packageManifestPath: String { "\(rootPath)/Package.swift" }
    var ipaOutputPath: String { "\(rootPath)/.build/xforge-\(name).ipa" }

    /// The project directory in XForge's own container.
    ///
    /// Derived from `name` rather than stored. `rootPath` is the guest path this
    /// model was designed around, and two stored locations for one project is how
    /// a build ends up reading a directory nobody created.
    var rootURL: URL {
        XForgeEnvironment.projectsDirectory.appendingPathComponent(name, isDirectory: true)
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
    ///
    /// It used to have a `.bundled` case for an SDK already inside the guest
    /// filesystem. There is no guest, so there is one way to get an SDK: fetch it.
    case hostedRemote(URL)
}
