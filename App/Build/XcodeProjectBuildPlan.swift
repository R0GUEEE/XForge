import Foundation

/// Converts a narrow, read-only Xcode target into the native compiler plan.
/// It does not interpret arbitrary Xcode build settings or pretend to implement
/// xcodebuild; any input outside the checked subset is rejected before compiling.
enum XcodeProjectBuildPlanner {
    private static let supportedImports: Set<String> = ["Foundation", "UIKit", "SwiftUI"]
    private static let maximumSources = 64
    private static let maximumSourceBytes: Int64 = 4 * 1024 * 1024

    static func makePlan(project: Project, configuration: BuildConfiguration) throws -> NativeBuildPlan {
        guard project.isXcodeProject else { throw XcodeProjectBuildError.unsupported("not an Xcode project") }
        let root = project.rootURL.standardizedFileURL
        let summary = try XcodeProjectReader.read(at: root)
        guard summary.projectDirectory.standardizedFileURL == root else {
            throw XcodeProjectBuildError.unsupported("the selected Xcode project is not rooted at the imported project directory")
        }
        let apps = summary.applicationTargets
        guard apps.count == 1, let target = apps.first else {
            throw XcodeProjectBuildError.unsupported("exactly one application target is required")
        }
        guard target.unsupportedBuildFeatures.isEmpty else {
            throw XcodeProjectBuildError.unsupported(target.unsupportedBuildFeatures.joined(separator: ", "))
        }
        guard target.xcconfigPaths.isEmpty else {
            throw XcodeProjectBuildError.unsupported("xcconfig files are not evaluated")
        }
        guard !target.sourceFiles.isEmpty, target.sourceFiles.count <= maximumSources,
              target.sourceFiles.allSatisfy({ $0.lowercased().hasSuffix(".swift") }) else {
            throw XcodeProjectBuildError.unsupported("only up to \(maximumSources) Swift source files are supported")
        }
        let sources = try target.sourceFiles.map { path -> URL in
            guard let safe = try? SnapshotArchiveExtractor.validatedRelativePath(path) else {
                throw XcodeProjectBuildError.unsafeSourcePath(path)
            }
            let url = root.appendingPathComponent(safe).standardizedFileURL
            guard isContained(url, by: root),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw XcodeProjectBuildError.unsafeSourcePath(path)
            }
            let resolved = url.resolvingSymlinksInPath()
            guard isContained(resolved, by: root.resolvingSymlinksInPath()) else {
                throw XcodeProjectBuildError.unsafeSourcePath(path)
            }
            return resolved
        }.sorted { $0.path < $1.path }
        let size = sources.reduce(Int64(0)) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        guard size <= maximumSourceBytes else {
            throw XcodeProjectBuildError.unsupported("Swift source exceeds the 4 MiB build limit")
        }
        let identifier = target.bundleIdentifier
        guard let identifier, isLiteralBundleID(identifier) else {
            throw XcodeProjectBuildError.unresolvedSetting("PRODUCT_BUNDLE_IDENTIFIER")
        }
        guard let minimumIOS = target.deploymentTarget, isLiteralVersion(minimumIOS) else {
            throw XcodeProjectBuildError.unresolvedSetting("IPHONEOS_DEPLOYMENT_TARGET")
        }
        guard !target.productName.isEmpty,
              !target.productName.contains("$("), !target.productName.contains("${") else {
            throw XcodeProjectBuildError.unresolvedSetting("PRODUCT_NAME")
        }
        let sourceImports = try imports(in: sources)
        let unsupported = sourceImports.subtracting(supportedImports)
        guard unsupported.isEmpty else {
            throw XcodeProjectBuildError.unsupported("imports outside the Foundation/UIKit/SwiftUI SDK subset: \(unsupported.sorted().joined(separator: ", "))")
        }
        let mainCount = try sources.reduce(0) { count, source in
            let text = try String(contentsOf: source, encoding: .utf8)
            return count + (text.range(of: #"@(?:main|UIApplicationMain)\b"#, options: .regularExpression) == nil ? 0 : 1)
        }
        guard mainCount == 1 else {
            throw XcodeProjectBuildError.unsupported("exactly one source-level @main or @UIApplicationMain entry point is required")
        }
        let pbx = summary.projectURL.appendingPathComponent("project.pbxproj")
        if let data = try? Data(contentsOf: pbx), let text = String(data: data, encoding: .utf8),
           text.contains("XCRemoteSwiftPackageReference") || text.contains("XCSwiftPackageProductDependency") {
            throw XcodeProjectBuildError.unsupported("Xcode-project Swift package product references are not mapped yet")
        }
        let module = sanitizedIdentifier(target.productName)
        let version = literal(target.buildSettings["MARKETING_VERSION"], fallback: "1.0")
        let build = literal(target.buildSettings["CURRENT_PROJECT_VERSION"], fallback: "1")
        var frameworks = ["Foundation"]
        for item in ["UIKit", "SwiftUI"] where sourceImports.contains(item) { frameworks.append(item) }
        return NativeBuildPlan(
            root: root, moduleName: module, appName: target.productName, executableName: module,
            bundleIdentifier: identifier, minimumIOSVersion: minimumIOS, version: version,
            buildNumber: build, configuration: configuration, swiftSources: sources,
            swiftDependencies: [], clangSources: [], resources: [], infoPlistTemplate: nil,
            frameworks: frameworks, librarySearchPaths: [], frameworkSearchPaths: []
        )
    }

    static func appInfo(from plan: NativeBuildPlan) -> AppInfo {
        AppInfo(bundleIdentifier: plan.bundleIdentifier, displayName: plan.appName,
                version: plan.version, buildNumber: plan.buildNumber,
                minimumOSVersion: plan.minimumIOSVersion)
    }

    private static func imports(in sources: [URL]) throws -> Set<String> {
        var result = Set<String>()
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2 {
                    result.insert(String(parts[1]).split(separator: ".").first.map(String.init) ?? String(parts[1]))
                }
            }
        }
        return result
    }

    private static func isContained(_ url: URL, by root: URL) -> Bool {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func isLiteralBundleID(_ value: String) -> Bool {
        guard !value.contains("$("), !value.contains("${") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let pieces = value.split(separator: ".")
        return pieces.count >= 2 && pieces.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    private static func isLiteralVersion(_ value: String) -> Bool {
        !value.contains("$(") && !value.contains("${") && !value.isEmpty
            && value.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func literal(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty, !value.contains("$("), !value.contains("${") else { return fallback }
        return value
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let identifier = String(value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return identifier.first?.isNumber == true ? "App_" + identifier : identifier
    }
}

enum XcodeProjectBuildError: LocalizedError {
    case unsupported(String)
    case unsafeSourcePath(String)
    case unresolvedSetting(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return "This Xcode project is outside XForge's supported build subset: \(reason). Xcode handoff remains available."
        case .unsafeSourcePath(let path): return "Xcode source path is missing or escapes the project directory: \(path)"
        case .unresolvedSetting(let key): return "Xcode build setting \(key) is missing or contains an unevaluated variable."
        }
    }
}
