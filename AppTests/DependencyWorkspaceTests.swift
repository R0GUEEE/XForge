import XCTest
@testable import XForge

final class DependencyWorkspaceTests: XCTestCase {
    private var project: Project!

    override func setUpWithError() throws {
        let name = "deps-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        project = Project(name: name, rootPath: Project.path(forValidatedName: name))
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project.rootURL) }
    }

    func testAnalyzerExposesOnlyImmutablePublicGitHubPinsAsFetchable() throws {
        let sha = String(repeating: "a", count: 40)
        let lock = """
        {"version":2,"pins":[{"identity":"zipfoundation","kind":"remoteSourceControl","location":"https://github.com/weichsel/ZIPFoundation.git","state":{"revision":"\(sha)","version":"0.9.19"}}]}
        """
        try Data(lock.utf8).write(to: project.rootURL.appendingPathComponent("Package.resolved"))

        let report = DependencyWorkspaceAnalyzer.analyze(project: project)
        XCTAssertEqual(report.packagePins.map(\.identity), ["zipfoundation"])
        XCTAssertEqual(report.fetchablePins.map(\.revision), [sha])
        XCTAssertFalse(report.hasEligibleBuildProfile)
        XCTAssertTrue(report.findings.contains { $0.id == "module-build" && $0.capability == .unsupported })
    }

    func testArchiveRootMustNamePinnedRevision() {
        let revision = String(repeating: "d", count: 40)
        XCTAssertTrue(PinnedDependencySourceInstaller.archiveRootMatches(
            revision: revision, rootName: "ZIPFoundation-\(revision)"
        ))
        XCTAssertFalse(PinnedDependencySourceInstaller.archiveRootMatches(
            revision: revision, rootName: "ZIPFoundation-main"
        ))
    }

    func testInstallerSkipsNonImmutablePinsWithoutStartingNetworkRequest() async throws {
        let pin = ResolvedPackagePin(identity: "not-pinned", location: "https://github.com/owner/repo",
                                     revision: "main", version: nil, kind: .remoteSourceControl)
        let result = try await PinnedDependencySourceInstaller.installPinnedSources(for: project, pins: [pin])
        XCTAssertTrue(result.installed.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("immutable") })
    }

    func testInstallerRefusesOversizedBatchBeforeNetwork() async throws {
        let pins = (0..<(PinnedDependencySourceInstaller.maximumPackagesPerRun + 1)).map { index in
            ResolvedPackagePin(identity: "package-\(index)", location: "https://github.com/owner/repo-\(index)",
                               revision: String(repeating: "a", count: 40), version: "1.0.0", kind: .remoteSourceControl)
        }
        do {
            _ = try await PinnedDependencySourceInstaller.installPinnedSources(for: project, pins: pins)
            XCTFail("oversized batch must stop before network access")
        } catch let error as PinnedDependencySourceInstaller.InstallError {
            guard case .tooManyPackages = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testAnalyzerDoesNotFlattenConflictingPinsAcrossLockfiles() throws {
        let first = project.rootURL.appendingPathComponent("App/Package.resolved")
        let second = project.rootURL.appendingPathComponent("Widget/Package.resolved")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        func lock(_ revision: String) -> Data {
            Data("""
            {"version":2,"pins":[{"identity":"zipfoundation","kind":"remoteSourceControl","location":"https://github.com/weichsel/ZIPFoundation","state":{"revision":"\(revision)"}}]}
            """.utf8)
        }
        try lock(String(repeating: "a", count: 40)).write(to: first)
        try lock(String(repeating: "b", count: 40)).write(to: second)
        let report = DependencyWorkspaceAnalyzer.analyze(project: project)
        XCTAssertEqual(report.packagePins.count, 1)
        XCTAssertTrue(report.findings.contains { $0.id == "pin-conflict-zipfoundation" })
    }

    func testSourceTreeDigestChangesWhenAFileChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-source-digest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/File.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        let first = try PinnedDependencySourceInstaller.sourceTreeSHA256(at: root)
        try "let value = 2".write(to: file, atomically: true, encoding: .utf8)
        let second = try PinnedDependencySourceInstaller.sourceTreeSHA256(at: root)
        XCTAssertNotEqual(first, second)
    }

    func testSourceTreeDigestRejectsSymlinkEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-source-link-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path,
                                                   withDestinationPath: "/tmp")
        XCTAssertThrowsError(try PinnedDependencySourceInstaller.sourceTreeSHA256(at: root))
    }

    func testAnalyzerReportsNoLockfileAsUnknownNotResolved() {
        let report = DependencyWorkspaceAnalyzer.analyze(project: project)
        XCTAssertTrue(report.packagePins.isEmpty)
        XCTAssertTrue(report.fetchablePins.isEmpty)
        XCTAssertTrue(report.findings.contains { $0.id == "lock-missing" && $0.capability == .unknown })
    }

    func testInstalledMarkerIsRecognizedOnlyForMatchingPinnedRevision() throws {
        let sha = String(repeating: "b", count: 40)
        let repo = try GitHubRepository.parse("https://github.com/weichsel/ZIPFoundation")
        let pin = ResolvedPackagePin(identity: "zipfoundation", location: "https://github.com/weichsel/ZIPFoundation",
                                     revision: sha, version: "0.9.19", kind: .remoteSourceControl)
        let lock = """
        {"version":2,"pins":[{"identity":"zipfoundation","kind":"remoteSourceControl","location":"https://github.com/weichsel/ZIPFoundation","state":{"revision":"\(sha)","version":"0.9.19"}}]}
        """
        try Data(lock.utf8).write(to: project.rootURL.appendingPathComponent("Package.resolved"))
        let dir = DependencyWorkspaceAnalyzer.dependencyDirectory(for: pin, root: project.rootURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = PinnedDependencySourceInstaller.Marker(identity: pin.identity, repository: repo.slug,
            revision: sha, archiveSHA256: String(repeating: "c", count: 64),
            sourceTreeSHA256: try PinnedDependencySourceInstaller.sourceTreeSHA256(at: dir),
            archiveBytes: 123,
            extractedBytes: 456, fetchedAt: Date(timeIntervalSince1970: 1))
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(".xforge-dependency.json"))
        XCTAssertEqual(PinnedDependencySourceInstaller.readMarker(dir), marker)
        XCTAssertTrue(DependencyWorkspaceAnalyzer.analyze(project: project).installedIdentities.contains("zipfoundation"))
    }
}
