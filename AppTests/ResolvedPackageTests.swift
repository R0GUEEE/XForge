import XCTest
@testable import XForge

/// Covers the locked-dependency parser: all three Package.resolved schemas, both
/// pins containers, remoteSourceControl-only pins, 40-hex revisions, public
/// github.com location parsing, duplicate rejection and the strict limits.
final class ResolvedPackageTests: XCTestCase {

    private let sha = "0123456789abcdef0123456789abcdef01234567"
    private let sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // MARK: Fixtures

    private func read(_ json: String,
                      limits: ResolvedPackageLimits = .default) throws -> ResolvedPackageLockfile {
        try ResolvedPackageLockfile.read(data: Data(json.utf8), limits: limits)
    }

    /// A v1/v2 document with `object.pins`.
    private func objectDocument(pins: [String], version: Int, extra: String = "") -> String {
        "{\"object\":{\"pins\":[\(pins.joined(separator: ","))],\"version\":\(version)},"
            + "\"version\":\(version)\(extra)}"
    }

    /// A v2/v3 document with root `pins`.
    private func rootDocument(pins: [String], version: Int, extra: String = "") -> String {
        "{\"pins\":[\(pins.joined(separator: ","))],\"version\":\(version)\(extra)}"
    }

    private func pin(identity: String = "alamofire",
                     kind: String = "remoteSourceControl",
                     location: String = "https://github.com/Alamofire/Alamofire.git",
                     revision: String? = nil,
                     version: String? = "5.8.1",
                     branch: String? = nil) -> String {
        var state = "\"revision\":\"\(revision ?? sha)\""
        if let version { state += ",\"version\":\"\(version)\"" }
        if let branch { state += ",\"branch\":\"\(branch)\"" }
        return "{\"identity\":\"\(identity)\",\"kind\":\"\(kind)\","
            + "\"location\":\"\(location)\",\"state\":{\(state)}}"
    }

    private func pinV1(package: String = "Alamofire",
                       url: String = "https://github.com/Alamofire/Alamofire.git",
                       revision: String? = nil,
                       version: String? = "5.8.1",
                       branch: String? = nil,
                       kind: String? = nil) -> String {
        var state = "\"revision\":\"\(revision ?? sha)\""
        if let version { state += ",\"version\":\"\(version)\"" }
        if let branch { state += ",\"branch\":\"\(branch)\"" } else { state += ",\"branch\":null" }
        let kindField = kind.map { ",\"kind\":\"\($0)\"" } ?? ""
        return "{\"package\":\"\(package)\",\"repositoryURL\":\"\(url)\"\(kindField),"
            + "\"state\":{\(state)}}"
    }

    // MARK: Assertions

    private func assertFails(_ json: String,
                             limits: ResolvedPackageLimits = .default,
                             file: StaticString = #filePath,
                             line: UInt = #line,
                             _ matches: (ResolvedPackageError) -> Bool) {
        do {
            let lockfile = try read(json, limits: limits)
            XCTFail("expected an error, parsed \(lockfile.pins.count) pins",
                    file: file, line: line)
        } catch let error as ResolvedPackageError {
            XCTAssertTrue(matches(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected non-parser error: \(error)", file: file, line: line)
        }
    }

    private func assertInvalidLocation(_ location: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        assertFails(objectDocument(pins: [pin(location: location)], version: 2),
                    file: file, line: line) {
            if case .invalidRepositoryURL = $0 { return true }
            return false
        }
    }

    // MARK: Schema versions and layouts

    func testReadsVersionOneObjectPins() throws {
        let lockfile = try read(objectDocument(pins: [pinV1()], version: 1))

        XCTAssertEqual(lockfile.schemaVersion, 1)
        XCTAssertEqual(lockfile.layout, .object)
        XCTAssertEqual(lockfile.pins.count, 1)
        let resolved = try XCTUnwrap(lockfile.pins.first)
        // v1 has no identity field: it is derived from the repository name.
        XCTAssertEqual(resolved.identity, "alamofire")
        XCTAssertEqual(resolved.location, "https://github.com/Alamofire/Alamofire")
        XCTAssertEqual(resolved.revision, sha)
        XCTAssertEqual(resolved.version, "5.8.1")
    }

    func testReadsVersionTwoObjectPins() throws {
        let lockfile = try read(objectDocument(pins: [pin()], version: 2))

        XCTAssertEqual(lockfile.schemaVersion, 2)
        XCTAssertEqual(lockfile.layout, .object)
        let resolved = try XCTUnwrap(lockfile.pins.first)
        XCTAssertEqual(resolved.identity, "alamofire")
        XCTAssertEqual(resolved.location, "https://github.com/Alamofire/Alamofire")
        XCTAssertEqual(resolved.revision, sha)
        XCTAssertEqual(resolved.version, "5.8.1")
        XCTAssertNil(lockfile.originHash)
    }

    func testReadsVersionThreeRootPinsAndNormalizesOriginHash() throws {
        let json = rootDocument(pins: [pin()], version: 3,
                                extra: ",\"originHash\":\"\(sha256.uppercased())\"")
        let lockfile = try read(json)

        XCTAssertEqual(lockfile.schemaVersion, 3)
        XCTAssertEqual(lockfile.layout, .root)
        XCTAssertEqual(lockfile.originHash, sha256)
        XCTAssertEqual(lockfile.pins.map(\.identity), ["alamofire"])
    }

    func testAcceptsRootPinsForVersionTwo() throws {
        let lockfile = try read(rootDocument(pins: [pin()], version: 2))
        XCTAssertEqual(lockfile.layout, .root)
        XCTAssertEqual(lockfile.schemaVersion, 2)
    }

    func testAcceptsObjectWrapperForVersionThree() throws {
        let lockfile = try read(objectDocument(pins: [pin()], version: 3))
        XCTAssertEqual(lockfile.layout, .object)
        XCTAssertEqual(lockfile.schemaVersion, 3)
    }

    func testAcceptsRootPinsForVersionOne() throws {
        let lockfile = try read(rootDocument(pins: [pinV1()], version: 1))
        XCTAssertEqual(lockfile.layout, .root)
        XCTAssertEqual(lockfile.pins.first?.identity, "alamofire")
    }

    func testAcceptsVersionOnlyInsideObject() throws {
        let json = """
        {"object":{"pins":[],"version":2}}
        """
        let lockfile = try read(json)
        XCTAssertEqual(lockfile.schemaVersion, 2)
        XCTAssertTrue(lockfile.pins.isEmpty)
    }

    func testAcceptsEmptyPinList() throws {
        let lockfile = try read(rootDocument(pins: [], version: 3))
        XCTAssertTrue(lockfile.pins.isEmpty)
        XCTAssertTrue(lockfile.identities.isEmpty)
    }

    func testRejectsMissingVersion() {
        assertFails("{\"object\":{\"pins\":[]}}") {
            if case .missingSchemaVersion = $0 { return true }
            return false
        }
        assertFails("{\"pins\":[]}") {
            if case .missingSchemaVersion = $0 { return true }
            return false
        }
    }

    func testRejectsUnsupportedSchemaVersions() {
        for version in [0, 4, 99] {
            assertFails(rootDocument(pins: [], version: version)) {
                if case .unsupportedSchema(let declared) = $0 { return declared == version }
                return false
            }
        }
    }

    func testRejectsContradictoryVersions() {
        let json = """
        {"object":{"pins":[],"version":3},"version":2}
        """
        assertFails(json) {
            if case .contradictoryVersions(let root, let object) = $0 {
                return root == 2 && object == 3
            }
            return false
        }
    }

    func testRejectsPinsInBothLocations() {
        let json = """
        {"object":{"pins":[],"version":2},"pins":[],"version":2}
        """
        assertFails(json) {
            if case .contradictoryPins = $0 { return true }
            return false
        }
    }

    func testRejectsMissingPins() {
        assertFails("{\"object\":{\"version\":2},\"version\":2}") {
            if case .missingPins = $0 { return true }
            return false
        }
    }

    func testRejectsPinsThatAreNotAnArray() {
        assertFails("{\"object\":{\"pins\":{},\"version\":2},\"version\":2}") {
            if case .malformedDocument = $0 { return true }
            return false
        }
    }

    func testRejectsTopLevelThatIsNotAnObject() {
        assertFails("[]") {
            if case .malformedDocument = $0 { return true }
            return false
        }
    }

    func testRejectsPinThatIsNotAnObject() {
        assertFails(objectDocument(pins: ["\"nope\""], version: 2)) {
            if case .malformedPin(let index, _) = $0 { return index == 0 }
            return false
        }
    }

    // MARK: Pins

    func testRejectsNonRemoteSourceControlKinds() {
        for kind in ["fileSystem", "localSourceControl", "registry", "edited"] {
            assertFails(objectDocument(pins: [pin(kind: kind)], version: 2)) {
                if case .unsupportedKind(_, let parsed) = $0 { return parsed == kind }
                return false
            }
        }
    }

    func testRejectsMissingKindInVersionTwo() {
        let json = """
        {
          "object": {
            "pins": [{
              "identity": "alamofire",
              "location": "https://github.com/Alamofire/Alamofire",
              "state": {"revision": "\(sha)"}
            }],
            "version": 2
          },
          "version": 2
        }
        """
        assertFails(json) {
            if case .malformedPin(let index, _) = $0 { return index == 0 }
            return false
        }
    }

    func testVersionOnePinWithNonRemoteKindIsRejected() {
        assertFails(objectDocument(pins: [pinV1(kind: "fileSystem")], version: 1)) {
            if case .unsupportedKind = $0 { return true }
            return false
        }
    }

    func testRejectsMissingState() {
        let json = """
        {
          "object": {
            "pins": [{
              "identity": "alamofire",
              "kind": "remoteSourceControl",
              "location": "https://github.com/Alamofire/Alamofire"
            }],
            "version": 2
          },
          "version": 2
        }
        """
        assertFails(json) {
            if case .malformedPin = $0 { return true }
            return false
        }
    }

    func testRejectsStateThatIsNotAnObject() {
        let json = """
        {
          "object": {
            "pins": [{
              "identity": "alamofire",
              "kind": "remoteSourceControl",
              "location": "https://github.com/Alamofire/Alamofire",
              "state": "pinned"
            }],
            "version": 2
          },
          "version": 2
        }
        """
        assertFails(json) {
            if case .malformedPin = $0 { return true }
            return false
        }
    }

    func testRejectsMissingRevision() {
        let json = """
        {
          "object": {
            "pins": [{
              "identity": "alamofire",
              "kind": "remoteSourceControl",
              "location": "https://github.com/Alamofire/Alamofire",
              "state": {"version": "5.8.1"}
            }],
            "version": 2
          },
          "version": 2
        }
        """
        assertFails(json) {
            if case .malformedPin = $0 { return true }
            return false
        }
    }

    func testAcceptsBranchPinWithoutVersion() throws {
        let lockfile = try read(objectDocument(
            pins: [pin(version: nil, branch: "main")], version: 2))
        let resolved = try XCTUnwrap(lockfile.pins.first)
        XCTAssertNil(resolved.version)
        XCTAssertEqual(resolved.revision, sha)
    }

    func testRejectsInvalidBranchName() {
        assertFails(objectDocument(
            pins: [pin(version: nil, branch: "bad branch")], version: 2)) {
            if case .malformedPin = $0 { return true }
            return false
        }
    }

    func testRejectsInvalidVersionString() {
        for version in ["not a version", "v5.8.1", "5.8.1; rm -rf /"] {
            assertFails(objectDocument(pins: [pin(version: version)], version: 2)) {
                if case .malformedPin = $0 { return true }
                return false
            }
        }
    }

    // MARK: Revisions

    func testRejectsRevisionsThatAreNotFortyHexCharacters() {
        let revisions = [String(sha.dropLast()), sha256, "main", "HEAD", sha + "0"]
        for revision in revisions {
            assertFails(objectDocument(pins: [pin(revision: revision)], version: 2)) {
                if case .invalidRevision = $0 { return true }
                return false
            }
        }
    }

    func testNormalizesUppercaseRevision() throws {
        let lockfile = try read(objectDocument(
            pins: [pin(revision: sha.uppercased())], version: 2))
        XCTAssertEqual(lockfile.pins.first?.revision, sha)
    }

    // MARK: Identities

    func testRejectsDuplicateIdentity() {
        let pins = [
            pin(identity: "foo", location: "https://github.com/owner-one/Foo"),
            pin(identity: "foo", location: "https://github.com/owner-two/Foo"),
        ]
        assertFails(objectDocument(pins: pins, version: 2)) {
            if case .duplicateIdentity(let identity) = $0 { return identity == "foo" }
            return false
        }
    }

    func testRejectsDuplicateIdentityDerivedFromVersionOneRepositoryNames() {
        let pins = [
            pinV1(package: "One", url: "https://github.com/owner-one/Foo.git"),
            pinV1(package: "Two", url: "https://github.com/owner-two/Foo.git"),
        ]
        assertFails(objectDocument(pins: pins, version: 1)) {
            if case .duplicateIdentity(let identity) = $0 { return identity == "foo" }
            return false
        }
    }

    func testRejectsDuplicateRepositoryRegardlessOfOwnerCase() {
        let pins = [
            pin(identity: "foo", location: "https://github.com/Owner/Repo"),
            pin(identity: "bar", location: "https://github.com/owner/repo.git"),
        ]
        assertFails(objectDocument(pins: pins, version: 2)) {
            if case .duplicateRepository(let slug) = $0 {
                return slug.lowercased() == "owner/repo"
            }
            return false
        }
    }

    func testRejectsUppercaseIdentity() {
        assertFails(objectDocument(pins: [pin(identity: "Alamofire")], version: 2)) {
            if case .malformedPin = $0 { return true }
            return false
        }
    }

    func testRejectsIdentityWithUnsupportedCharacters() {
        for identity in ["ala mofire", "alamofire!", "-alamofire", "../alamofire"] {
            assertFails(objectDocument(pins: [pin(identity: identity)], version: 2)) {
                if case .malformedPin = $0 { return true }
                return false
            }
        }
    }

    func testVersionOneDerivesLowercaseIdentityFromRepositoryName() throws {
        let lockfile = try read(objectDocument(
            pins: [pinV1(package: "FancyName", url: "https://github.com/Owner/RepoKit.git")],
            version: 1))
        XCTAssertEqual(lockfile.pins.first?.identity, "repokit")
    }

    // MARK: Repository URLs

    func testAcceptsOnlyCanonicalGitHubLocations() throws {
        let locations = [
            "https://github.com/owner/repo",
            "https://github.com/owner/repo.git",
            "https://github.com/owner/repo/",
            "https://www.github.com/owner/repo.git",
        ]
        for location in locations {
            let lockfile = try read(objectDocument(pins: [pin(location: location)], version: 2))
            XCTAssertEqual(lockfile.pins.first?.location, "https://github.com/owner/repo",
                           "for \(location)")
        }
    }

    func testPreservesRepositoryCaseInCanonicalLocation() throws {
        let lockfile = try read(objectDocument(
            pins: [pin(location: "https://github.com/Owner/Repo.git")], version: 2))
        XCTAssertEqual(lockfile.pins.first?.location, "https://github.com/Owner/Repo")
    }

    func testRejectsInsecureAndForeignLocations() {
        let locations = [
            "http://github.com/owner/repo",
            "ftp://github.com/owner/repo",
            "git@github.com:owner/repo.git",
            "git://github.com/owner/repo.git",
            "ssh://git@github.com/owner/repo.git",
            "https://gitlab.com/owner/repo",
            "https://bitbucket.org/owner/repo",
            "https://github.com.evil.example/owner/repo",
        ]
        for location in locations {
            assertInvalidLocation(location)
        }
    }

    func testRejectsCredentialsInLocation() {
        assertInvalidLocation("https://user:password@github.com/owner/repo")
        assertInvalidLocation("https://token@github.com/owner/repo")
    }

    func testRejectsQueryFragmentAndPort() {
        assertInvalidLocation("https://github.com/owner/repo?ref=main")
        assertInvalidLocation("https://github.com/owner/repo#readme")
        assertInvalidLocation("https://github.com:443/owner/repo")
    }

    func testRejectsPathInsideRepository() {
        assertInvalidLocation("https://github.com/owner/repo/tree/main")
        assertInvalidLocation("https://github.com/owner/repo/archive/refs/heads/main.zip")
    }

    func testRejectsIncompleteOrInvalidPaths() {
        assertInvalidLocation("https://github.com/owner")
        assertInvalidLocation("https://github.com/")
        assertInvalidLocation("https://github.com/-owner/repo")
        assertInvalidLocation("https://github.com/owner/.git")
        assertInvalidLocation("https://github.com/owner/..")
    }

    func testRejectsPercentEncodingAndWhitespace() {
        assertInvalidLocation("https://github.com/owner/repo%2Fextra")
        assertInvalidLocation("https://github.com/owner/repo ")
        assertInvalidLocation("https://github.com/ owner/repo")
    }

    // MARK: Limits

    func testRejectsTooManyPins() {
        var limits = ResolvedPackageLimits.default
        limits.maxPins = 1
        let pins = [
            pin(identity: "one", location: "https://github.com/owner/one"),
            pin(identity: "two", location: "https://github.com/owner/two"),
        ]
        assertFails(objectDocument(pins: pins, version: 2), limits: limits) {
            if case .tooManyPins(let limit) = $0 { return limit == 1 }
            return false
        }
    }

    func testRejectsOversizedDocument() {
        var limits = ResolvedPackageLimits.default
        limits.maxBytes = 32
        assertFails(objectDocument(pins: [pin()], version: 2), limits: limits) {
            if case .tooLarge(let actual, let limit) = $0 {
                return actual > 32 && limit == 32
            }
            return false
        }
    }

    func testRejectsDeeplyNestedJSON() {
        var limits = ResolvedPackageLimits.default
        limits.maxJSONDepth = 4
        assertFails(objectDocument(pins: [pin()], version: 2), limits: limits) {
            if case .tooDeep(let limit) = $0 { return limit == 4 }
            return false
        }
    }

    func testRejectsOverlongIdentity() {
        var limits = ResolvedPackageLimits.default
        limits.maxIdentityLength = 5
        assertFails(objectDocument(pins: [pin(identity: "alamofire")], version: 2),
                    limits: limits) {
            if case .fieldTooLong(_, let field, let limit) = $0 {
                return field == "identity" && limit == 5
            }
            return false
        }
    }

    func testRejectsOverlongLocation() {
        var limits = ResolvedPackageLimits.default
        limits.maxLocationLength = 20
        assertFails(objectDocument(pins: [pin()], version: 2), limits: limits) {
            if case .fieldTooLong(_, let field, let limit) = $0 {
                return field == "location" && limit == 20
            }
            return false
        }
    }

    func testRejectsOverlongVersion() {
        var limits = ResolvedPackageLimits.default
        limits.maxVersionLength = 3
        assertFails(objectDocument(pins: [pin(version: "5.8.1")], version: 2),
                    limits: limits) {
            if case .fieldTooLong(_, let field, let limit) = $0 {
                return field == "state.version" && limit == 3
            }
            return false
        }
    }

    func testRejectsOverlongVersionOneDisplayName() {
        var limits = ResolvedPackageLimits.default
        limits.maxDisplayNameLength = 3
        assertFails(objectDocument(pins: [pinV1(package: "Alamofire")], version: 1),
                    limits: limits) {
            if case .fieldTooLong(_, let field, let limit) = $0 {
                return field == "package" && limit == 3
            }
            return false
        }
    }

    func testRejectsOverlongOriginHash() {
        var limits = ResolvedPackageLimits.default
        limits.maxOriginHashLength = 10
        let json = rootDocument(pins: [], version: 3, extra: ",\"originHash\":\"\(sha256)\"")
        assertFails(json, limits: limits) {
            if case .malformedDocument = $0 { return true }
            return false
        }
    }

    func testRejectsNonHexadecimalOriginHash() {
        let json = rootDocument(pins: [], version: 3,
                                extra: ",\"originHash\":\"not-a-hash\"")
        assertFails(json) {
            if case .malformedDocument = $0 { return true }
            return false
        }
    }

    // MARK: Bytes and files

    func testRejectsInvalidUTF8() {
        XCTAssertThrowsError(try ResolvedPackageLockfile.read(data: Data([0xFF, 0xFE, 0xFD]))) {
            guard let error = $0 as? ResolvedPackageError,
                  case .notUTF8 = error else {
                return XCTFail("expected notUTF8, got \($0)")
            }
        }
    }

    func testRejectsEmptyData() {
        XCTAssertThrowsError(try ResolvedPackageLockfile.read(data: Data())) {
            guard let error = $0 as? ResolvedPackageError,
                  case .notJSON = error else {
                return XCTFail("expected notJSON, got \($0)")
            }
        }
    }

    func testRejectsGarbageJSON() {
        XCTAssertThrowsError(
            try ResolvedPackageLockfile.read(data: Data("not json".utf8))) {
            guard let error = $0 as? ResolvedPackageError,
                  case .notJSON = error else {
                return XCTFail("expected notJSON, got \($0)")
            }
        }
    }

    func testReadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Package-\(UUID().uuidString).resolved")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(objectDocument(pins: [pin()], version: 2).utf8).write(to: url)

        let lockfile = try ResolvedPackageLockfile.read(contentsOf: url)
        XCTAssertEqual(lockfile.schemaVersion, 2)
        XCTAssertEqual(lockfile.pins.count, 1)
    }

    func testRefusesRemoteURLWithoutNetworkAccess() {
        let url = URL(string: "https://example.com/Package.resolved")!
        XCTAssertThrowsError(try ResolvedPackageLockfile.read(contentsOf: url)) {
            guard let error = $0 as? ResolvedPackageError,
                  case .notAFile = error else {
                return XCTFail("expected notAFile, got \($0)")
            }
        }
    }

    func testMissingFileIsUnreadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).resolved")
        XCTAssertThrowsError(try ResolvedPackageLockfile.read(contentsOf: url)) {
            guard let error = $0 as? ResolvedPackageError,
                  case .unreadable = error else {
                return XCTFail("expected unreadable, got \($0)")
            }
        }
    }

    func testDirectoryIsNotAFile() {
        XCTAssertThrowsError(
            try ResolvedPackageLockfile.read(contentsOf: FileManager.default.temporaryDirectory)) {
            guard let error = $0 as? ResolvedPackageError,
                  case .notAFile = error else {
                return XCTFail("expected notAFile, got \($0)")
            }
        }
    }

    // MARK: Lookup

    func testPinLookupAndIdentityOrder() throws {
        let pins = [
            pin(identity: "foo", location: "https://github.com/owner/foo"),
            pin(identity: "bar", location: "https://github.com/owner/bar"),
        ]
        let lockfile = try read(objectDocument(pins: pins, version: 2))

        XCTAssertEqual(lockfile.identities, ["foo", "bar"])
        XCTAssertEqual(lockfile.pin(identity: "FOO")?.identity, "foo")
        XCTAssertNil(lockfile.pin(identity: "missing"))
    }

    // MARK: Swift 6 concurrency

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }

    func testModelsAreSendable() throws {
        let lockfile = try read(objectDocument(pins: [pin()], version: 2))
        requireSendable(lockfile)
        requireSendable(try XCTUnwrap(lockfile.pins.first))
        requireSendable(ResolvedPackageLimits.default)
        requireSendable(ResolvedPackageLayout.root)
        requireSendable(ResolvedPackageError.missingPins)
        requireSendable(Data())
    }

    func testParsingOffTheMainActor() async throws {
        let json = objectDocument(pins: [pin()], version: 2)
        let lockfile = try await Task.detached {
            try ResolvedPackageLockfile.read(data: Data(json.utf8))
        }.value
        XCTAssertEqual(lockfile.pins.map(\.identity), ["alamofire"])
    }
}
