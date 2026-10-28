import XCTest
@testable import XForge

final class XcodeProjectBuildPlanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-xcode-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeProject(source: String) throws -> Project {
        try XcodeProjectTests.pbxproj.write(
            to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"),
            atomically: true, encoding: .utf8
        )
        let sources = root.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try source.write(to: sources.appendingPathComponent("AppDelegate.swift"), atomically: true, encoding: .utf8)
        let name = "XcodePlan-\(UUID().uuidString.prefix(8))"
        let project = Project(name: name, rootPath: Project.path(forValidatedName: name), kind: .xcodeProject)
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Demo.xcodeproj"), to: project.rootURL.appendingPathComponent("Demo.xcodeproj"))
        try FileManager.default.copyItem(at: sources, to: project.rootURL.appendingPathComponent("Demo", isDirectory: true))
        return project
    }

    func testPlansOneLiteralSingleSwiftApplicationTarget() throws {
        let project = try writeProject(source: "import SwiftUI\n@main struct DemoApp: App { var body: some Scene { WindowGroup { Text(\"Hi\") } } }\n")
        defer { try? FileManager.default.removeItem(at: project.rootURL) }
        let plan = try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug)
        XCTAssertEqual(plan.moduleName, "Demo")
        XCTAssertEqual(plan.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(plan.minimumIOSVersion, "17.0")
        XCTAssertEqual(plan.swiftSources.map(\.lastPathComponent), ["AppDelegate.swift"])
        XCTAssertTrue(plan.frameworks.contains("SwiftUI"))
    }

    func testRejectsImportsOutsideExplicitSDKAllowlist() throws {
        let project = try writeProject(source: "import SwiftUI\nimport SomePackage\n@main struct DemoApp: App { var body: some Scene { WindowGroup { Text(\"Hi\") } } }\n")
        defer { try? FileManager.default.removeItem(at: project.rootURL) }
        XCTAssertThrowsError(try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug))
    }

    func testRejectsEscapingOrMissingSourceFiles() throws {
        let text = XcodeProjectTests.pbxproj.replacingOccurrences(of: "path = AppDelegate.swift;", with: "path = ../outside.swift;")
        XCTAssertFalse(text.isEmpty)
        let project = try writeProject(source: "import SwiftUI\n@main struct DemoApp: App { var body: some Scene { WindowGroup { Text(\"Hi\") } } }\n")
        defer { try? FileManager.default.removeItem(at: project.rootURL) }
        let pbx = project.rootURL.appendingPathComponent("Demo.xcodeproj/project.pbxproj")
        try text.write(to: pbx, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug))
    }
}
