import Foundation

/// The IDE's build compatibility is distinct from whether dependency source can
/// be inspected or downloaded. A green "fetched" state never implies "buildable".
enum DependencyCapability: String, Codable, Sendable {
    case ready
    case fetchable
    case unsupported
    case unknown
}

struct DependencyCompatibilityFinding: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let capability: DependencyCapability
    let summary: String
    let detail: String
}

struct DependencyWorkspaceReport: Sendable {
    let packagePins: [ResolvedPackagePin]
    let lockfilePaths: [String]
    let installedIdentities: Set<String>
    let buildableIdentities: Set<String>
    let findings: [DependencyCompatibilityFinding]
    let truncatedLockfileScan: Bool

    var buildSupported: Bool { !buildableIdentities.isEmpty }
    var conflictingIdentities: Set<String> {
        Set(findings.compactMap { finding in
            guard finding.id.hasPrefix("pin-conflict-") else { return nil }
            return String(finding.id.dropFirst("pin-conflict-".count))
        })
    }

    var fetchablePins: [ResolvedPackagePin] {
        let conflicts = conflictingIdentities
        return packagePins.filter { pin in
            !conflicts.contains(pin.identity)
                && pin.kind == .remoteSourceControl
                && (try? GitHubRepository.parse(pin.location, explicitRef: pin.revision)) != nil
                && !installedIdentities.contains(pin.identity)
        }
    }
    var buildSupported: Bool { false }
}

/// A bounded, read-only analyzer. It never interprets Package.swift or runs a
/// package plugin; only committed Package.resolved pins are offered for download.
enum DependencyWorkspaceAnalyzer {
    static let maximumLockfiles = 16
    static let maximumLockfileBytes = ResolvedPackageLimits.default.maxBytes
    static let maximumManifestBytes = 512 * 1024
    static let maximumManifests = 200

    static func analyze(project: Project) -> DependencyWorkspaceReport {
        let root = project.isXcodeProject ? project.snapshotRootURL : project.rootURL
        let lockfiles = findLockfiles(root: root)
        let manifestFiles = findManifestFiles(root: root)
        var pins: [ResolvedPackagePin] = []
        var paths: [String] = []
        var findings: [DependencyCompatibilityFinding] = []
        for url in lockfiles.urls {
            let path = GitHubSnapshotDetector.relativePath(of: url, in: root) ?? url.lastPathComponent
            paths.append(path)
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= maximumLockfileBytes else { throw ResolvedPackageError.tooLarge(actual: size, limit: maximumLockfileBytes) }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let lock = try ResolvedPackageLockfile.read(data: data)
                for pin in lock.pins {
                    if let prior = pins.first(where: { $0.identity == pin.identity }) {
                        let same = prior.revision == pin.revision
                            && prior.location.caseInsensitiveCompare(pin.location) == .orderedSame
                        if !same {
                            findings.append(.init(id: "pin-conflict-\(pin.identity)", capability: .unsupported,
                                                  summary: "Conflicting lockfile pins for \(pin.identity)",
                                                  detail: "Different lockfiles resolve this identity to different sources or revisions. The source fetcher will not guess which target's pin to use."))
                        }
                        continue
                    }
                    pins.append(pin)
                }
            } catch {
                findings.append(.init(id: "lock:\(path)", capability: .unsupported,
                                      summary: "Could not analyze \(path)",
                                      detail: error.localizedDescription))
            }
        }

        var installed = Set<String>()
        for pin in pins {
            let dir = dependencyDirectory(for: pin, root: root)
            if let marker = PinnedDependencySourceInstaller.readMarker(dir),
               marker.revision.caseInsensitiveCompare(pin.revision) == .orderedSame,
               marker.repository.lowercased() == ((try? GitHubRepository.parse(pin.location))?.slug.lowercased() ?? "") {
                installed.insert(pin.identity)
            }
        }

        var verifiedModules: [NativeSwiftDependencyPlan] = []
        if !project.isXcodeProject {
            let manifestURL = root.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifestURL.path),
               let names = try? NativeBuildPlanFactory.swiftPackageDependencies(manifestURL: manifestURL) {
                verifiedModules = (try? NativeBuildPlanFactory.swiftDependencyModules(
                    root: root, declaredNames: names
                )) ?? []
            }
        }
        let native = NativeToolchainCapabilities.current
        let canCompileModule = native.hasSwiftFrontend && NativeSDK.isInstalled
        let buildable = canCompileModule ? Set(verifiedModules.map(\.identity)) : []

        let manifestMentions = manifestFiles.filter { url in
            guard let text = boundedText(url, maximumBytes: maximumManifestBytes) else { return false }
            // Heuristic evidence only: Package.swift is never evaluated, so text
            // inside comments or strings may also match this token.
            return text.contains(".package(")
        }
        if !manifestMentions.isEmpty {
            findings.append(.init(id: "manifest-declarations", capability: .unknown,
                                  summary: "Possible SwiftPM dependencies declared",
                                  detail: "A bounded text scan found .package( in \(manifestMentions.count) manifest(s). It is not evaluated; use Package.resolved pins for reproducible source fetching."))
        }
        if paths.isEmpty {
            findings.append(.init(id: "lock-missing", capability: .unknown,
                                  summary: "No Package.resolved lockfile found",
                                  detail: manifestMentions.isEmpty
                                    ? "Without a committed lockfile, exact dependency revisions are unknown. XForge will not execute Package.swift to solve versions."
                                    : "A manifest appears to declare dependencies, but no lockfile pins exact revisions. XForge will not execute it or choose floating versions."))
        }
        if !pins.isEmpty {
            findings.append(.init(id: "source-fetch", capability: .fetchable,
                                  summary: "Pinned source snapshots can be downloaded",
                                  detail: "Only immutable public GitHub revisions are supported. This fetches source snapshots, not Git history."))
            let allPinsHaveSupportedBuildProfile = pins.count == 1
                && pins.allSatisfy { buildable.contains($0.identity) }
            if allPinsHaveSupportedBuildProfile {
                findings.append(.init(id: "module-build", capability: .ready,
                                      summary: "The pinned ZIPFoundation module profile is buildable",
                                      detail: "For this exact allowlisted source revision and layout, XForge emits the Swift module, compiles its sources, makes the module available to the app, links its objects, and bundles the privacy resource. This is not general SwiftPM dependency support."))
            } else {
                let detail: String
                if verifiedModules.isEmpty {
                    detail = "Only the exact ZIPFoundation 0.9.19 pinned source profile is supported today. Other packages, versions, multi-pin graphs, products, plugins, binaries, and resources remain unsupported."
                } else if !native.hasSwiftFrontend {
                    detail = "The pinned ZIPFoundation source profile is present, but this XForge build has no linked Swift frontend."
                } else if !NativeSDK.isInstalled {
                    detail = "The pinned ZIPFoundation source profile is present, but the Darwin SDK is not installed."
                } else {
                    detail = "All dependencies in this lockfile must match the same validated build profile; conflicting or additional pins are not guessed."
                }
                findings.append(.init(id: "module-build", capability: .unsupported,
                                      summary: "Some dependency modules are not buildable by XForge",
                                      detail: detail))
            }
        }
        if lockfiles.truncated {
            findings.append(.init(id: "lock-limit", capability: .unsupported,
                                  summary: "Lockfile scan limit reached",
                                  detail: "Only the first \(maximumLockfiles) lockfiles were inspected."))
        }
        return DependencyWorkspaceReport(packagePins: pins, lockfilePaths: paths,
                                         installedIdentities: installed,
                                         buildableIdentities: buildable,
                                         findings: findings,
                                         truncatedLockfileScan: lockfiles.truncated)
    }

    static func dependencyDirectory(for pin: ResolvedPackagePin, root: URL) -> URL {
        let identity = GitHubSnapshotImporter.sanitizedProjectName(pin.identity)
        let revision = String(pin.revision.prefix(12)).lowercased()
        return root.appendingPathComponent(".xforge-dependencies", isDirectory: true)
            .appendingPathComponent("\(identity)-\(revision)", isDirectory: true)
    }

    private static func findManifestFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                            options: [.skipsHiddenFiles]) else { return [] }
        let excluded: Set<String> = [".git", ".build", ".xforge-generated", ".xforge-dependencies", "Pods", "Carthage", "DerivedData", "node_modules"]
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if excluded.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent == "Package.swift" {
                urls.append(url)
                if urls.count >= maximumManifests { break }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func boundedText(_ url: URL, maximumBytes: Int) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct LockScan { let urls: [URL]; let truncated: Bool }

    private static func findLockfiles(root: URL) -> LockScan {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return LockScan(urls: [], truncated: false) }
        let excluded: Set<String> = [".git", ".build", ".xforge-generated", ".xforge-dependencies", "Pods", "Carthage", "DerivedData", "node_modules"]
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if excluded.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent == "Package.resolved" {
                urls.append(url)
                if urls.count > maximumLockfiles { break }
            }
        }
        return LockScan(urls: Array(urls.prefix(maximumLockfiles)), truncated: urls.count > maximumLockfiles)
    }
}
