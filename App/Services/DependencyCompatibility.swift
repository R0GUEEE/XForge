import Foundation

/// Shared compatibility vocabulary for the dependency UI and build diagnostics.
enum CompatibilityState: String, Codable, Sendable {
    case supported
    case partial
    case unsupported
    case unknown
}

struct CompatibilityFinding: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let state: CompatibilityState
    let summary: String
    let detail: String
}

struct DependencyCompatibilityReport: Codable, Equatable, Sendable {
    let analyzedAt: Date
    let projectKind: ProjectKind
    let lockfiles: [String]
    let pinnedPackageCount: Int
    let githubPinnedPackageCount: Int
    let unavailablePackageCount: Int
    let dependencySourceDirectories: [String]
    let findings: [CompatibilityFinding]

    var canFetchPinnedSources: Bool { githubPinnedPackageCount > 0 }
    /// Intentionally conservative: source availability does not mean the current
    /// one-module backend can compile/link arbitrary package products.
    var canBuildDependencies: Bool { false }
}

/// Performs static, non-executing project compatibility analysis. This type never
/// evaluates Package.swift, invokes plugins, or shells out to package managers.
enum DependencyCompatibilityAnalyzer {
    static let maximumLockfiles = 16
    static let maximumLockfileBytes = 4 * 1024 * 1024

    static func analyze(project: Project) -> DependencyCompatibilityReport {
        let root = project.isXcodeProject ? project.snapshotRootURL : project.rootURL
        let lockURLs = findLockfiles(root: root)
        var packageCount = 0
        var githubCount = 0
        var unavailable = 0
        var directories: [String] = []
        var findings: [CompatibilityFinding] = []

        if project.isXcodeProject {
            findings.append(.init(id: "xcode-project", state: .unsupported,
                                  summary: "Xcode project build is not implemented",
                                  detail: "XForge can inspect and export a limited Xcode handoff, but it cannot reproduce the original target graph or build phases."))
        } else {
            findings.append(.init(id: "swiftpm-driver", state: .partial,
                                  summary: "SwiftPM build support is restricted",
                                  detail: "XForge does not execute Package.swift. The current compiler backend builds a limited single-module source set."))
        }

        if lockURLs.isEmpty {
            findings.append(.init(id: "lockfile-missing", state: .unknown,
                                  summary: "No Package.resolved lockfile found",
                                  detail: "Floating package requirements cannot be reproducibly installed without a committed lockfile."))
        } else {
            for url in lockURLs.prefix(maximumLockfiles) {
                let relative = GitHubSnapshotDetector.relativePath(of: url, in: root) ?? url.lastPathComponent
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = (attrs[.size] as? NSNumber)?.intValue, size <= maximumLockfileBytes,
                      let data = try? Data(contentsOf: url),
                      let lock = try? ResolvedPackageLockfile.read(data: data) else {
                    unavailable += 1
                    findings.append(.init(id: "invalid-lock-\(relative)", state: .unsupported,
                                          summary: "Could not safely parse \(relative)",
                                          detail: "The file is missing, too large, malformed, or uses an unsupported lockfile schema."))
                    continue
                }
                packageCount += lock.pins.count
                for pin in lock.pins {
                    guard pin.kind == .remoteSourceControl,
                          let repo = try? GitHubRepository.parse(pin.location),
                          isCommit(pin.revision) else {
                        unavailable += 1
                        findings.append(.init(id: "pin-\(relative)-\(pin.identity)", state: .unsupported,
                                              summary: "\(pin.identity) is not a supported pinned GitHub source",
                                              detail: "Only public github.com remoteSourceControl pins with a full immutable revision can be fetched. Registry, local, branch-only, and other-host pins are reported but not downloaded."))
                        continue
                    }
                    githubCount += 1
                    let dirName = "\(GitHubSnapshotImporter.sanitizedProjectName(pin.identity))-\(pin.revision.prefix(12))"
                    let installed = root.appendingPathComponent(".xforge-dependencies", isDirectory: true)
                        .appendingPathComponent(dirName, isDirectory: true)
                    if FileManager.default.fileExists(atPath: installed.path) { directories.append(".xforge-dependencies/\(dirName)") }
                    findings.append(.init(id: "pin-\(relative)-\(pin.identity)", state: .partial,
                                          summary: "Pinned source available for \(pin.identity)",
                                          detail: "Revision \(pin.revision.prefix(12)) is immutable and can be downloaded as a public GitHub source snapshot. Source acquisition does not make the dependency buildable: module emission, products, resources, and linking are not yet implemented."))
                    _ = repo
                }
            }
            if lockURLs.count > maximumLockfiles {
                findings.append(.init(id: "lockfile-limit", state: .unsupported,
                                      summary: "More than \(maximumLockfiles) lockfiles found",
                                      detail: "The scan limit was reached to bound work on imported repositories."))
            }
        }

        if githubCount > 0 {
            findings.append(.init(id: "module-linking", state: .unsupported,
                                  summary: "Pinned sources are not compiled or linked",
                                  detail: "The native backend currently emits app translation units only; it has no dependency module graph, -emit-module ordering, dependency search paths, resource bundles, or product linker integration."))
        }
        return DependencyCompatibilityReport(
            analyzedAt: Date(), projectKind: project.kind, lockfiles: lockURLs.map { GitHubSnapshotDetector.relativePath(of: $0, in: root) ?? $0.lastPathComponent },
            pinnedPackageCount: packageCount, githubPinnedPackageCount: githubCount,
            unavailablePackageCount: unavailable, dependencySourceDirectories: directories.sorted(),
            findings: findings
        )
    }

    static func findLockfiles(root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        let skipped: Set<String> = [".git", ".build", "Pods", "Carthage", "DerivedData", "node_modules"]
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent == "Package.resolved" { result.append(url); if result.count >= maximumLockfiles + 1 { break } }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
