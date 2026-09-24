import Foundation
import PathKit
import XcodeProj

/// A read-only view of an existing Xcode project (`Foo.xcodeproj`).
///
/// This is the foundation of the "Xcode alternative" path: an Xcode project file
/// is the only description of what an existing app is made of, and it is a plain
/// property list, so it can be read on-device — no Mac, no `xcodebuild`.
/// `tuist/XcodeProj` is pure Swift and (like XKit) declares iOS 17, which is where
/// the app's own floor comes from.
///
/// It answers the questions a build driver has to ask first: which targets are
/// there, what they produce, which sources they compile, and what their build
/// settings are after the project's own inheritance rules — project settings,
/// project xcconfig, target xcconfig, target settings, in Xcode's order.
///
/// Deliberately *not* here yet:
///  - anything that compiles (see `NativeToolchain`/`EmbeddedLinuxExecutor`);
///  - `$(...)` evaluation, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`-style variants and
///    `[config=...]` conditions: values are reported as written;
///  - schemes, asset catalogs and storyboards. `actool`/`ibtool` are Xcode's own
///    tools and have no iOS build, so an app that needs them cannot be built
///    on-device at all — see Docs/XCODE-ALTERNATIVE.md.
struct XcodeTargetSummary: Identifiable, Sendable {
    /// The target name, which is unique inside a project.
    let id: String
    let name: String
    /// `PBXProductType` raw value, e.g. `com.apple.product-type.application`.
    let productType: String
    let productName: String
    let bundleIdentifier: String?
    let deploymentTarget: String?
    /// Project-relative paths, as they appear in the project's groups.
    let sourceFiles: [String]
    /// The `.xcconfig` files that feed this target, outermost first.
    let xcconfigPaths: [String]
    /// The merged settings for the target's default configuration.
    let buildSettings: [String: String]
    let configurationNames: [String]
    let defaultConfiguration: String?

    var isApplication: Bool { productType == PBXProductType.application.rawValue }
    var containsSwift: Bool { sourceFiles.contains { $0.hasSuffix(".swift") } }
}

struct XcodeProjectSummary: Sendable {
    /// The `.xcodeproj` bundle itself.
    let projectURL: URL
    /// The directory holding it, which is the source root of a relative path.
    let projectDirectory: URL
    let name: String
    let targets: [XcodeTargetSummary]

    var applicationTargets: [XcodeTargetSummary] { targets.filter(\.isApplication) }
}

enum XcodeProjectError: LocalizedError {
    case notFound(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No Xcode project was found at \(path)."
        case .malformed(let reason):
            return "The Xcode project could not be read: \(reason)"
        }
    }
}

enum XcodeProjectReader {
    /// Read `url`, which may be the `.xcodeproj` itself or a directory holding one.
    static func read(at url: URL) throws -> XcodeProjectSummary {
        let projectURL = try locate(from: url)

        let project: XcodeProj
        do {
            project = try XcodeProj(path: Path(projectURL.path))
        } catch {
            throw XcodeProjectError.malformed(error.localizedDescription)
        }
        guard let root = project.pbxproj.rootObject else {
            throw XcodeProjectError.malformed("the project file has no root object")
        }

        let sourceDirectory = projectURL.deletingLastPathComponent()
        var paths: [ObjectIdentifier: String] = [:]
        if let mainGroup = root.mainGroup {
            index(mainGroup, prefix: "", into: &paths)
        }

        let targets = root.targets.map {
            summarize($0, in: root, paths: paths, sourceDirectory: sourceDirectory)
        }

        return XcodeProjectSummary(
            projectURL: projectURL,
            projectDirectory: sourceDirectory,
            name: root.name,
            targets: targets
        )
    }

    // MARK: - Locating

    private static func locate(from url: URL) throws -> URL {
        if url.pathExtension == "xcodeproj" { return url }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let projects = entries
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let project = projects.first else { throw XcodeProjectError.notFound(url.path) }
        guard projects.count == 1 else {
            // Guessing would compile the wrong app, so say which files are there.
            throw XcodeProjectError.malformed(
                "\(url.lastPathComponent) contains \(projects.count) Xcode projects "
                + "(\(projects.map(\.lastPathComponent).joined(separator: ", "))); name the one to build"
            )
        }
        return project
    }

    // MARK: - Sources

    /// Walk the project's group tree once, so a source file can be reported with the
    /// path it has inside the project rather than the single component its build
    /// phase records.
    private static func index(
        _ element: PBXFileElement,
        prefix: String,
        into paths: inout [ObjectIdentifier: String]
    ) {
        let component = element.path ?? element.name ?? ""
        let full = component.isEmpty ? prefix : (prefix.isEmpty ? component : prefix + "/" + component)
        paths[ObjectIdentifier(element)] = full

        guard let group = element as? PBXGroup else { return }
        for child in group.children {
            index(child, prefix: full, into: &paths)
        }
    }

    // MARK: - Targets

    private static func summarize(
        _ target: PBXTarget,
        in root: PBXProject,
        paths: [ObjectIdentifier: String],
        sourceDirectory: URL
    ) -> XcodeTargetSummary {
        let configurations = target.buildConfigurationList?.buildConfigurations ?? []
        let projectConfigurations = root.buildConfigurationList?.buildConfigurations ?? []
        let defaultName = target.buildConfigurationList?.defaultConfigurationName
            ?? root.buildConfigurationList?.defaultConfigurationName
        let chosen = configurations.first { $0.name == defaultName } ?? configurations.first

        var settings: [String: String] = [:]
        var xcconfigs: [String] = []
        // Xcode's precedence: the project's settings are the base, the target's win
        // over them, and inside each pair the xcconfig is the base.
        if let configuration = projectConfigurations.first(where: { $0.name == chosen?.name })
            ?? projectConfigurations.first {
            let (values, referenced) = resolve(configuration, sourceDirectory: sourceDirectory)
            settings.merge(values) { _, target in target }
            xcconfigs.append(contentsOf: referenced)
        }
        if let chosen {
            let (values, referenced) = resolve(chosen, sourceDirectory: sourceDirectory)
            settings.merge(values) { _, target in target }
            xcconfigs.append(contentsOf: referenced)
        }

        let sources = target.buildPhases
            .compactMap { $0 as? PBXSourcesBuildPhase }
            .flatMap { $0.files ?? [] }
            .compactMap { buildFile -> String? in
                guard let file = buildFile.file else { return nil }
                // Identity lookup first: the same element is reachable from the group
                // tree and from the build phase. Fall back to the recorded path, which
                // is at least the file's own name.
                return paths[ObjectIdentifier(file)] ?? file.path
            }

        return XcodeTargetSummary(
            id: target.name,
            name: target.name,
            productType: target.productType?.rawValue ?? "",
            productName: settings["PRODUCT_NAME"] ?? target.productName ?? target.name,
            bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"],
            deploymentTarget: settings["IPHONEOS_DEPLOYMENT_TARGET"],
            sourceFiles: Array(Set(sources)).sorted(),
            xcconfigPaths: xcconfigs,
            buildSettings: settings,
            configurationNames: configurations.map(\.name),
            defaultConfiguration: chosen?.name
        )
    }

    // MARK: - Build settings

    private static func resolve(
        _ configuration: XCBuildConfiguration,
        sourceDirectory: URL
    ) -> ([String: String], [String]) {
        var settings = flatten(configuration.buildSettings)
        var paths: [String] = []

        guard let relative = configuration.baseConfigurationReferenceRelativePath else {
            return (settings, paths)
        }
        let url = sourceDirectory.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path),
              let xcconfig = try? XCConfig(
                path: Path(url.path),
                projectPath: Path(sourceDirectory.path)
              ) else {
            return (settings, paths)
        }

        paths.append(relative)
        paths.append(contentsOf: xcconfig.includes.map { $0.include.string })
        // The xcconfig is the base of its layer; the project file's own settings win.
        settings.merge(flatten(xcconfig)) { _, declared in declared }
        return (settings, paths)
    }

    private static func flatten(_ xcconfig: XCConfig) -> [String: String] {
        var settings: [String: String] = [:]
        for included in xcconfig.includes {
            settings.merge(flatten(included.config)) { _, new in new }
        }
        settings.merge(flatten(xcconfig.buildSettings)) { _, new in new }
        return settings
    }

    private static func flatten(_ buildSettings: BuildSettings) -> [String: String] {
        var settings: [String: String] = [:]
        for (key, value) in buildSettings {
            if let string = value.stringValue {
                settings[key] = string
            } else if let array = value.arrayValue {
                settings[key] = array.joined(separator: " ")
            } else if let flag = value.boolValue {
                settings[key] = flag ? "YES" : "NO"
            }
        }
        return settings
    }
}
