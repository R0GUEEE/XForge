import XCTest
@testable import XForge

/// The reader exists to answer "what is in this project?" for a build driver, so
/// these tests check the four things a driver needs and the format quirks that
/// would silently corrupt them: comments between values, quoted strings, the group
/// tree that turns a file reference into a project-relative path, and the
/// project→target settings merge.
final class XcodeProjectTests: XCTestCase {

    /// A minimal but real project file: both configuration lists, a sources phase,
    /// a nested group, and settings split between the project and the target — so a
    /// reader that ignores one of the two levels fails the assertions below.
    private static let pbxproj = #"""
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 56;
    	objects = {

    /* Begin PBXBuildFile section */
    		AA01 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA02 /* AppDelegate.swift */; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
    		AA02 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
    		AA03 /* Demo.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Demo.app; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
    		AA04 = {
    			isa = PBXGroup;
    			children = (
    				AA05 /* Demo */,
    				AA06 /* Products */,
    			);
    			sourceTree = "<group>";
    		};
    		AA05 /* Demo */ = {
    			isa = PBXGroup;
    			children = (
    				AA02 /* AppDelegate.swift */,
    			);
    			path = Demo;
    			sourceTree = "<group>";
    		};
    		AA06 /* Products */ = {
    			isa = PBXGroup;
    			children = (
    				AA03 /* Demo.app */,
    			);
    			name = Products;
    			sourceTree = "<group>";
    		};
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
    		AA07 /* Demo */ = {
    			isa = PBXNativeTarget;
    			buildConfigurationList = AA08 /* Build configuration list for PBXNativeTarget "Demo" */;
    			buildPhases = (
    				AA09 /* Sources */,
    			);
    			name = Demo;
    			productName = Demo;
    			productReference = AA03 /* Demo.app */;
    			productType = "com.apple.product-type.application";
    		};
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
    		AA10 /* Project object */ = {
    			isa = PBXProject;
    			buildConfigurationList = AA11 /* Build configuration list for PBXProject "Demo" */;
    			mainGroup = AA04;
    			name = Demo;
    			targets = (
    				AA07 /* Demo */,
    			);
    		};
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
    		AA09 /* Sources */ = {
    			isa = PBXSourcesBuildPhase;
    			buildActionMask = 2147483647;
    			files = (
    				AA01 /* AppDelegate.swift in Sources */,
    			);
    			runOnlyForDeploymentPostprocessing = 0;
    		};
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
    		AA12 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				PRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
    				SWIFT_VERSION = 5.0;
    			};
    			name = Debug;
    		};
    		AA13 /* Release */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				PRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
    				SWIFT_VERSION = 5.0;
    			};
    			name = Release;
    		};
    		AA14 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
    				SDKROOT = iphoneos;
    			};
    			name = Debug;
    		};
    		AA15 /* Release */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
    				SDKROOT = iphoneos;
    			};
    			name = Release;
    		};
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
    		AA08 /* Build configuration list for PBXNativeTarget "Demo" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				AA12 /* Debug */,
    				AA13 /* Release */,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Debug;
    		};
    		AA11 /* Build configuration list for PBXProject "Demo" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				AA14 /* Debug */,
    				AA15 /* Release */,
    			);
    			defaultConfigurationIsVisible = 0;
    			defaultConfigurationName = Debug;
    		};
    /* End XCConfigurationList section */
    	};
    	rootObject = AA10 /* Project object */;
    }
    """#

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-xcodeproj-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.pbxproj.write(
            to: project.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReadsTargetsAndProductType() throws {
        let summary = try XcodeProjectReader.read(at: root)

        XCTAssertEqual(summary.name, "Demo")
        XCTAssertEqual(summary.targets.count, 1)

        let target = try XCTUnwrap(summary.targets.first)
        XCTAssertEqual(target.name, "Demo")
        XCTAssertEqual(target.productType, "com.apple.product-type.application")
        XCTAssertTrue(target.isApplication)
        XCTAssertTrue(target.containsSwift)
        XCTAssertEqual(summary.applicationTargets.map(\.name), ["Demo"])
    }

    /// The path has to come from the group tree (`Demo/AppDelegate.swift`), not from
    /// the build file's own reference, which holds only `AppDelegate.swift`.
    func testResolvesSourcePathsThroughTheGroupTree() throws {
        let summary = try XcodeProjectReader.read(at: root)
        let target = try XCTUnwrap(summary.targets.first)

        XCTAssertEqual(target.sourceFiles, ["Demo/AppDelegate.swift"])
    }

    /// `Debug` carries the bundle identifier, the project's `Debug` carries the
    /// deployment target: a reader that only reads one level loses the other.
    func testMergesProjectAndTargetSettings() throws {
        let summary = try XcodeProjectReader.read(at: root)
        let target = try XCTUnwrap(summary.targets.first)

        XCTAssertEqual(target.defaultConfiguration, "Debug")
        XCTAssertEqual(target.configurationNames, ["Debug", "Release"])
        XCTAssertEqual(target.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(target.deploymentTarget, "17.0")
        XCTAssertEqual(target.buildSettings["SDKROOT"], "iphoneos")
        XCTAssertEqual(target.buildSettings["SWIFT_VERSION"], "5.0")
    }

    func testAcceptsTheProjectBundleItself() throws {
        let summary = try XcodeProjectReader.read(
            at: root.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        )
        XCTAssertEqual(summary.targets.count, 1)
    }

    func testReportsAMalformedProject() throws {
        let url = root.appendingPathComponent("Broken.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{ this = is not a plist".write(
            to: url.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try XcodeProjectReader.read(at: root.appendingPathComponent("Broken.xcodeproj")))
    }

    func testReportsAMissingProject() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try XcodeProjectReader.read(at: empty))
    }
}
