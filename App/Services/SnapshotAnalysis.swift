import Foundation
import ZIPFoundation

/// Findings from a repository snapshot. Detection is intentionally evidence-based:
/// it never executes Package.swift, Podfile, scripts, plugins, or project phases.
struct SnapshotInventory: Codable, Equatable, Sendable {
    var fileCount: Int
    var directoryCount: Int
    var extractedBytes: Int64
    var skippedEntries: Int
    var xcodeProjects: [String]
    var workspaces: [String]
    var packageManifests: [String]
    var lockfiles: [String]
    var dependencyIndicators: [String]
    var lfsPointerFiles: [String]
    var scriptPhaseProjects: [String]
    var caseCollisionPaths: [String]
    var generatedAt: Date

    static func scan(root: URL, extraction: SnapshotExtractionStats? = nil) -> SnapshotInventory {
        let fm = FileManager.default
        let ignored: Set<String> = [".git", ".build", ".swiftpm", ".xforge-generated", "Pods", "Carthage", "DerivedData", "node_modules"]
        var files = 0, directories = 0
        var bytes: Int64 = 0
        var projects: [String] = [], workspaces: [String] = [], manifests: [String] = []
        var locks: [String] = [], deps = Set<String>(), lfs: [String] = [], scripts: [String] = []
        var caseNames: [String: String] = [:], collisions = Set<String>()
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: []) {
            while let url = e.nextObject() as? URL {
                let rel = relative(url, root)
                if ignored.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if v?.isDirectory == true {
                    directories += 1
                    if url.pathExtension == "xcodeproj" { projects.append(rel) }
                    if url.pathExtension == "xcworkspace" { workspaces.append(rel) }
                    continue
                }
                guard v?.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(v?.fileSize ?? 0)
                let folded = rel.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if let old = caseNames[folded], old != rel { collisions.insert(old); collisions.insert(rel) }
                else { caseNames[folded] = rel }
                let leaf = url.lastPathComponent
                if leaf == "Package.swift" {
                    manifests.append(rel)
                    if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(".package(") {
                        deps.insert("SwiftPM dependency declarations found; XForge does not evaluate Package.swift")
                    } else {
                        deps.insert("Swift package manifest found; XForge supports only a restricted dependency-free subset")
                    }
                }
                if ["Package.resolved", "Podfile.lock", "Cartfile.resolved"].contains(leaf) { locks.append(rel) }
                if leaf == ".gitmodules" { deps.insert("Git submodules declared (.gitmodules); GitHub ZIPs omit their contents") }
                if leaf == "Podfile" { deps.insert("CocoaPods declared; XForge does not run pod install") }
                if leaf == "Cartfile" { deps.insert("Carthage declared; no Carthage build is available on-device") }
                if leaf == ".gitattributes", let text = try? String(contentsOf: url, encoding: .utf8), text.localizedCaseInsensitiveContains("filter=lfs") {
                    deps.insert("Git LFS attributes found; pointer files may not be materialized")
                }
                if isLFSPointer(url) { lfs.append(rel) }
                if leaf == "project.pbxproj", let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PBXShellScriptBuildPhase") { scripts.append(rel) }
            }
        }
        if !workspaces.isEmpty {
            deps.insert("Xcode workspace files found; workspace-level project/package references are reported but not resolved")
        }
        return SnapshotInventory(fileCount: files, directoryCount: directories,
            extractedBytes: extraction?.bytes ?? bytes, skippedEntries: extraction?.skipped ?? 0,
            xcodeProjects: projects.sorted(), workspaces: workspaces.sorted(),
            packageManifests: manifests.sorted(), lockfiles: locks.sorted(),
            dependencyIndicators: deps.sorted(), lfsPointerFiles: lfs.sorted(),
            scriptPhaseProjects: scripts.sorted(), caseCollisionPaths: collisions.sorted(), generatedAt: Date())
    }

    private static func relative(_ url: URL, _ root: URL) -> String {
        let base = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == base ? "" : String(path.dropFirst(base.count + 1))
    }

    private static func isLFSPointer(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let bytes = (try? h.read(upToCount: 64)) ?? Data()
        return String(decoding: bytes, as: UTF8.self).hasPrefix("version https://git-lfs.github.com/spec/v1")
    }
}

/// Generates a deterministic, source-referencing Xcode handoff project for a
/// single Swift app target. This does NOT make the project buildable by XForge;
/// resources, settings, dependencies, workspaces and build phases stay explicit
/// in the accompanying report, and must be reviewed in Xcode.
enum XcodeProjectHandoff {
    struct Output: Sendable {
        let archiveURL: URL
        let projectFileCount: Int
        let notes: [String]
    }

    enum GenerationError: LocalizedError {
        case notSwiftApp
        case invalidBundleIdentifier
        case conflictingSwiftEntrypoints
        case missingSwiftEntrypoint
        case unresolvedSetting(String)
        case invalidDeploymentTarget(String)
        var errorDescription: String? {
            switch self {
            case .notSwiftApp: return "Handoff generation currently requires one Xcode application target with Swift sources."
            case .invalidBundleIdentifier: return "The target does not have a literal reverse-DNS bundle identifier; generated settings would be unsafe."
            case .conflictingSwiftEntrypoints: return "Multiple Swift files declare an app entry point. Resolve it before exporting."
            case .missingSwiftEntrypoint: return "No Swift @main or @UIApplicationMain entry point was found; this target may rely on generated sources or Objective-C main code."
            case .unresolvedSetting(let key): return "The Xcode target's \(key) uses an unevaluated build-setting expression. Review it in Xcode before handoff."
            case .invalidDeploymentTarget(let value): return "The deployment target \(value) is not a literal version; review it in Xcode."
            }
        }
    }

    static func export(project: Project, summary: XcodeProjectSummary,
                       inventory: SnapshotInventory) throws -> Output {
        let appTargets = summary.applicationTargets
        guard appTargets.count == 1, let target = appTargets.first else { throw GenerationError.notSwiftApp }
        guard target.bundleIdentifier.map(validBundleID) == true else { throw GenerationError.invalidBundleIdentifier }
        if let productName = target.buildSettings["PRODUCT_NAME"], productName.contains("$(") {
            throw GenerationError.unresolvedSetting("PRODUCT_NAME")
        }
        let minimumIOS = target.deploymentTarget ?? "17.0"
        guard validDeploymentTarget(minimumIOS) else { throw GenerationError.invalidDeploymentTarget(minimumIOS) }
        let sourceFiles = target.sourceFiles.filter { $0.lowercased().hasSuffix(".swift") }.sorted()
        guard !sourceFiles.isEmpty else { throw GenerationError.notSwiftApp }
        let mains = sourceFiles.filter { path in
            guard let text = try? String(contentsOf: project.rootURL.appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.range(of: #"@(?:main|UIApplicationMain)\b"#, options: .regularExpression) != nil
        }
        guard mains.count == 1 else {
            if mains.isEmpty { throw GenerationError.missingSwiftEntrypoint }
            throw GenerationError.conflictingSwiftEntrypoints
        }

        let name = safeName(target.productName)
        let generatedRoot = project.rootURL.appendingPathComponent(".xforge-generated", isDirectory: true)
        let bundle = generatedRoot.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let pbx = try makeProject(name: name, bundleID: target.bundleIdentifier!,
                                  sourceFiles: sourceFiles, minimumIOS: minimumIOS)
        try pbx.write(to: bundle.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let xcconfig = "// Generated by XForge as a starting point. Review before building.\nPRODUCT_BUNDLE_IDENTIFIER = \(target.bundleIdentifier!)\nIPHONEOS_DEPLOYMENT_TARGET = \(target.deploymentTarget ?? "17.0")\n"
        try xcconfig.write(to: generatedRoot.appendingPathComponent("\(name).xcconfig"), atomically: true, encoding: .utf8)
        let schemeDir = bundle.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemeDir, withIntermediateDirectories: true)
        let scheme = sharedScheme(name: name, targetID: id("target:\(name)"))
        try scheme.write(to: schemeDir.appendingPathComponent("\(name).xcscheme"), atomically: true, encoding: .utf8)
        let report = notes(project: project, target: target, inventory: inventory, sources: sourceFiles)
        try report.write(to: generatedRoot.appendingPathComponent("XFORGE-IMPORT-REPORT.md"), atomically: true, encoding: .utf8)
        let archive = try ProjectExporter.export(project)
        return Output(archiveURL: archive, projectFileCount: sourceFiles.count, notes: inventory.dependencyIndicators)
    }

    private static func validBundleID(_ value: String) -> Bool {
        let pieces = value.split(separator: ".")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return pieces.count >= 2 && pieces.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) && $0.first?.isLetter == true }
    }

    private static func validDeploymentTarget(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.count <= 3
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private static func safeName(_ raw: String) -> String {
        let out = raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" }
        let value = String(out)
        return value.first?.isLetter == true ? value : "App_\(value)"
    }

    private static func id(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llX%08X", hash, UInt32(truncatingIfNeeded: hash >> 17))
    }

    static func makeProject(name: String, bundleID: String, sourceFiles: [String], minimumIOS: String) throws -> String {
        guard validBundleID(bundleID) else { throw GenerationError.invalidBundleIdentifier }
        guard validDeploymentTarget(minimumIOS) else { throw GenerationError.invalidDeploymentTarget(minimumIOS) }
        var fileRefs: [String] = [], buildFiles: [String] = [], sourceIDs: [String] = []
        for path in sourceFiles {
            _ = try SnapshotArchiveExtractor.validatedRelativePath(path)
            let fileID = id("file:\(path)"), buildID = id("build:\(path)")
            fileRefs.append("\(fileID) = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(quoted("../\(path)")); sourceTree = SOURCE_ROOT; };")
            buildFiles.append("\(buildID) = { isa = PBXBuildFile; fileRef = \(fileID); };")
            sourceIDs.append(buildID)
        }
        fileRefs.append("\(id("xcconfig:\(name)")) = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = \(quoted("\(name).xcconfig")); sourceTree = SOURCE_ROOT; };")
        let projectID = id("project:\(name)"), groupID = id("group:\(name)"), productsID = id("products:\(name)")
        let targetID = id("target:\(name)"), productID = id("product:\(name)")
        let sourcePhaseID = id("sources:\(name)"), frameworkPhaseID = id("frameworks:\(name)"), resourcePhaseID = id("resources:\(name)")
        let projectDebug = id("project-debug:\(name)"), projectRelease = id("project-release:\(name)")
        let targetDebug = id("target-debug:\(name)"), targetRelease = id("target-release:\(name)")
        let projectList = id("project-list:\(name)"), targetList = id("target-list:\(name)")
        let xcconfigID = id("xcconfig:\(name)")
        let rootChildren = (sourceFiles.map { id("file:\($0)") } + [xcconfigID]).joined(separator: ", ")
        let sources = sourceIDs.joined(separator: ", ")
        let lines = [
            "// !$*UTF8*$!", "{ archiveVersion = 1; objectVersion = 56; objects = {",
            buildFiles.joined(separator: "\n"), fileRefs.joined(separator: "\n"),
            "\(groupID) = { isa = PBXGroup; children = (\(rootChildren), \(productsID), ); sourceTree = SOURCE_ROOT; };",
            "\(productsID) = { isa = PBXGroup; children = (\(productID), ); name = Products; sourceTree = SOURCE_ROOT; };",

            "\(sourcePhaseID) = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(sources), ); runOnlyForDeploymentPostprocessing = 0; };",
            "\(frameworkPhaseID) = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };",
            "\(resourcePhaseID) = { isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };",
            "\(productID) = { isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"\(name).app\"; sourceTree = BUILT_PRODUCTS_DIR; };",
            "\(targetID) = { isa = PBXNativeTarget; buildConfigurationList = \(targetList); buildPhases = (\(sourcePhaseID), \(frameworkPhaseID), \(resourcePhaseID), ); buildRules = (); dependencies = (); name = \"\(name)\"; productName = \"\(name)\"; productReference = \(productID); productType = \"com.apple.product-type.application\"; };",
            "\(projectDebug) = { isa = XCBuildConfiguration; buildSettings = { IPHONEOS_DEPLOYMENT_TARGET = \(minimumIOS); SDKROOT = iphoneos; }; name = Debug; };",
            "\(projectRelease) = { isa = XCBuildConfiguration; buildSettings = { IPHONEOS_DEPLOYMENT_TARGET = \(minimumIOS); SDKROOT = iphoneos; }; name = Release; };",
            "\(targetDebug) = { isa = XCBuildConfiguration; baseConfigurationReference = \(xcconfigID); buildSettings = { GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = \(minimumIOS); PRODUCT_BUNDLE_IDENTIFIER = \(quoted(bundleID)); PRODUCT_NAME = \(quoted(name)); SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = \"1,2\"; }; name = Debug; };",
            "\(targetRelease) = { isa = XCBuildConfiguration; baseConfigurationReference = \(xcconfigID); buildSettings = { GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = \(minimumIOS); PRODUCT_BUNDLE_IDENTIFIER = \(quoted(bundleID)); PRODUCT_NAME = \(quoted(name)); SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = \"1,2\"; }; name = Release; };",
            "\(projectList) = { isa = XCConfigurationList; buildConfigurations = (\(projectDebug), \(projectRelease), ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
            "\(targetList) = { isa = XCConfigurationList; buildConfigurations = (\(targetDebug), \(targetRelease), ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
            "\(projectID) = { isa = PBXProject; attributes = { LastUpgradeCheck = 1600; }; buildConfigurationList = \(projectList); compatibilityVersion = \"Xcode 14.0\"; mainGroup = \(groupID); productRefGroup = \(productsID); projectDirPath = \"\"; projectRoot = \"\"; targets = (\(targetID), ); };",
            "}; rootObject = \(projectID); }"
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ value: String) -> String { "\"\(escape(value))\"" }

    private static func sharedScheme(name: String, targetID: String) -> String {
        let ref = "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(targetID)\" BuildableName=\"\(name).app\" BlueprintName=\"\(name)\" ReferencedContainer=\"container:\(name).xcodeproj\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="1600" version="1.7">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(ref)</BuildActionEntry></BuildActionEntries></BuildAction>
          <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
          <LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(ref)</BuildableProductRunnable></LaunchAction>
          <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(ref)</BuildableProductRunnable></ProfileAction>
          <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
        </Scheme>
        """
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    private static func notes(project: Project, target: XcodeTargetSummary, inventory: SnapshotInventory, sources: [String]) -> String {
        let omittedSourceCount = target.sourceFiles.count - sources.count
        var lines = ["# XForge Xcode handoff", "", "Generated project: `\(safeName(target.productName)).xcodeproj`", "Source project: `\(project.origin?.repository ?? project.name)`", "", "This is a minimal, generated starting point—not a faithful reproduction of the original Xcode build. Review in Xcode before use. XForge does not build this generated project.", "", "## Included", "", "- Single application target: `\(target.name)`", "- \(sources.count) Swift files from the selected target", "- Bundle identifier: `\(target.bundleIdentifier ?? "unknown")`", "- Minimum iOS: `\(target.deploymentTarget ?? "17.0")`"]
        if omittedSourceCount > 0 { lines.append("- \(omittedSourceCount) non-Swift source files are omitted from the generated target.") }
        lines += ["", "## Detected but not resolved"]
        if inventory.dependencyIndicators.isEmpty { lines.append("") ; lines.append("- No supported dependency markers were detected.") }
        else { lines.append(contentsOf: inventory.dependencyIndicators.map { "- \($0)" }) }
        if !inventory.lfsPointerFiles.isEmpty {
            lines += ["", "## Git LFS", "", "- \(inventory.lfsPointerFiles.count) LFS pointer files remain pointer text; their large-file objects were not downloaded."]
        }
        if !inventory.caseCollisionPaths.isEmpty {
            lines += ["", "## Case-sensitive paths", "", "- Case-only collisions detected: \(inventory.caseCollisionPaths.joined(separator: ", ")). A case-insensitive destination may not preserve both names."]
        }
        if !inventory.workspaces.isEmpty {
            lines += ["", "## Workspaces", "", "- Workspace(s) detected: \(inventory.workspaces.joined(separator: ", ")). Workspace-level references were not translated."]
        }
        if !inventory.scriptPhaseProjects.isEmpty { lines += ["", "## Build scripts", "", "- Script build phases were detected. They are not included or executed."] }
        lines += ["", "## Not transferred into this generated project", "", "Original resources, localized groups, framework links, app extensions, entitlements, schemes, custom build settings, build scripts, CocoaPods/Carthage/SwiftPM dependency graphs, asset catalogs and storyboard compilation. The original repository is preserved separately in XForge.", ""]
        return lines.joined(separator: "\n")
    }
}
