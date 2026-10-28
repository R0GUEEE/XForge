import Foundation

/// Builds a project with the toolchain linked into this process — no guest, no
/// subprocess.
///
/// The stages mirror the Alpine executor it replaces, because the pipeline's
/// shape (provision → SDK → configure → resolve → compile → package) is what the
/// Build screen presents; what changed is where the work happens. Everything here
/// is a library call in XForge's own process:
///
///  - `swift-frontend` through `swift::performFrontend`,
///  - `clang` through `CompilerInvocation` + `EmitObjAction`,
///  - `ld64.lld` through `lld::lldMain`,
///  - the Darwin SDK read straight out of the app sandbox.
///
/// What it deliberately does *not* do is invent capability. Resolving SwiftPM
/// dependencies and compiling asset catalogs both need a package manager and
/// `actool`, neither of which can run on iOS, so the plan factory refuses those
/// projects by name instead of failing halfway through a build.
@MainActor
final class NativeBuildExecutor: BuildExecutor {
    private let stagingDirectory: URL
    private let fileManager: FileManager

    init(
        stagingDirectory: URL = XForgeEnvironment.stagingDirectory,
        fileManager: FileManager = .default
    ) {
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
    }

    // MARK: - Bootstrap

    func bootstrap() async throws -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let capabilities = NativeToolchainCapabilities.current
                continuation.yield(.plan("Checking the native toolchain…"))
                for line in capabilities.report {
                    continuation.yield(.output(line))
                }

                guard capabilities.canCompile else {
                    continuation.yield(.failed(capabilities.unavailableReason ?? "The native compiler is unavailable."))
                    continuation.finish()
                    return
                }

                continuation.yield(.plan("Checking the Darwin SDK…"))
                do {
                    let layout = try NativeSDK.layout()
                    continuation.yield(.output("✓ SDK \(layout.sdkRoot.lastPathComponent)"))
                    if !capabilities.hasSwiftFrontend {
                        continuation.yield(.output(
                            "! The Swift frontend is not linked into this build: "
                            + "C and Objective-C sources compile, Swift does not."
                        ))
                    }
                } catch {
                    continuation.yield(.failed(
                        "\(error.localizedDescription) Install it from the Toolchain screen."
                    ))
                    continuation.finish()
                    return
                }

                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }

    // MARK: - SDK

    func installSDK(from source: SDKSource) async throws {
        switch source {
        case .hostedRemote(let url):
            try await NativeSDK.install(fromRemote: url)
        case .bundled:
            _ = try await BundledDarwinSDK.installBundled()
        }
    }

    // MARK: - Project creation

    /// Write a new package into the app's own container.
    ///
    /// The template is the smallest thing that both SwiftPM and this driver
    /// understand: a `Package.swift` with one executable product, one SwiftUI
    /// entry point, and the app metadata XForge keeps in `xtool.yml`.
    func createProject(named name: String, organizationIdentifier: String) async throws -> Project {
        let validated = try Project.validatedName(name)
        let project = Project(
            name: validated,
            organizationIdentifier: organizationIdentifier,
            rootPath: Project.path(forValidatedName: validated)
        )
        let root = project.rootURL
        let sources = root.appendingPathComponent("Sources/\(validated)", isDirectory: true)

        guard !fileManager.fileExists(atPath: root.path) else {
            throw NativeBuildError.projectAlreadyExists(root)
        }
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)

        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(validated)",
            platforms: [.iOS(.v17)],
            products: [
                .executable(name: "\(validated)", targets: ["\(validated)"])
            ],
            targets: [
                .executableTarget(
                    name: "\(validated)",
                    path: "Sources/\(validated)"
                )
            ]
        )
        """
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let entry = """
        import SwiftUI

        @main
        struct \(validated)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 12) {
                    Image(systemName: "hammer.fill").font(.largeTitle)
                    Text("\(validated)").font(.title2.bold())
                    Text("Built by XForge on device.").foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        """
        try entry.write(
            to: sources.appendingPathComponent("\(validated)App.swift"),
            atomically: true,
            encoding: .utf8
        )

        let metadata = """
        name: \(validated)
        bundleIdentifier: \(organizationIdentifier).\(validated)
        deploymentTarget: "17.0"
        """
        try metadata.write(
            to: root.appendingPathComponent("xtool.yml"),
            atomically: true,
            encoding: .utf8
        )

        return project
    }

    // MARK: - Resolve

    func resolve(_ project: Project) -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    if project.isXcodeProject {
                        let plan = try XcodeProjectBuildPlanner.makePlan(
                            project: project, configuration: .debug
                        )
                        continuation.yield(.plan("Checking supported Xcode target…"))
                        continuation.yield(.output("Target \(plan.appName), \(plan.swiftSources.count) Swift files; scripts/resources/dependencies are not reproduced."))
                    } else {
                        let manifest = project.rootURL.appendingPathComponent("Package.swift")
                        let dependencies = try NativeBuildPlanFactory.swiftPackageDependencies(manifestURL: manifest)
                        let modules: [NativeSwiftDependencyPlan]
                        do {
                            modules = try NativeBuildPlanFactory.swiftDependencyModules(
                                root: project.rootURL, declaredNames: dependencies
                            )
                        } catch let planError as NativeBuildPlanError {
                            guard case .dependencySourceMissing = planError else { throw planError }
                            continuation.yield(.plan("Fetching verified pinned dependency sources…"))
                            let lockURL = project.rootURL.appendingPathComponent("Package.resolved")
                            let lock = try ResolvedPackageLockfile.read(contentsOf: lockURL)
                            _ = try await PinnedDependencySourceInstaller.installPinnedSources(for: project, pins: lock.pins)
                            modules = try NativeBuildPlanFactory.swiftDependencyModules(
                                root: project.rootURL, declaredNames: dependencies
                            )
                        }
                        continuation.yield(.plan("Preparing dependency modules…"))
                        if modules.isEmpty {
                            continuation.yield(.output("No package dependencies: nothing to resolve."))
                        } else {
                            for module in modules {
                                continuation.yield(.output("verified \(module.identity) @ \(module.revision.prefix(12)); module will be built in-process"))
                            }
                        }
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Build

    func build(
        _ project: Project,
        configuration: BuildConfiguration
    ) -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try await self.build(project, configuration: configuration) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    /// The pipeline proper. Kept off the stream so failures can use `throw` and
    /// carry their diagnostics, rather than being flattened into a string.
    private func build(
        _ project: Project,
        configuration: BuildConfiguration,
        emit: @MainActor (BuildEvent) -> Void
    ) async throws {
        let capabilities = NativeToolchainCapabilities.current
        guard capabilities.canCompile else {
            throw NativeBuildError.toolchainUnavailable(capabilities.unavailableReason)
        }

        let sdk = try NativeSDK.layout()
        let appInfo: AppInfo
        let plan: NativeBuildPlan
        if project.isXcodeProject {
            plan = try XcodeProjectBuildPlanner.makePlan(project: project, configuration: configuration)
            appInfo = XcodeProjectBuildPlanner.appInfo(from: plan)
        } else {
            appInfo = project.appInfo ?? .default(for: project)
            plan = try NativeBuildPlanFactory.makePlan(
                root: project.rootURL, appInfo: appInfo, configuration: configuration, sdk: sdk
            )
        }

        emit(.plan("Compiling \(plan.moduleName) for arm64-apple-ios\(plan.minimumIOSVersion)…"))
        emit(.output("\(plan.swiftSources.count) Swift, \(plan.clangSources.count) C, \(plan.resources.count) resource files"))

        if plan.hasSwift, !capabilities.hasSwiftFrontend {
            throw NativeBuildError.swiftFrontendMissing(plan.swiftSources.count + plan.swiftDependencies.reduce(0) { $0 + $1.sources.count })
        }

        let buildDirectory = project.rootURL.appendingPathComponent(".xforge-build", isDirectory: true)
        try? fileManager.removeItem(at: buildDirectory)
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)

        var objects: [URL] = []
        let dependencyModuleDirectories = plan.swiftDependencies.map { dependency in
            buildDirectory.appendingPathComponent("Dependencies/\(dependency.moduleName)", isDirectory: true)
        }

        // Build each audited dependency as a real Swift module before compiling
        // the app. No package manifest is evaluated here: the plan carries a
        // fixed source list derived from a verified lock pin/profile.
        for (index, dependency) in plan.swiftDependencies.enumerated() {
            let moduleDirectory = dependencyModuleDirectories[index]
            try fileManager.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
            let moduleFile = moduleDirectory.appendingPathComponent("\(dependency.moduleName).swiftmodule")
            let moduleArguments = try NativeToolchainInvocation.swiftModuleArguments(
                moduleName: dependency.moduleName,
                sources: dependency.sources,
                moduleOutput: moduleFile,
                minimumIOSVersion: plan.minimumIOSVersion,
                sdk: sdk,
                swiftVersion: "5"
            )
            emit(.output("swift-frontend emit-module \(dependency.moduleName) (\(dependency.sources.count) files)"))
            let moduleResult = try await runDetached {
                try NativeToolchain.runSwiftFrontend(arguments: moduleArguments)
            }
            try check(moduleResult, tool: "swift-frontend module \(dependency.moduleName)", source: dependency.sources[0])
            guard fileManager.fileExists(atPath: moduleFile.path) else {
                throw NativeBuildError.dependencyModuleMissing(dependency.moduleName)
            }

            var dependencyPlan = plan
            dependencyPlan.moduleName = dependency.moduleName
            dependencyPlan.swiftSources = dependency.sources
            dependencyPlan.swiftDependencies = []
            for source in dependency.sources {
                let object = moduleDirectory.appendingPathComponent(objectName(for: source))
                let arguments = try NativeToolchainInvocation.swiftFrontendArguments(
                    source: source,
                    object: object,
                    plan: dependencyPlan,
                    sdk: sdk,
                    compilationUnitSources: dependency.sources,
                    additionalImportPaths: [moduleDirectory]
                )
                emit(.output("swift-frontend \(dependency.moduleName)/\(source.lastPathComponent)"))
                let result = try await runDetached {
                    try NativeToolchain.runSwiftFrontend(arguments: arguments)
                }
                try check(result, tool: "swift-frontend \(dependency.moduleName)", source: source)
                objects.append(object)
            }
        }

        for source in plan.swiftSources {
            let object = buildDirectory
                .appendingPathComponent(objectName(for: source))
            let arguments = try NativeToolchainInvocation.swiftFrontendArguments(
                source: source,
                object: object,
                plan: plan,
                sdk: sdk,
                compilationUnitSources: plan.swiftSources,
                additionalImportPaths: dependencyModuleDirectories
            )
            emit(.output("swift-frontend \(source.lastPathComponent)"))
            let result = try await runDetached {
                try NativeToolchain.runSwiftFrontend(arguments: arguments)
            }
            try check(result, tool: "swift-frontend", source: source)
            objects.append(object)
        }

        for source in plan.clangSources {
            let object = buildDirectory
                .appendingPathComponent(objectName(for: source.url))
            emit(.output("clang \(source.url.lastPathComponent)"))
            let result = try await runDetached {
                try NativeToolchain.compileC(
                    source: source.url,
                    object: object,
                    sdk: sdk.sdkRoot,
                    target: NativeToolchainInvocation.targetTriple(
                        minimumIOSVersion: plan.minimumIOSVersion
                    ),
                    language: source.language
                )
            }
            try check(result, tool: "clang", source: source.url)
            objects.append(object)
        }

        let executable = buildDirectory.appendingPathComponent(plan.executableName)
        emit(.plan("Linking \(plan.executableName)…"))
        let linkerArguments = NativeToolchainInvocation.linkerArguments(
            objects: objects,
            plan: plan,
            sdk: sdk,
            executable: executable
        )
        let linkResult = try await runDetached {
            try NativeToolchain.linkMachO(arguments: linkerArguments)
        }
        guard linkResult.succeeded else {
            throw NativeBuildError.linkFailed(linkResult.diagnostics)
        }
        emit(.output("ld64.lld → \(plan.executableName)"))

        let bundle = try assembleBundle(plan: plan, executable: executable, emit: emit)
        let ipa = try IPABuilder.buildIPA(
            appBundle: bundle,
            appInfo: appInfo,
            outputDir: buildDirectory
        )

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staged = stagingDirectory.appendingPathComponent("\(project.name)-\(appInfo.version).ipa")
        try? fileManager.removeItem(at: staged)
        try fileManager.copyItem(at: ipa, to: staged)

        emit(.output("Packaged \(staged.lastPathComponent) (unsigned — sign it on the Signing screen)."))
        emit(.artifact(staged))
        emit(.finished)
    }

    // MARK: - Bundle assembly

    /// `<AppName>.app` with the executable, an Info.plist and the resources.
    private func assembleBundle(
        plan: NativeBuildPlan,
        executable: URL,
        emit: @MainActor (BuildEvent) -> Void
    ) throws -> URL {
        let bundle = plan.root
            .appendingPathComponent(".xforge-build", isDirectory: true)
            .appendingPathComponent("\(plan.appName).app", isDirectory: true)
        if fileManager.fileExists(atPath: bundle.path) {
            try fileManager.removeItem(at: bundle)
        }
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let destination = bundle.appendingPathComponent(plan.executableName)
        try fileManager.copyItem(at: executable, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        var info: [String: Any] = [
            "CFBundleIdentifier": plan.bundleIdentifier,
            "CFBundleName": plan.moduleName,
            "CFBundleDisplayName": plan.appName,
            "CFBundleExecutable": plan.executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": plan.version,
            "CFBundleVersion": plan.buildNumber,
            "MinimumOSVersion": plan.minimumIOSVersion,
            "LSRequiresIPhoneOS": true,
            "UIDeviceFamily": [1],
            "UILaunchScreen": [String: Any](),
            "UIRequiredDeviceCapabilities": ["arm64"],
        ]
        // A project's own Info.plist wins over the generated keys, which is what
        // makes hand-written scene manifests and orientations survive a build.
        if let template = plan.infoPlistTemplate,
           let data = try? Data(contentsOf: template),
           let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] {
            info.merge(decoded) { _, project in project }
        }

        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Info.plist"), options: .atomic)

        for dependency in plan.swiftDependencies where !dependency.resources.isEmpty {
            let resourceBundle = bundle.appendingPathComponent(dependency.resourceBundleName, isDirectory: true)
            try fileManager.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
            let resourceInfo: [String: Any] = [
                "CFBundleIdentifier": "\(plan.bundleIdentifier).\(dependency.identity).resources",
                "CFBundleName": dependency.moduleName,
                "CFBundlePackageType": "BNDL"
            ]
            let resourcePlist = try PropertyListSerialization.data(fromPropertyList: resourceInfo,
                                                                  format: .xml, options: 0)
            try resourcePlist.write(to: resourceBundle.appendingPathComponent("Info.plist"), options: .atomic)
            for resource in dependency.resources {
                try fileManager.copyItem(at: resource,
                    to: resourceBundle.appendingPathComponent(resource.lastPathComponent))
            }
            emit(.output("Bundled resources for \(dependency.moduleName) (\(dependency.resources.count) files)."))
        }

        for resource in plan.resources {
            if resource.pathExtension.lowercased() == "xcassets" {
                // There is no actool on iOS: asset catalogs are compiled by a
                // macOS-only tool. Copy the catalog so the project round-trips
                // and say plainly what is missing rather than shipping an app
                // whose icon silently vanishes.
                emit(.output(
                    "! \(resource.lastPathComponent) was copied uncompiled: "
                    + "asset catalogs need actool, which cannot run on iOS."
                ))
            }
            let target = bundle.appendingPathComponent(resource.lastPathComponent)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: resource, to: target)
        }

        return bundle
    }

    // MARK: - Helpers

    private func objectName(for source: URL) -> String {
        // Path separators cannot appear in a file name, and two sources with the
        // same last path component would otherwise collide.
        source.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            + ".o"
    }

    private func check(_ result: NativeToolchainResult, tool: String, source: URL) throws {
        guard result.succeeded else {
            throw NativeBuildError.compileFailed(
                tool: tool,
                source: source,
                diagnostics: result.diagnostics
            )
        }
    }

    /// Run a blocking compiler call off the main actor. The frontend and linker
    /// are synchronous C++ entry points: a large module can take seconds, and the
    /// UI must keep drawing while it does.
    private func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}

enum NativeBuildError: LocalizedError {
    case toolchainUnavailable(String?)
    case swiftFrontendMissing(Int)
    case dependencyModuleMissing(String)
    case projectAlreadyExists(URL)
    case missingProjectDirectory(URL)
    case compileFailed(tool: String, source: URL, diagnostics: String)
    case linkFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolchainUnavailable(let reason):
            return reason ?? "The native compiler toolchain is not linked into this build."
        case .swiftFrontendMissing(let count):
            return """
            \(count) Swift source file(s) must be compiled, but the Swift frontend \
            is not linked into this build of XForge. Only the C/C++/Objective-C \
            half of the toolchain is present.
            """
        case .dependencyModuleMissing(let name):
            return "The Swift frontend did not emit the expected \(name).swiftmodule; refusing to compile the app against a missing dependency module."
        case .projectAlreadyExists(let url):
            return "A project already exists at \(url.path)."
        case .missingProjectDirectory(let url):
            return "The project directory is missing: \(url.path)."
        case .compileFailed(let tool, let source, let diagnostics):
            let text = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = text.isEmpty ? "\(tool) reported a failure without diagnostics." : text
            return "\(source.lastPathComponent): \(detail)"
        case .linkFailed(let diagnostics):
            let text = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "The linker failed without diagnostics." : text
        }
    }
}
