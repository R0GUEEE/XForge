import Foundation

/// A SwiftPM package that can be built into an iOS app.
struct Project: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var organizationIdentifier: String = "com.example"
    /// Path of the package root inside the embedded Linux filesystem.
    var rootPath: String
    var createdAt: Date = Date()

    var packageManifestPath: String { "\(rootPath)/Package.swift" }
    var ipaOutputPath: String { "\(rootPath)/.build/xforge-\(name).ipa" }
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
    /// Fetch/install the base toolchain + xtool (no-op if already installed).
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
