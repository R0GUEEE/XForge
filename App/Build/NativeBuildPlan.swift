import Foundation

/// A resolved, self-contained description of what to compile and link.
///
/// The plan is the boundary between "reading a project" and "running a compiler".
/// It exists so the on-device driver is *not* a second build system: every source
/// file, framework and search path is decided here, and the executor only turns
/// this value into `swift-frontend` / `clang` / `ld64.lld` argument lists. That
/// split is what makes the argument construction testable on a simulator, where
/// no compiler libraries exist.
struct NativeBuildPlan: Sendable, Equatable {
    /// Directory holding `Package.swift` / the sources.
    var root: URL
    /// The product being built, e.g. `Sources/MyApp` → `MyApp`.
    var moduleName: String
    /// Display name of the produced app bundle (`<appName>.app`).
    var appName: String
    /// Mach-O executable name inside the bundle.
    var executableName: String
    var bundleIdentifier: String
    var minimumIOSVersion: String
    var version: String
    var buildNumber: String
    var configuration: BuildConfiguration

    /// Swift translation units, in a stable order.
    var swiftSources: [URL]
    /// Swift source modules built from verified, allowlisted pinned dependencies.
    var swiftDependencies: [NativeSwiftDependencyPlan]
    /// C / Objective-C / Objective-C++ translation units.
    var clangSources: [NativeClangSource]
    /// Files copied into the bundle unchanged.
    var resources: [URL]
    /// A hand-written Info.plist in the project, merged over the generated one.
    var infoPlistTemplate: URL?
    /// Frameworks every app needs; the plan adds the project's own on top.
    var frameworks: [String]
    /// Extra `-L` paths, e.g. the Swift runtime inside the Darwin SDK.
    var librarySearchPaths: [URL]
    /// Extra `-F` paths.
    var frameworkSearchPaths: [URL]

    var isEmpty: Bool {
        swiftSources.isEmpty && swiftDependencies.isEmpty && clangSources.isEmpty
    }

    var hasSwift: Bool { !swiftSources.isEmpty || !swiftDependencies.isEmpty }
}

struct NativeSwiftDependencyPlan: Sendable, Equatable {
    let identity: String
    let moduleName: String
    let revision: String
    let sources: [URL]
    let resources: [URL]
    let resourceBundleName: String
}

/// One non-Swift translation unit plus the language clang must be told to use.
struct NativeClangSource: Sendable, Equatable, Hashable {
    var url: URL
    /// `c`, `objective-c`, `c++`, `objective-c++`.
    var language: String

    static func language(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "c": return "c"
        case "m": return "objective-c"
        case "mm": return "objective-c++"
        case "cc", "cpp", "cxx": return "c++"
        default: return nil
        }
    }
}

enum NativeBuildPlanError: LocalizedError {
    case noSources(URL)
    case missingTargetsDirectory(URL)
    case unsupportedSwiftPackageDependencies([String])
    case dependencyLockfileMissing(URL)
    case dependencySourceMissing(String)
    case missingPackageManifest(URL)

    var errorDescription: String? {
        switch self {
        case .noSources(let root):
            return "No compilable sources were found under \(root.path)."
        case .missingTargetsDirectory(let root):
            return "This project has no Sources/ directory, so XForge cannot tell what to build (\(root.path))."
        case .unsupportedSwiftPackageDependencies(let names):
            let list = names.prefix(5).joined(separator: ", ")
            let more = names.count > 5 ? " and \(names.count - 5) more" : ""
            return "Only the exact pinned ZIPFoundation 0.9.19 profile is currently compiled in-process. Unsupported dependencies: \(list)\(more). XForge does not execute Package.swift, plugins, or build scripts."
        case .dependencyLockfileMissing(let url):
            return "This package declares a dependency but has no Package.resolved at \(url.path). Commit a lockfile, then use Project → Dependencies to fetch a supported pinned source. XForge will not resolve floating versions."
        case .dependencySourceMissing(let identity):
            return "The verified source snapshot for \(identity) is not installed. Open Project → Dependencies and fetch the pinned source before building."
        case .missingPackageManifest(let root):
            return "No Package.swift was found at \(root.path)."
        }
    }
}

/// Turns a project directory into a `NativeBuildPlan`.
///
/// Deliberately conservative: it reads the layout SwiftPM and `xtool new` produce
/// (`Package.swift`, `Sources/<Target>/**`) and refuses anything it cannot resolve
/// exactly, rather than guessing and producing a binary that links the wrong code.
enum NativeBuildPlanFactory {
    static func makePlan(
        root: URL,
        appInfo: AppInfo,
        configuration: BuildConfiguration,
        sdk: NativeSDKLayout,
        fileManager: FileManager = .default
    ) throws -> NativeBuildPlan {
        let manifest = root.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw NativeBuildPlanError.missingPackageManifest(root)
        }

        // Build only dependency shapes that have a verified, audited native module
        // profile. No manifest evaluation or general SwiftPM resolution happens here.
        let dependencies = try swiftPackageDependencies(manifestURL: manifest)
        let swiftDependencies = try swiftDependencyModules(
            root: root, declaredNames: dependencies, fileManager: fileManager
        )

        let sourcesRoot = root.appendingPathComponent("Sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourcesRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NativeBuildPlanError.missingTargetsDirectory(root)
        }

        let (moduleName, sourcesDirectory) = try target(in: sourcesRoot, fileManager: fileManager)
        let swiftSources = try files(in: sourcesDirectory, extensions: ["swift"], fileManager: fileManager)
        let clangSources = try files(
            in: sourcesDirectory,
            extensions: ["c", "m", "mm", "cc", "cpp", "cxx"],
            fileManager: fileManager
        ).compactMap { url -> NativeClangSource? in
            guard let language = NativeClangSource.language(for: url) else { return nil }
            return NativeClangSource(url: url, language: language)
        }

        guard !swiftSources.isEmpty || !clangSources.isEmpty else {
            throw NativeBuildPlanError.noSources(sourcesDirectory)
        }

        // Resources live next to the sources in the layouts XForge creates and in
        // the ones `xtool new` produces.
        let resources = try files(
            in: sourcesDirectory,
            extensions: ["xcassets", "json", "plist", "strings", "storyboard", "xib", "png", "jpg"],
            fileManager: fileManager
        ).filter { !$0.lastPathComponent.hasPrefix("Info.plist") }

        var searchPaths: [URL] = []
        var frameworkSearchPaths: [URL] = []
        var frameworks = ["Foundation"]
        if !swiftSources.isEmpty || !swiftDependencies.isEmpty {
            // A Swift executable links the Swift runtime statically: the Darwin
            // SDK bundle carries it, and there is no dyld-shared runtime on a
            // sideloaded device build.
            searchPaths.append(contentsOf: sdk.swiftRuntimeLibraryPaths)
            frameworks.append("UIKit")
        }
        if swiftDependencies.contains(where: { $0.moduleName == "ZIPFoundation" }) {
            frameworks.append("Compression")
        }

        let template = root.appendingPathComponent("Support/Info.plist")
        let hasTemplate = fileManager.fileExists(atPath: template.path)

        return NativeBuildPlan(
            root: root,
            moduleName: moduleName,
            appName: appInfo.displayName,
            executableName: moduleName,
            bundleIdentifier: appInfo.bundleIdentifier,
            minimumIOSVersion: appInfo.minimumOSVersion,
            version: appInfo.version,
            buildNumber: appInfo.buildNumber,
            configuration: configuration,
            swiftSources: swiftSources,
            swiftDependencies: swiftDependencies,
            clangSources: clangSources,
            resources: resources,
            infoPlistTemplate: hasTemplate ? template : nil,
            frameworks: frameworks,
            librarySearchPaths: searchPaths,
            frameworkSearchPaths: frameworkSearchPaths
        )
    }

    /// First audited in-process dependency module profile. The exact commit is tied
    /// to ZIPFoundation 0.9.19; a different pin is never guessed compatible.
    static let zipFoundationSupportedRevision = "02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0"

    static func swiftDependencyModules(
        root: URL,
        declaredNames: [String],
        fileManager: FileManager = .default
    ) throws -> [NativeSwiftDependencyPlan] {
        guard !declaredNames.isEmpty else { return [] }
        guard declaredNames.count == 1,
              declaredNames[0].caseInsensitiveCompare("ZIPFoundation") == .orderedSame else {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(declaredNames)
        }
        let lockURL = root.appendingPathComponent("Package.resolved")
        guard fileManager.fileExists(atPath: lockURL.path) else {
            throw NativeBuildPlanError.dependencyLockfileMissing(lockURL)
        }
        guard let lock = try? ResolvedPackageLockfile.read(contentsOf: lockURL),
              lock.pins.count == 1,
              let pin = lock.pins.first,
              pin.identity == "zipfoundation",
              pin.kind == .remoteSourceControl,
              pin.revision == zipFoundationSupportedRevision,
              pin.version == "0.9.19",
              let repository = try? GitHubRepository.parse(pin.location),
              repository.owner.lowercased() == "weichsel",
              repository.name.lowercased() == "zipfoundation" else {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(declaredNames)
        }

        let snapshot = PinnedDependencySourceInstaller.dependencyDirectory(for: pin, root: root)
        guard fileManager.fileExists(atPath: snapshot.path) else {
            throw NativeBuildPlanError.dependencySourceMissing("ZIPFoundation 0.9.19")
        }
        guard let marker = PinnedDependencySourceInstaller.readMarker(snapshot),
              marker.identity == pin.identity,
              marker.repository.lowercased() == "weichsel/zipfoundation",
              marker.revision == pin.revision,
              marker.archiveSHA256.count == 64 else {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(declaredNames)
        }

        let sourceRoot = snapshot.appendingPathComponent("Sources/ZIPFoundation", isDirectory: true)
        let sources = try files(in: sourceRoot, extensions: ["swift"], fileManager: fileManager)
        let sourceBytes = sources.reduce(Int64(0)) { total, url in
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
        guard (16...32).contains(sources.count), sourceBytes <= 1024 * 1024 else {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(declaredNames)
        }
        let resourceDirectory = sourceRoot.appendingPathComponent("Resources", isDirectory: true)
        let resourceEntries = (try? fileManager.contentsOfDirectory(
            at: resourceDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        guard resourceEntries.allSatisfy({ $0.lastPathComponent == "PrivacyInfo.xcprivacy" }),
              resourceEntries.count <= 1 else {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(declaredNames)
        }
        return [NativeSwiftDependencyPlan(identity: pin.identity, moduleName: "ZIPFoundation",
                                          revision: pin.revision, sources: sources,
                                          resources: resourceEntries,
                                          resourceBundleName: "ZIPFoundation_ZIPFoundation.bundle")]
    }

    /// The package's declared `.package(url: "…")` dependencies, by name.
    ///
    /// A text scan on purpose: a full manifest evaluation means compiling and
    /// *running* `Package.swift`, which is exactly what this path cannot do. The
    /// scan only needs to answer "are there any", which it does reliably; the
    /// names are for the error message.
    static func swiftPackageDependencies(manifestURL: URL) throws -> [String] {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var names: [String] = []
        for line in lines {
            guard let invocation = line.range(of: ".package(") else { continue }
            let arguments = String(line[invocation.upperBound...])
            if let name = quotedName(in: arguments) {
                names.append(name)
            } else {
                names.append("an unresolved package dependency")
            }
        }
        // Multi-line/dynamic declarations that the small scanner cannot classify
        // must be refused, never mistaken for a dependency-free package.
        if names.isEmpty, text.contains(".package") {
            return ["an unresolved package declaration"]
        }
        return names
    }

    /// The last quoted path-ish component of a `.package(...)` line, e.g.
    /// `…/swift-argument-parser.git` → `swift-argument-parser`.
    private static func quotedName(in line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: firstQuote)...]
        guard let lastQuote = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<lastQuote])
        var name = value
        if name.hasSuffix(".git") { name.removeLast(4) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return name.isEmpty ? nil : name
    }

    /// Pick the target to build. `Sources/<Target>` when there is exactly one, the
    /// project's own name when several exist, and the only directory otherwise.
    private static func target(
        in sourcesRoot: URL,
        fileManager: FileManager
    ) throws -> (name: String, directory: URL) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard !directories.isEmpty else {
            throw NativeBuildPlanError.noSources(sourcesRoot)
        }
        guard directories.count > 1 else {
            return (directories[0].lastPathComponent, directories[0])
        }
        // Several targets: the app target is the one named after the package,
        // which is the layout `xtool new` and XForge both produce.
        let packageName = sourcesRoot.deletingLastPathComponent().lastPathComponent
        if let match = directories.first(where: { $0.lastPathComponent == packageName }) {
            return (match.lastPathComponent, match)
        }
        throw NativeBuildPlanError.noSources(sourcesRoot)
    }

    /// Regular files with one of `extensions`, recursively, sorted by path.
    private static func files(
        in directory: URL,
        extensions: Set<String>,
        fileManager: FileManager
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            // Asset catalogs are directories, and they are copied whole.
            if extensions.contains("xcassets") {
                if url.pathExtension.lowercased() == "xcassets" {
                    found.append(url)
                    enumerator.skipDescendants()
                } else if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    found.append(url)
                }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
