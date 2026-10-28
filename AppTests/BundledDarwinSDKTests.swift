import XCTest
import ZIPFoundation
@testable import XForge

/// Tests for the bundled-Darwin-SDK path: manifest handling, the first-run
/// decision table, integrity checking and archive unpacking.
///
/// The install itself cannot run here — it moves ~1.5 GB into the app container
/// and needs a real Darwin SDK — so the tests cover the halves that decide *what*
/// happens: which archive is trusted, whether an automatic install is allowed, and
/// whether the unpacked tree is the shape `NativeSDK` expects.
final class BundledDarwinSDKTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-bundled-sdk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func manifest(
        tag: String = "darwin-sdk-7",
        sha: String = String(repeating: "a", count: 64),
        bytes: Int64 = 456_769_875
    ) -> BundledDarwinSDK.Manifest {
        BundledDarwinSDK.Manifest(
            schemaVersion: BundledDarwinSDK.Manifest.currentSchemaVersion,
            releaseTag: tag,
            assetName: BundledDarwinSDK.archiveName,
            sourceURL: "https://example.com/\(tag)/darwin.artifactbundle.zip",
            sha256: sha,
            byteCount: bytes,
            installedByteCount: 1_500_000_000,
            sdkVersion: "27.0",
            license: "test fixture",
            generatedAt: "2026-10-28T00:00:00Z"
        )
    }

    /// A `BundledSDK/` folder as the app would find it.
    private func bundledFolder(withManifest: Bool = true,
                               archiveBytes: Data = Data("PK\u{3}\u{4}not-really".utf8)) throws -> URL {
        let folder = root.appendingPathComponent(BundledDarwinSDK.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try archiveBytes.write(to: folder.appendingPathComponent(BundledDarwinSDK.archiveName))
        if withManifest {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest())
                .write(to: folder.appendingPathComponent(BundledDarwinSDK.manifestName))
        }
        return folder
    }

    /// A minimal but *valid* `darwin.artifactbundle` tree for the unpack test.
    private func writeSDKFixture(at bundle: URL) throws {
        let fm = FileManager.default
        let sdkRoot = bundle.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/"
                                                    + "Developer/SDKs/iPhoneOS27.0.sdk",
                                                    isDirectory: true)
        try fm.createDirectory(at: sdkRoot, withIntermediateDirectories: true)
        try Data("// stub\n".utf8)
            .write(to: sdkRoot.appendingPathComponent("usr-include-marker.h"))
        let metadata: [String: Any] = [
            "schemaVersion": "4.0",
            "targetTriples": [
                "arm64-apple-ios": [
                    "sdkRootPath": "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk",
                    "includeSearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                    "librarySearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                    "swiftResourcesPath": "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                    "swiftStaticResourcesPath": "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bundle.appendingPathComponent("swift-sdk.json"))
        try Data("27.0\n".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))
    }

    private func zip(directory: URL, name: String, keepParent: Bool = true) throws -> URL {
        let archive = root.appendingPathComponent(name)
        try FileManager.default.zipItem(at: directory, to: archive, shouldKeepParent: keepParent)
        return archive
    }

    // MARK: - Manifest

    func testManifestRoundTrips() throws {
        let original = manifest()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try BundledDarwinSDK.decodeManifest(data), original)
    }

    func testManifestRejectsUnknownSchema() throws {
        var newer = manifest()
        newer.schemaVersion = BundledDarwinSDK.Manifest.currentSchemaVersion + 1
        let data = try JSONEncoder().encode(newer)
        XCTAssertThrowsError(try BundledDarwinSDK.decodeManifest(data)) { error in
            guard case BundledDarwinSDK.Error.unverified(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("schemaVersion"), reason)
        }
    }

    func testManifestRejectsMissingDigest() throws {
        var noDigest = manifest()
        noDigest.sha256 = ""
        let data = try JSONEncoder().encode(noDigest)
        XCTAssertThrowsError(try BundledDarwinSDK.decodeManifest(data))
    }

    // MARK: - Discovery

    func testDiscoveryFindsArchiveAndManifest() throws {
        let folder = try bundledFolder()
        guard case .bundled(let archive, let parsed) = BundledDarwinSDK.discovery(in: folder) else {
            return XCTFail("expected a bundled discovery")
        }
        XCTAssertEqual(archive.lastPathComponent, BundledDarwinSDK.archiveName)
        XCTAssertEqual(parsed.releaseTag, "darwin-sdk-7")
    }

    /// An archive with no manifest is *present but unverifiable*: usable on
    /// request, never on the first run.
    func testArchiveWithoutManifestIsUnverified() throws {
        let folder = try bundledFolder(withManifest: false)
        guard case .unverified = BundledDarwinSDK.discovery(in: folder) else {
            return XCTFail("expected unverified")
        }
    }

    func testEmptyOrMissingFolderIsNotBundled() throws {
        XCTAssertEqual(BundledDarwinSDK.discovery(in: nil), .notBundled)
        XCTAssertEqual(BundledDarwinSDK.discovery(in: root), .notBundled)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(BundledDarwinSDK.discovery(in: empty), .notBundled)
    }

    // MARK: - Decision table

    private func bundledDiscovery() throws -> BundledDarwinSDK.Discovery {
        BundledDarwinSDK.discovery(in: try bundledFolder())
    }

    func testFirstRunInstallsWhenNothingIsThere() throws {
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: try bundledDiscovery(),
                                                 state: .init())
        XCTAssertEqual(decision, .install)
    }

    /// The central safety rule: an existing SDK is never replaced by an automatic
    /// install, however many bundles the new build carries.
    func testExistingSDKIsNeverReplacedAutomatically() throws {
        let decision = BundledDarwinSDK.decision(isInstalled: true,
                                                 discovery: try bundledDiscovery(),
                                                 state: .init())
        XCTAssertEqual(decision, .alreadyInstalled)
    }

    func testRemovedBundleIsNotReinstalled() throws {
        var state = BundledDarwinSDK.State()
        state.declined = ["darwin-sdk-7"]
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: try bundledDiscovery(),
                                                 state: state)
        XCTAssertEqual(decision, .declined)
    }

    func testFailedAttemptIsNotRetriedOnEveryLaunch() throws {
        var state = BundledDarwinSDK.State()
        state.attempts = ["darwin-sdk-7"]
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: try bundledDiscovery(),
                                                 state: state)
        XCTAssertEqual(decision, .previouslyAttempted)
    }

    /// A *new* bundled release is allowed to install after an older one was
    /// declined — the state is per tag, not a blanket switch.
    func testNewReleaseIsAllowedAfterAnOlderOneWasDeclined() throws {
        var state = BundledDarwinSDK.State()
        state.declined = ["darwin-sdk-6"]
        state.attempts = ["darwin-sdk-6"]
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: try bundledDiscovery(),
                                                 state: state)
        XCTAssertEqual(decision, .install)
    }

    func testUnverifiedBundleIsNeverAutomatic() throws {
        let folder = try bundledFolder(withManifest: false)
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: BundledDarwinSDK.discovery(in: folder),
                                                 state: .init())
        XCTAssertEqual(decision, .unverified)
    }

    func testNoBundleMeansNoAutomaticInstall() {
        let decision = BundledDarwinSDK.decision(isInstalled: false,
                                                 discovery: .notBundled,
                                                 state: .init())
        XCTAssertEqual(decision, .notBundled)
    }

    // MARK: - State persistence

    func testStateRoundTripsAndKeepsRemovals() throws {
        let url = root.appendingPathComponent("state/bundled-sdk-state.json")
        BundledDarwinSDK.recordAttempt(tag: "darwin-sdk-7", at: url)
        BundledDarwinSDK.recordAttempt(tag: "darwin-sdk-7", at: url)   // idempotent
        BundledDarwinSDK.recordUserRemoval(tag: "darwin-sdk-7", at: url)

        let state = BundledDarwinSDK.loadState(at: url)
        XCTAssertEqual(state.attempts, ["darwin-sdk-7"])
        XCTAssertEqual(state.declined, ["darwin-sdk-7"])
    }

    func testMissingStateFileLoadsAsEmpty() {
        XCTAssertEqual(BundledDarwinSDK.loadState(at: root.appendingPathComponent("nope.json")),
                       BundledDarwinSDK.State())
    }

    // MARK: - Integrity

    func testSHA256MatchesTheKnownVector() throws {
        let file = root.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try BundledDarwinSDK.sha256Hex(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testIntegrityFailureIsReportedBeforeUnpacking() throws {
        // A manifest whose digest cannot match the archive: the install must fail
        // with `.integrity`, and the (empty) destination must stay untouched.
        let folder = try bundledFolder()
        let archive = folder.appendingPathComponent(BundledDarwinSDK.archiveName)
        let destination = root.appendingPathComponent("native-sdk", isDirectory: true)
        let stateURL = destination.appendingPathComponent("state.json")

        XCTAssertThrowsError(
            try BundledDarwinSDK.installSynchronously(discovery: BundledDarwinSDK.discovery(in: folder),
                                                      in: destination,
                                                      stateURL: stateURL)
        ) { error in
            guard case BundledDarwinSDK.Error.integrity = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the bundled archive must never be removed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: NativeSDK.installedBundle(in: destination).path),
            "a failed verification must not create a bundle")
    }

    // MARK: - Commit safety (the race the automatic install must lose safely)

    private func stagedBundle() throws -> URL {
        let bundle = root.appendingPathComponent("staged/darwin.artifactbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try writeSDKFixture(at: bundle)
        return bundle
    }

    /// A user import that lands between "no SDK installed" and the commit must not
    /// be deleted by an automatic install.
    func testCommitRefusesToReplaceAnExistingBundle() throws {
        let destination = NativeSDK.installedBundle(in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let userFile = destination.appendingPathComponent("user-import-marker")
        try Data("keep me".utf8).write(to: userFile)

        let staged = try stagedBundle()
        XCTAssertThrowsError(
            try NativeSDK.commit(preparedBundle: staged, to: destination, replacing: false)
        ) { error in
            guard case NativeSDKError.destinationOccupied = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path),
                      "the existing SDK must survive a refused commit")
    }

    /// An automatic install is refused before the destination is even touched, so
    /// even a bad archive cannot remove what is there.
    func testInstallRefusesWhenDestinationIsOccupied() throws {
        let destination = NativeSDK.installedBundle(in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("existing")
        try Data("x".utf8).write(to: marker)

        let folder = try bundledFolder()   // manifest digest deliberately does not match
        XCTAssertThrowsError(
            try BundledDarwinSDK.installSynchronously(discovery: BundledDarwinSDK.discovery(in: folder),
                                                      in: root,
                                                      stateURL: root.appendingPathComponent("s.json"))
        ) { error in
            guard case NativeSDKError.destinationOccupied = error else {
                return XCTFail("expected destinationOccupied, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// `replacing: true` swaps atomically: the new bundle is there, and nothing of
    /// the old one is left behind.
    func testCommitReplacesWhenAskedTo() throws {
        let destination = NativeSDK.installedBundle(in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old-sdk-marker"))

        let staged = try stagedBundle()
        try NativeSDK.commit(preparedBundle: staged, to: destination, replacing: true)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("old-sdk-marker").path))
        XCTAssertNoThrow(try NativeSDK.layout(at: destination))
    }

    /// The install destination follows the injected root, not the app container:
    /// this is what makes the tests above meaningful.
    func testDestinationIsScopedToTheGivenRoot() {
        let other = root.appendingPathComponent("other-native-sdk", isDirectory: true)
        XCTAssertEqual(NativeSDK.installedBundle(in: other).deletingLastPathComponent().path,
                       other.path)
        XCTAssertNotEqual(NativeSDK.installedBundle(in: other).path,
                          NativeSDK.installedBundle.path)
    }

    // MARK: - Unpacking

    func testUnpackFindsTheBundleDirectory() throws {
        let source = root.appendingPathComponent("source/darwin.artifactbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writeSDKFixture(at: source)
        // The bundle itself is the archive's root, which is how the published
        // `darwin.artifactbundle.zip` is laid out.
        let archive = try zip(directory: source, name: "ok.zip")

        let destination = root.appendingPathComponent("unpacked", isDirectory: true)
        let bundle = try BundledDarwinSDK.unpack(archive, into: destination)
        XCTAssertEqual(bundle.lastPathComponent, BundledDarwinSDK.bundleDirectoryName)

        // The unpacked tree is what `NativeSDK` will validate after the move.
        let layout = try NativeSDK.layout(at: bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.sdkRoot.path))
        XCTAssertEqual(layout.sdkRoot.lastPathComponent, "iPhoneOS27.0.sdk")
    }

    /// The archive's contents at the root — a layout the published zip has used.
    func testUnpackAcceptsBundleContentsAtTheRoot() throws {
        let staging = root.appendingPathComponent("flat-src", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeSDKFixture(at: staging)
        let archive = try zip(directory: staging, name: "flat.zip", keepParent: false)

        let destination = root.appendingPathComponent("flat-out", isDirectory: true)
        let bundle = try BundledDarwinSDK.unpack(archive, into: destination)
        XCTAssertEqual(bundle.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertNoThrow(try NativeSDK.layout(at: bundle))
    }

    /// One wrapper directory around the bundle — the other shape in the wild.
    func testUnpackAcceptsASingleWrapperDirectory() throws {
        let wrapper = root.appendingPathComponent("wrapper/Xcode_27", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try writeSDKFixture(at: wrapper)
        let archive = try zip(directory: root.appendingPathComponent("wrapper"),
                              name: "wrapper.zip")

        let destination = root.appendingPathComponent("wrapper-out", isDirectory: true)
        let bundle = try BundledDarwinSDK.unpack(archive, into: destination)
        XCTAssertEqual(bundle.lastPathComponent, "Xcode_27")
        XCTAssertNoThrow(try NativeSDK.layout(at: bundle))
    }

    func testUnpackRefusesAnArchiveWithoutABundle() throws {
        let junk = root.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: junk.appendingPathComponent("readme.txt"))
        let archive = try zip(directory: junk, name: "junk.zip")

        XCTAssertThrowsError(
            try BundledDarwinSDK.unpack(archive, into: root.appendingPathComponent("junk-out"))
        ) { error in
            guard case BundledDarwinSDK.Error.noBundleInsideArchive = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
