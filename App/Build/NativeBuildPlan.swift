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
        swiftSources.isEmpty && clangSources.isEmpty
    }

    var hasSwift: Bool { !swiftSources.isEmpty }
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
            return """
            This project declares SwiftPM dependencies (\(list)\(more)). Resolving \
            them needs a package manager, which cannot run inside an app that may \
            not spawn processes. Remove the dependencies, or build a project whose \
            sources are self-contained.
            """
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

        // Dependencies are the one thing an in-process driver cannot resolve:
        // SwiftPM resolves them by fetching and *running* package manifests.
        // Refuse them by name instead of failing somewhere further down.
        let dependencies = try swiftPackageDependencies(manifestURL: manifest)
        if !dependencies.isEmpty {
            throw NativeBuildPlanError.unsupportedSwiftPackageDependencies(dependencies)
        }

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
        if !swiftSources.isEmpty {
            // A Swift executable links the Swift runtime statically: the Darwin
            // SDK bundle carries it, and there is no dyld-shared runtime on a
            // sideloaded device build.
            searchPaths.append(contentsOf: sdk.swiftRuntimeLibraryPaths)
            frameworks.append("UIKit")
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
            clangSources: clangSources,
            resources: resources,
            infoPlistTemplate: hasTemplate ? template : nil,
            frameworks: frameworks,
            librarySearchPaths: searchPaths,
            frameworkSearchPaths: frameworkSearchPaths
        )
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
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".package(") else { continue }
            if let name = quotedName(in: trimmed) {
                names.append(name)
            } else {
                names.append("an unnamed package")
            }
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
