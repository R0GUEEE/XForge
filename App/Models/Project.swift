import Foundation

/// A SwiftPM package that can be built into an iOS app.
struct Project: Identifiable, Hashable, Codable {
    static let projectsRoot = "/host/projects"\n    static let legacyProjectsRoot = "/root/projects"
    var id: UUID = UUID()
    var name: String
    var organizationIdentifier: String = "com.example"
    /// Path of the package root inside the embedded Linux filesystem.
    var rootPath: String
    var createdAt: Date = Date()
    /// Configured Info.plist settings for the produced app (editable in the GUI).
    var appInfo: AppInfo?

    var packageManifestPath: String { "\(rootPath)/Package.swift" }
    var ipaOutputPath: String { "\(rootPath)/.build/xforge-\(name).ipa" }

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
            || rootPath == "\(Self.legacyProjectsRoot)/\(name)"
    }

    /// Native host URL for projects stored in the shared `/host` mount.
    ///
    /// Legacy `/root/projects` entries remain Linux-only until migrated.
    @MainActor
    var hostRootURL: URL? {
        let expected = Self.path(forValidatedName: name)
        guard rootPath == expected else { return nil }
        return XForgeEnvironment.hostShareDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
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

/// Pluggable build backend. `Local` = embedded Linux VM, `Remote` = future build server.
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
    /// Already inside the embedded Linux filesystem.
    case bundled(String)
}
