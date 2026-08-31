import XCTest
@testable import XForge

final class ProjectTests: XCTestCase {
    func testProjectDefaults() {
        let p = Project(name: "Demo", rootPath: "/root/projects/Demo")
        XCTAssertEqual(p.organizationIdentifier, "com.example")
        XCTAssertEqual(p.packageManifestPath, "/root/projects/Demo/Package.swift")
        XCTAssertEqual(p.ipaOutputPath, "/root/projects/Demo/.build/xforge-Demo.ipa")
    }

    func testBuildConfigurationRawValues() {
        XCTAssertEqual(BuildConfiguration.debug.rawValue, "debug")
        XCTAssertEqual(BuildConfiguration.release.rawValue, "release")
    }
}
