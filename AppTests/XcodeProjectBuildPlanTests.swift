import XCTest
@testable import XForge

final class XcodeProjectBuildPlanTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("xforge-xcode-plan-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeProject(extraPhase: String = "", extraObjects: String = "", source: String = "import SwiftUI\n@main struct DemoApp: App { var body: some Scene { WindowGroup { Text(\"Hi\") } } }\n") throws {
        try source.write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let phases = extraPhase.isEmpty ? "(SRC,);" : "(SRC, \(extraPhase));"
        let fileList = extraPhase.isEmpty ? "(BUILD,);" : "(BUILD, RESOURCE_BUILD);"
        let pbx = """
        // !$*UTF8*$!
        { archiveVersion = 1; objectVersion = 56; objects = {
          FILE = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
          PRODUCT = { isa = PBXFileReference; explicitFileType = wrapper.application; path = Demo.app; sourceTree = BUILT_PRODUCTS_DIR; };
          BUILD = { isa = PBXBuildFile; fileRef = FILE; };
          SRC = { isa = PBXSourcesBuildPhase; files = (BUILD,); runOnlyForDeploymentPostprocessing = 0; };
          \(extraObjects)
          ROOT_GROUP = { isa = PBXGroup; children = (FILE, PRODUCTS); sourceTree = "<group>"; };
          PRODUCTS = { isa = PBXGroup; children = (PRODUCT,); name = Products; sourceTree = "<group>"; };
          TARGET_CFG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = com.example.demo; PRODUCT_NAME = Demo; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; }; };
          TARGET_CFG_LIST = { isa = XCConfigurationList; buildConfigurations = (TARGET_CFG,); defaultConfigurationName = Debug; };
          PROJECT_CFG = { isa = XCBuildConfiguration; name = Debug; buildSettings = {}; };
          PROJECT_CFG_LIST = { isa = XCConfigurationList; buildConfigurations = (PROJECT_CFG,); defaultConfigurationName = Debug; };
          TARGET = { isa = PBXNativeTarget; name = Demo; productName = Demo; productReference = PRODUCT; productType = "com.apple.product-type.application"; buildConfigurationList = TARGET_CFG_LIST; buildPhases = \(phases); };
          PROJECT = { isa = PBXProject; mainGroup = ROOT_GROUP; targets = (TARGET,); buildConfigurationList = PROJECT_CFG_LIST; };
        }; rootObject = PROJECT; }
        """
        try pbx.write(to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
    }

    func testPlansOneLiteralSingleSwiftAppTarget() throws {
        try writeProject()
        let projectName = "XcodePlan-\(UUID().uuidString.prefix(8))"
        let project = Project(name: projectName, rootPath: Project.path(forValidatedName: projectName), kind: .xcodeProject)
        let destination = project.rootURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Demo.xcodeproj"), to: destination.appendingPathComponent("Demo.xcodeproj"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("App.swift"), to: destination.appendingPathComponent("App.swift"))
        let plan = try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug)
        XCTAssertEqual(plan.moduleName, "Demo")
        XCTAssertEqual(plan.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(plan.minimumIOSVersion, "17.0")
        XCTAssertEqual(plan.swiftSources.map(\.lastPathComponent), ["App.swift"])
        XCTAssertTrue(plan.frameworks.contains("SwiftUI"))
        try FileManager.default.removeItem(at: destination)
    }

    func testRejectsXcodeResourcesBeforeBuilding() throws {
        try writeProject(extraPhase: "RES")
        // The phase declares a real resource build input, not an empty phase.
        let pbxURL = root.appendingPathComponent("Demo.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: pbxURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "FILE = { isa = PBXFileReference;", with: "RESOURCE = { isa = PBXFileReference; path = data.json; sourceTree = \"<group>\"; }; RESOURCE_BUILD = { isa = PBXBuildFile; fileRef = RESOURCE; }; RES = { isa = PBXResourcesBuildPhase; files = (RESOURCE_BUILD,); }; FILE = { isa = PBXFileReference;")
        try text.write(to: pbxURL, atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        let projectName = "XcodePlan-\(UUID().uuidString.prefix(8))"
        let project = Project(name: projectName, rootPath: Project.path(forValidatedName: projectName), kind: .xcodeProject)
        let destination = project.rootURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Demo.xcodeproj"), to: destination.appendingPathComponent("Demo.xcodeproj"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("App.swift"), to: destination.appendingPathComponent("App.swift"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("data.json"), to: destination.appendingPathComponent("data.json"))
        XCTAssertThrowsError(try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug))
        try FileManager.default.removeItem(at: destination)
    }

    func testRejectsImportsOutsideExplicitSDKAllowlist() throws {
        try writeProject(source: "import SwiftUI\nimport SomePackage\n@main struct DemoApp: App { var body: some Scene { WindowGroup { Text(\"Hi\") } } }")
        let projectName = "XcodePlan-\(UUID().uuidString.prefix(8))"
        let project = Project(name: projectName, rootPath: Project.path(forValidatedName: projectName), kind: .xcodeProject)
        let destination = project.rootURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Demo.xcodeproj"), to: destination.appendingPathComponent("Demo.xcodeproj"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("App.swift"), to: destination.appendingPathComponent("App.swift"))
        XCTAssertThrowsError(try XcodeProjectBuildPlanner.makePlan(project: project, configuration: .debug))
        try FileManager.default.removeItem(at: destination)
    }
}
