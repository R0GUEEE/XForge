import XCTest
import ZIPFoundation
@testable import XForge

/// Validates the host-side IPA packager: given a compiled `.app` fixture, it produces
/// a valid `.ipa` containing the correct Info.plist, entitlements, and Payload layout.
final class IPABuilderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPABuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Build a fake compiled .app bundle on disk for the packager to consume.
    private func makeFixtureApp(name: String = "Demo") throws -> URL {
        let app = tempDir.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        // A minimal Info.plist + a placeholder binary.
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.Demo"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        try Data("x".utf8).write(to: app.appendingPathComponent(name))
        return app
    }

    func testInfoPlistDictionary() {
        let info = AppInfo(bundleIdentifier: "com.acme.App", displayName: "App", version: "2.1", buildNumber: "7", minimumOSVersion: "16.0")
        let dict = IPABuilder.infoPlistDictionary(info)
        XCTAssertEqual(dict["CFBundleIdentifier"] as? String, "com.acme.App")
        XCTAssertEqual(dict["CFBundleDisplayName"] as? String, "App")
        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, "2.1")
        XCTAssertEqual(dict["CFBundleVersion"] as? String, "7")
        XCTAssertEqual(dict["MinimumOSVersion"] as? String, "16.0")
        XCTAssertEqual(dict["CFBundlePackageType"] as? String, "APPL")
    }

    func testBuildIPACreatesValidArchive() throws {
        let app = try makeFixtureApp()
        let appInfo = AppInfo(bundleIdentifier: "com.acme.Demo", displayName: "Demo", version: "1.0", buildNumber: "1", minimumOSVersion: "16.0")

        let ipa = try IPABuilder.buildIPA(appBundle: app, appInfo: appInfo, outputDir: tempDir)

        // The .ipa exists and is a real zip.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path))
        let archive = try Archive(url: ipa, accessMode: .read)
        let paths = archive.map { $0.path }
        XCTAssertTrue(paths.contains("Payload/Demo.app/Info.plist"), "expected Payload/Demo.app/Info.plist, got \(paths)")
        XCTAssertTrue(paths.contains("Payload/Demo.app/Entitlements.plist"))
        XCTAssertTrue(paths.contains("Payload/Demo.app/Demo"), "expected the binary inside the app")
    }

    func testBuildIPAOverwritesInfoPlist() throws {
        let app = try makeFixtureApp(name: "Renamed")
        let appInfo = AppInfo(bundleIdentifier: "com.acme.Renamed", displayName: "Renamed", version: "3.0", buildNumber: "9", minimumOSVersion: "17.0")

        _ = try IPABuilder.buildIPA(appBundle: app, appInfo: appInfo, outputDir: tempDir)
        let ipa = tempDir.appendingPathComponent("Renamed.ipa")
        let archive = try Archive(url: ipa, accessMode: .read)
        guard let entry = archive["Payload/Renamed.app/Info.plist"] else {
            return XCTFail("Info.plist missing from archive")
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(dict?["CFBundleIdentifier"] as? String, "com.acme.Renamed")
        XCTAssertEqual(dict?["CFBundleShortVersionString"] as? String, "3.0")
    }
}
