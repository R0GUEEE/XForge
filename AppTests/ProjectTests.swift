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

    func testGuestShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(GuestShell.quote("one'two"), "'one'\\''two'")
        XCTAssertEqual(GuestShell.environment(["TOKEN": "a b'c"]), "TOKEN='a b'\\''c' ")
    }

    func testProjectNameValidationAndSafePath() throws {
        let name = try Project.validatedName("Demo-App_2")
        XCTAssertEqual(name, "Demo-App_2")

        let project = Project(
            name: name,
            rootPath: Project.path(forValidatedName: name)
        )
        XCTAssertTrue(project.hasSafeRootPath)
        XCTAssertFalse(Project(name: name, rootPath: "/tmp/Demo-App_2").hasSafeRootPath)
        XCTAssertThrowsError(try Project.validatedName("bad/name"))
        XCTAssertThrowsError(try Project.validatedName("bad'; rm -rf /"))
    }
}
