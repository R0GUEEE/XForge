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
        XCTAssertFalse(report.buildSupported)
        XCTAssertTrue(report.findings.contains { $0.id == "module-build" && $0.capability == .unsupported })
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
            revision: sha, archiveSHA256: String(repeating: "c", count: 64), archiveBytes: 123,
            extractedBytes: 456, fetchedAt: Date(timeIntervalSince1970: 1))
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(".xforge-dependency.json"))
        XCTAssertEqual(PinnedDependencySourceInstaller.readMarker(dir), marker)
        XCTAssertTrue(DependencyWorkspaceAnalyzer.analyze(project: project).installedIdentities.contains("zipfoundation"))
    }
}
