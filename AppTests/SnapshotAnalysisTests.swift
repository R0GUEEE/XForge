import XCTest
@testable import XForge

final class SnapshotAnalysisTests: XCTestCase {
    private let minimalPBX = #"""
    { archiveVersion = 1; objectVersion = 56; objects = {
      A = { isa = PBXProject; buildConfigurationList = PC; mainGroup = G; name = Demo; targets = (T,); };
      G = { isa = PBXGroup; children = (); sourceTree = "<group>"; };
      T = { isa = PBXNativeTarget; buildConfigurationList = TC; buildPhases = (); name = Demo; productName = Demo; productType = "com.apple.product-type.application"; };
      PC = { isa = XCConfigurationList; buildConfigurations = (PD,); defaultConfigurationName = Debug; };
      TC = { isa = XCConfigurationList; buildConfigurations = (TD,); defaultConfigurationName = Debug; };
      PD = { isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
      TD = { isa = XCBuildConfiguration; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = com.example.demo; }; name = Debug; };
    }; rootObject = A; }
    """#

    func testInventoryDetectsProjectsWorkspacesAndDependencyMarkers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-inventory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example/App.xcodeproj", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example/App.xcworkspace", isDirectory: true), withIntermediateDirectories: true)
        try Data("// swift-tools-version: 5.9\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
        try Data("[submodule \"Framework\"]\npath = Framework\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        try Data("*.bin filter=lfs diff=lfs merge=lfs -text\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 5\n".utf8)
            .write(to: root.appendingPathComponent("asset.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let inventory = SnapshotInventory.scan(root: root)
        XCTAssertEqual(inventory.xcodeProjects, ["Example/App.xcodeproj"])
        XCTAssertEqual(inventory.workspaces, ["Example/App.xcworkspace"])
        XCTAssertEqual(inventory.packageManifests, ["Package.swift"])
        XCTAssertTrue(inventory.dependencyIndicators.contains { $0.contains("submodules") })
        XCTAssertTrue(inventory.dependencyIndicators.contains { $0.contains("Git LFS") })
        XCTAssertEqual(inventory.lfsPointerFiles, ["asset.bin"])
    }

    func testGeneratedPBXParsesAsSingleAppWithSwiftSources() throws {
        let pbx = try XcodeProjectHandoff.makeProject(
            name: "SampleApp",
            bundleID: "com.example.sample",
            sourceFiles: ["Sources/SampleApp/App.swift", "Sources/SampleApp/Scene.swift"],
            minimumIOS: "17.0"
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-generated-pbx-\(UUID())", isDirectory: true)
        let bundle = dir.appendingPathComponent("SampleApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try pbx.write(to: bundle.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let summary = try XcodeProjectReader.read(at: bundle)
        XCTAssertEqual(summary.applicationTargets.count, 1)
        XCTAssertEqual(summary.targets.first?.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(summary.targets.first?.sourceFiles.count, 2)
        XCTAssertEqual(summary.targets.first?.configurationNames.sorted(), ["Debug", "Release"])
    }

    func testDetectorPrefersRealXcodeAppOverRootPackageManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-detect-\(UUID())", isDirectory: true)
        let project = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try minimalPBX.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 5.9\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .xcodeProject(let subpath, let summary) = try GitHubSnapshotDetector.detect(in: root) else {
            return XCTFail("an app .xcodeproj should outrank a repository-root tooling Package.swift")
        }
        XCTAssertNil(subpath)
        XCTAssertEqual(summary.applicationTargets.map(\.name), ["Demo"])
    }

    func testDetectorKeepsMultipleXcodeCandidatesImportableAndChoosesStableFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-multiple-projects-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Beta", "Alpha"] {
            let bundle = root.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let pbx = minimalPBX.replacingOccurrences(of: "name = Demo;", with: "name = \(name);")
            try pbx.write(to: bundle.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        }
        guard case .xcodeProject(let subpath, let summary) = try GitHubSnapshotDetector.detect(in: root) else {
            return XCTFail("multiple projects should remain importable for analysis")
        }
        XCTAssertNil(subpath)
        XCTAssertEqual(summary.name, "Alpha")
    }

    func testDetectorFallsBackToStandaloneSwiftPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xforge-package-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .swiftPackage = try GitHubSnapshotDetector.detect(in: root) else {
            return XCTFail("a repo without an Xcode project should still be recognized as SwiftPM")
        }
    }

    func testGeneratedProjectRejectsInvalidBundleIdentifierAndVersion() {
        XCTAssertThrowsError(try XcodeProjectHandoff.makeProject(
            name: "BadApp", bundleID: "$(PRODUCT_BUNDLE_IDENTIFIER)", sourceFiles: ["Sources/App.swift"], minimumIOS: "17.0"
        ))
        XCTAssertThrowsError(try XcodeProjectHandoff.makeProject(
            name: "BadApp", bundleID: "com.example.bad", sourceFiles: ["Sources/App.swift"], minimumIOS: "$(IPHONEOS_DEPLOYMENT_TARGET)"
        ))
    }

    func testGeneratedProjectRejectsTraversalPaths() {
        XCTAssertThrowsError(try XcodeProjectHandoff.makeProject(
            name: "BadApp", bundleID: "com.example.bad", sourceFiles: ["../../outside.swift"], minimumIOS: "17.0"
        ))
    }
}
