import XCTest
@testable import XForge

/// The GitHub import is split into pure pieces on purpose — URL parsing, project
/// location and archive path validation — because those are the parts where a
/// mistake means importing the wrong code or writing outside the projects
/// directory. None of them need a network or a real archive to test.
final class GitHubSnapshotImportTests: XCTestCase {

    // MARK: - Repository URL parsing

    func testParsesRepositoryURL() throws {
        let reference = try GitHubRepositoryReference.parse(
            "https://github.com/apple/swift-argument-parser"
        )
        XCTAssertEqual(reference.owner, "apple")
        XCTAssertEqual(reference.repository, "swift-argument-parser")
        XCTAssertNil(reference.ref)
        XCTAssertEqual(reference.fullName, "apple/swift-argument-parser")
        XCTAssertEqual(reference.zipballURL.absoluteString,
                       "https://codeload.github.com/apple/swift-argument-parser/zipball/HEAD")
    }

    func testParsesDotGitSuffixAndTrailingSlash() throws {
        let reference = try GitHubRepositoryReference.parse(
            "https://github.com/apple/swift-argument-parser.git/"
        )
        XCTAssertEqual(reference.repository, "swift-argument-parser")
        XCTAssertNil(reference.ref)
    }

    func testParsesTreeLinkAsRef() throws {
        let tag = try GitHubRepositoryReference.parse(
            "https://github.com/apple/swift-argument-parser/tree/1.3.0"
        )
        XCTAssertEqual(tag.ref, "1.3.0")
        XCTAssertEqual(tag.zipballURL.absoluteString,
                       "https://codeload.github.com/apple/swift-argument-parser/zipball/1.3.0")

        let branch = try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo/tree/feature/login"
        )
        XCTAssertEqual(branch.ref, "feature/login")
    }

    func testParsesShorthandAndShorthandRef() throws {
        let plain = try GitHubRepositoryReference.parse("owner/repo")
        XCTAssertEqual(plain.fullName, "owner/repo")
        XCTAssertNil(plain.ref)

        let withRef = try GitHubRepositoryReference.parse("owner/repo@release/2.0")
        XCTAssertEqual(withRef.ref, "release/2.0")
        XCTAssertEqual(withRef.displayName, "owner/repo@release/2.0")
    }

    func testExplicitRefWinsWhenURLHasNoneAndMustAgreeWhenItDoes() throws {
        let explicit = try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo", ref: "dev"
        )
        XCTAssertEqual(explicit.ref, "dev")

        let same = try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo/tree/main", ref: "main"
        )
        XCTAssertEqual(same.ref, "main")

        XCTAssertThrowsError(try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo/tree/main", ref: "dev"
        ))
    }

    func testRejectsNonGitHubAndInsecureURLs() {
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("https://gitlab.com/owner/repo"))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("http://github.com/owner/repo"))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("ssh://github.com/owner/repo"))
    }

    func testRejectsLinksThatAreNotRepositoriesOrRevisions() {
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("https://github.com/owner"))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("https://github.com/owner/repo/issues/1"))
        // A blob link names a file; treating its path as a ref would fetch the
        // wrong revision.
        XCTAssertThrowsError(try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo/blob/main/README.md"
        ))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo/tree"
        ))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse(
            "https://github.com/owner/repo?tab=readme"
        ))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse(""))
    }

    func testRejectsInvalidNamesAndRefs() {
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("owner/repo extra"))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("owner/repo/extra"))
        XCTAssertThrowsError(try GitHubRepositoryReference.parse("https://github.com/../repo"))

        XCTAssertThrowsError(try GitHubRepositoryReference.validatedRef("../main"))
        XCTAssertThrowsError(try GitHubRepositoryReference.validatedRef("main..next"))
        XCTAssertThrowsError(try GitHubRepositoryReference.validatedRef("main\nother"))
        XCTAssertThrowsError(try GitHubRepositoryReference.validatedRef("main?x=1"))
        XCTAssertThrowsError(try GitHubRepositoryReference.validatedRef("-danger"))
        XCTAssertNoThrow(try GitHubRepositoryReference.validatedRef("release/2.0"))
    }

    // MARK: - Project model: snapshot subpath

    func testProjectRootURLUsesValidatedSnapshotSubpath() throws {
        let project = Project(
            name: "Demo",
            rootPath: Project.path(forValidatedName: "Demo"),
            kind: .xcodeProject,
            snapshotSubpath: "ios/Demo"
        )
        XCTAssertTrue(project.isXcodeProject)
        XCTAssertTrue(project.rootURL.path.hasSuffix("/projects/Demo/ios/Demo"))
        XCTAssertTrue(project.snapshotRootURL.path.hasSuffix("/projects/Demo"))
    }

    func testUnsafeSnapshotSubpathFallsBackToSnapshotRoot() throws {
        for bad in ["../Other", "/etc", "ios/../../Other", "ios//App", "ios\\App", "."] {
            let project = Project(
                name: "Demo",
                rootPath: Project.path(forValidatedName: "Demo"),
                snapshotSubpath: bad
            )
            XCTAssertEqual(project.rootURL, project.snapshotRootURL,
                           "subpath \(bad) should not escape the project")
            XCTAssertThrowsError(try Project.validatedSubpath(bad))
        }
    }

    func testProjectKindAndOriginSurviveCodableRoundTrip() throws {
        let project = Project(
            name: "Demo",
            rootPath: "projects/Demo",
            kind: .xcodeProject,
            origin: .githubArchive(
                repository: "owner/repo",
                requestedRef: "main",
                resolvedCommit: "abcdef1234567890",
                archiveURL: "https://codeload.github.com/owner/repo/zipball/main"
            ),
            snapshotSubpath: "ios"
        )
        let decoded = try JSONDecoder().decode(Project.self,
                                               from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.kind, .xcodeProject)
        XCTAssertEqual(decoded.snapshotSubpath, "ios")
        XCTAssertEqual(decoded.origin?.repository, "owner/repo")
        XCTAssertEqual(decoded.origin?.requestedRef, "main")
        XCTAssertEqual(decoded.origin?.resolvedCommit, "abcdef1234567890")
        XCTAssertEqual(decoded.origin?.shortDescription, "owner/repo@abcdef1")
    }

    func testLegacyProjectJSONDecodesAsSwiftPackage() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","rootPath":"projects/Old",
         "organizationIdentifier":"com.example","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .swiftPackage)
        XCTAssertNil(decoded.origin)
        XCTAssertNil(decoded.snapshotSubpath)
    }

    // MARK: - Archive entry validation

    func testAcceptsOrdinaryArchivePaths() throws {
        XCTAssertEqual(try GitHubRepository.parse("https://github.com/apple/swift-argument-parser").slug,
                       "apple/swift-argument-parser")
        XCTAssertEqual(try GitHubRepository.parse("owner/repo@release/2.0").ref,
                       "release/2.0")
        let limits = SnapshotExtractionLimits.default
        XCTAssertEqual(try SnapshotArchiveExtractor.validatedRelativePath(
            "owner-repo-abc1234/App/AppDelegate.swift", limits: limits
        ), "owner-repo-abc1234/App/AppDelegate.swift")
        XCTAssertEqual(try SnapshotArchiveExtractor.validatedRelativePath(
            "owner-repo-abc1234/App/", isDirectory: true, limits: limits
        ), "owner-repo-abc1234/App")
        XCTAssertEqual(try SnapshotArchiveExtractor.validatedRelativePath(
            "Package.swift", limits: limits
        ), "Package.swift")
    }

    func testRejectsTraversalAndAbsoluteArchivePaths() {
        let limits = SnapshotExtractionLimits.default
        for bad in [
            "../evil.sh",
            "repo/../../evil.sh",
            "repo/./file",
            "repo//file",
            "/etc/passwd",
            "C:/Windows/system32",
            "repo\\..\\evil.sh",
            "repo/file\u{0}.swift",
            "repo/file\n.swift",
            ""
        ] {
            XCTAssertThrowsError(
                try SnapshotArchiveExtractor.validatedRelativePath(bad, limits: limits),
                "path \(bad.debugDescription) should be rejected"
            )
        }
    }

    func testRejectsOverlongAndOverdeepArchivePaths() {
        let tight = SnapshotExtractionLimits(
            maxPathLength: 20,
            maxPathComponents: 3
        )
        XCTAssertThrowsError(try SnapshotArchiveExtractor.validatedRelativePath(
            String(repeating: "a", count: 21), limits: tight
        ))
        XCTAssertThrowsError(try SnapshotArchiveExtractor.validatedRelativePath(
            "a/b/c/d", limits: tight
        ))
        XCTAssertNoThrow(try SnapshotArchiveExtractor.validatedRelativePath(
            "a/b/c", limits: tight
        ))
    }
}
