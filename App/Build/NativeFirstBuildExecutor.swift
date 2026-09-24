import Foundation
import XtoolMobileKit

/// Prefers the in-process XtoolMobileKit compiler when the host app contains the
/// native compiler archive and a compatible SDK is installed. Otherwise it
/// delegates to the embedded Linux executor so existing projects keep working.
@MainActor
final class NativeFirstBuildExecutor: BuildExecutor {
    private let project: Project?
    private let stagingDirectory: URL
    private let fallback: EmbeddedLinuxExecutor

    init(
        project: Project?,
        stagingDirectory: URL,
        fallback: EmbeddedLinuxExecutor
    ) {
        self.project = project
        self.stagingDirectory = stagingDirectory
        self.fallback = fallback
    }

    func bootstrap() async throws -> AsyncThrowingStream<BuildEvent, Error> {
        if nativeContext(for: project) != nil {
            return AsyncThrowingStream { continuation in
                continuation.yield(.plan("Using native XtoolMobileKit compiler backend."))
                continuation.yield(.finished)
                continuation.finish()
            }
        }

        return try await fallback.bootstrap()
    }

    func installSDK(from source: SDKSource) async throws {
        // Native SDK installation uses XtoolMobileKit's manifest format. Until
        // XForge publishes that archive, keep the existing Darwin SDK installer
        // available through the Linux fallback.
        try await fallback.installSDK(from: source)
    }

    func createProject(
        named name: String,
        organizationIdentifier: String
    ) async throws -> Project {
        try await fallback.createProject(
            named: name,
            organizationIdentifier: organizationIdentifier
        )
    }

    func resolve(
        _ project: Project
    ) async throws -> AsyncThrowingStream<BuildEvent, Error> {
        // Native dependency resolution is not implemented in XtoolMobileKit yet.
        // Projects without external packages can still compile natively; the
        // fallback keeps SwiftPM resolution working for existing projects.
        try await fallback.resolve(project)
    }

    func build(
        _ project: Project,
        configuration: BuildConfiguration
    ) async throws -> AsyncThrowingStream<BuildEvent, Error> {
        guard let context = nativeContext(for: project) else {
            return try await fallback.build(
                project,
                configuration: configuration
            )
        }

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    continuation.yield(.plan(
                        "Building (project.name) natively with XtoolMobileKit…"
                    ))

                    let backend = NativeIOSApplicationBuildBackend(
                        sdk: context.sdk,
                        productName: project.name,
                        appName: project.appInfo?.displayName ?? project.name,
                        minimumIOSVersion:
                            project.appInfo?.minimumOSVersion ?? "17.0",
                        outputDirectory: stagingDirectory
                    )
                    let builder = NativeIOSXtoolBuilder(backend: backend)
                    let request = XtoolBuildRequest(
                        workspace: XtoolWorkspace(
                            rootURL: context.workspaceURL
                        ),
                        configuration:
                            configuration == .release ? .release : .debug
                    )

                    let result = try await builder.build(
                        request,
                        events: { event in
                            continuation.yield(.output(event.message))
                        }
                    )

                    guard let artifact = result.artifactURL else {
                        continuation.yield(.failed(
                            "Native build completed without an IPA artifact."
                        ))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.artifact(artifact))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private struct NativeContext {
        let workspaceURL: URL
        let sdk: XtoolSDK
    }

    private func nativeContext(for project: Project?) -> NativeContext? {
        guard let project,
              let workspaceURL = project.hostRootURL,
              XtoolRuntimeCapabilities.current.canBuildOnDevice else {
            return nil
        }

        let store: XtoolSDKStore
        do {
            store = try .applicationSupport()
        } catch {
            return nil
        }

        guard let sdk = try? store.installedSDKs().first else {
            return nil
        }

        let manifest = workspaceURL.appendingPathComponent("Package.swift")
        let xtoolConfig = workspaceURL.appendingPathComponent("xtool.yml")
        guard FileManager.default.fileExists(atPath: manifest.path),
              FileManager.default.fileExists(atPath: xtoolConfig.path) else {
            return nil
        }

        return .init(workspaceURL: workspaceURL, sdk: sdk)
    }
}
