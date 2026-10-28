import XCTest
@testable import XForge

/// The import flow may show an existing `.xcodeproj`, but it must never pretend
/// that project can be built or add it to the buildable project list. These tests
/// pin the decision `ProjectImportInspector` makes for each kind of folder, and that
/// a successful inspection is the reader's real output — targets, product types,
/// sources and settings — not a folder-name guess.
final class ProjectImportInspectionTests: XCTestCase {

    /// A project with two targets, so "actual targets" means more than the one the
    /// source folder happens to be named after: an app and the framework it uses.
    /// Settings are split across project and target level, and one source sits in a
    /// nested group, so the summary has to come from the reader's merge and group
    /// walk rather than from a shortcut.
    private static let pbxproj = #"""
    // !$*UTF8*$!
    {
        archiveVersion = 1;
        classes = {
        };
        objectVersion = 56;
        objects = {

    /* Begin PBXBuildFile section */
            AA01 = {isa = PBXBuildFile; fileRef = AA02; };
            AA03 = {isa = PBXBuildFile; fileRef = AA04; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
            AA02 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
            AA04 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DemoKit.swift; sourceTree = "<group>"; };
            AA05 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Demo.app; sourceTree = BUILT_PRODUCTS_DIR; };
            AA06 = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = DemoKit.framework; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
            AA10 = {
                isa = PBXGroup;
                children = (
                    AA11,
                    AA12,
                );
                sourceTree = "<group>";
            };
            AA11 = {
                isa = PBXGroup;
                children = (
                    AA02,
                    AA04,
                );
                path = Demo;
                sourceTree = "<group>";
            };
            AA12 = {
                isa = PBXGroup;
                children = (
                    AA05,
                    AA06,
                );
                name = Products;
                sourceTree = "<group>";
            };
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
            AA20 = {
                isa = PBXNativeTarget;
                buildConfigurationList = AA40;
                buildPhases = (
                    AA30,
                );
                name = Demo;
                productName = Demo;
                productReference = AA05;
                productType = "com.apple.product-type.application";
            };
            AA21 = {
                isa = PBXNativeTarget;
                buildConfigurationList = AA41;
                buildPhases = (
                    AA31,
                );
                name = DemoKit;
                productName = DemoKit;
                productReference = AA06;
                productType = "com.apple.product-type.framework";
            };
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
            AA50 = {
                isa = PBXProject;
                buildConfigurationList = AA42;
                mainGroup = AA10;
                name = DemoProject;
                targets = (
                    AA20,
                    AA21,
                );
            };
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
            AA30 = {
                isa = PBXSourcesBuildPhase;
                buildActionMask = 2147483647;
                files = (
                    AA01,
                );
                runOnlyForDeploymentPostprocessing = 0;
            };
            AA31 = {
                isa = PBXSourcesBuildPhase;
                buildActionMask = 2147483647;
                files = (
                    AA03,
                );
                runOnlyForDeploymentPostprocessing = 0;
            };
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
            AA60 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
                    PRODUCT_NAME = Demo;
                };
                name = Debug;
            };
            AA61 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
                    PRODUCT_NAME = Demo;
                };
                name = Release;
            };
            AA62 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = com.example.demokit;
                    PRODUCT_NAME = DemoKit;
                };
                name = Debug;
            };
            AA63 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    PRODUCT_BUNDLE_IDENTIFIER = com.example.demokit;
                    PRODUCT_NAME = DemoKit;
                };
                name = Release;
            };
            AA64 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    IPHONEOS_DEPLOYMENT_TARGET = 16.0;
                    SDKROOT = iphoneos;
                };
                name = Debug;
            };
            AA65 = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    IPHONEOS_DEPLOYMENT_TARGET = 16.0;
                    SDKROOT = iphoneos;
                };
                name = Release;
            };
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
            AA40 = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    AA60,
                    AA61,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Debug;
            };
            AA41 = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    AA62,
                    AA63,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Debug;
            };
            AA42 = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    AA64,
                    AA65,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Debug;
            };
    /* End XCConfigurationList section */
        };
        rootObject = AA50;
    }
    """#

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - Fixtures

    private func makeDirectory(_ name: String? = nil) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-import-\(UUID().uuidString)", isDirectory: true)
        let directory = name.map { parent.appendingPathComponent($0, isDirectory: true) } ?? parent
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(parent)
        return directory
    }

    @discardableResult
    private func writeProject(in directory: URL, named name: String = "Demo") throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.pbxproj.write(
            to: bundle.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        return bundle
    }

    private func writeManifest(in directory: URL) throws {
        try "// swift-tools-version: 5.9\n".write(
            to: directory.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Swift packages

    func testFolderWithManifestIsAnImportableSwiftPackage() throws {
        let directory = try makeDirectory()
        try writeManifest(in: directory)

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .swiftPackage = inspection else {
            return XCTFail("expected a Swift package, got \(inspection)")
        }
        XCTAssertTrue(inspection.isImportable)
    }

    /// A repository may keep an Xcode project beside its Package.swift. Import copies
    /// and builds the package, so the manifest decides — the reader must not turn an
    /// importable folder into a read-only inspection.
    func testManifestWinsOverAnXcodeProjectInTheSameFolder() throws {
        let directory = try makeDirectory()
        try writeManifest(in: directory)
        try writeProject(in: directory)

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .swiftPackage = inspection else {
            return XCTFail("expected the Package.swift to win, got \(inspection)")
        }
        XCTAssertTrue(inspection.isImportable)
    }

    // MARK: - Xcode projects

    func testFolderWithXcodeProjectIsInspectedAndNotImportable() throws {
        let directory = try makeDirectory()
        let bundle = try writeProject(in: directory)

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .xcodeProject(let summary) = inspection else {
            return XCTFail("expected an inspected Xcode project, got \(inspection)")
        }
        XCTAssertFalse(inspection.isImportable)
        XCTAssertEqual(summary.projectURL.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(summary.projectDirectory.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(summary.name, "DemoProject")
    }

    /// "Show the actual targets" is the point of the milestone: both targets, their
    /// product types, bundle identifiers and sources must survive the trip from
    /// project.pbxproj to the summary the UI renders.
    func testInspectionShowsEveryActualTarget() throws {
        let directory = try makeDirectory()
        try writeProject(in: directory)

        guard case .xcodeProject(let summary) = ProjectImportInspector.inspect(directory) else {
            return XCTFail("expected an inspected Xcode project")
        }

        XCTAssertEqual(summary.targets.map(\.name), ["Demo", "DemoKit"])
        XCTAssertEqual(summary.applicationTargets.map(\.name), ["Demo"])

        let app = try XCTUnwrap(summary.targets.first { $0.name == "Demo" })
        XCTAssertEqual(app.productType, "com.apple.product-type.application")
        XCTAssertEqual(app.productTypeLabel, "application")
        XCTAssertEqual(app.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(app.deploymentTarget, "16.0")
        XCTAssertEqual(app.sourceFiles, ["Demo/AppDelegate.swift"])
        XCTAssertTrue(app.containsSwift)
        XCTAssertEqual(app.defaultConfiguration, "Debug")

        let framework = try XCTUnwrap(summary.targets.first { $0.name == "DemoKit" })
        XCTAssertEqual(framework.productTypeLabel, "framework")
        XCTAssertEqual(framework.bundleIdentifier, "com.example.demokit")
        XCTAssertEqual(framework.sourceFiles, ["Demo/DemoKit.swift"])
        XCTAssertFalse(framework.isApplication)
    }

    /// The Files picker can return the `.xcodeproj` bundle itself, which is a
    /// directory: inspection must accept it without needing its parent.
    func testXcodeProjectBundleItselfIsInspected() throws {
        let directory = try makeDirectory()
        let bundle = try writeProject(in: directory)

        let inspection = ProjectImportInspector.inspect(bundle)

        guard case .xcodeProject(let summary) = inspection else {
            return XCTFail("expected the bundle itself to be inspected, got \(inspection)")
        }
        XCTAssertEqual(summary.targets.count, 2)
        XCTAssertFalse(inspection.isImportable)
    }

    func testMalformedXcodeProjectIsReportedAsUnreadable() throws {
        let directory = try makeDirectory()
        let bundle = directory.appendingPathComponent("Broken.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "{ this = is not a plist".write(
            to: bundle.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .unreadableXcodeProject(let reason) = inspection else {
            return XCTFail("expected an unreadable Xcode project, got \(inspection)")
        }
        XCTAssertTrue(reason.contains("could not be read"), reason)
        XCTAssertFalse(inspection.isImportable)
    }

    /// Two projects are ambiguous, not broken: the reader names both, and the UI
    /// shows that instead of picking one and describing the wrong app.
    func testTwoXcodeProjectsAreReportedAsUnreadableAndNamed() throws {
        let directory = try makeDirectory()
        try writeProject(in: directory, named: "First")
        try writeProject(in: directory, named: "Second")

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .unreadableXcodeProject(let reason) = inspection else {
            return XCTFail("expected an ambiguous project to be unreadable, got \(inspection)")
        }
        XCTAssertTrue(reason.contains("2 Xcode projects"), reason)
        XCTAssertTrue(reason.contains("First.xcodeproj"), reason)
        XCTAssertTrue(reason.contains("Second.xcodeproj"), reason)
        XCTAssertFalse(inspection.isImportable)
    }

    // MARK: - Neither

    func testEmptyFolderIsNotAProject() throws {
        let directory = try makeDirectory()

        let inspection = ProjectImportInspector.inspect(directory)

        guard case .notAProject(let reason) = inspection else {
            return XCTFail("expected an unsupported folder, got \(inspection)")
        }
        XCTAssertTrue(reason.contains("no Package.swift"), reason)
        XCTAssertFalse(inspection.isImportable)
    }

    /// `productTypeLabel` exists so the UI never has to invent a friendly name:
    /// unknown product types are shown as the project wrote them.
    func testUnknownProductTypeIsShownAsWritten() {
        let target = XcodeTargetSummary(
            id: "Tool",
            name: "Tool",
            productType: "com.example.custom-thing",
            productName: "Tool",
            bundleIdentifier: nil,
            deploymentTarget: nil,
            sourceFiles: [],
            xcconfigPaths: [],
            buildSettings: [:],
            configurationNames: [],
            defaultConfiguration: nil
        )
        XCTAssertEqual(target.productTypeLabel, "com.example.custom-thing")
    }
}
