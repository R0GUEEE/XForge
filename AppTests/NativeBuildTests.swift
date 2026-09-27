import XCTest
@testable import XForge

/// Tests for the native build path's pure half: reading a project into a plan and
/// turning that plan into compiler/linker argument lists.
///
/// This is the only part of the native pipeline a simulator can exercise — the
/// compiler itself is linked into device builds only — and it is deliberately the
/// largest part, because a wrong argument is invisible until a build runs on a
/// phone with a real SDK.
final class NativeBuildTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-native-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func sdkFixture() -> NativeSDKLayout {
        let bundle = root.appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        return NativeSDKLayout(
            bundle: bundle,
            sdkRoot: bundle.appendingPathComponent("iPhoneOS.sdk", isDirectory: true),
            swiftResources: bundle.appendingPathComponent("usr/lib/swift", isDirectory: true),
            swiftStaticResources: bundle.appendingPathComponent("usr/lib/swift_static", isDirectory: true),
            platformLibrarySearchPaths: [bundle.appendingPathComponent("usr/lib", isDirectory: true)]
        )
    }

    private func appInfo() -> AppInfo {
        AppInfo(
            bundleIdentifier: "com.example.Demo",
            displayName: "Demo",
            version: "2.1",
            buildNumber: "7",
            minimumOSVersion: "17.0"
        )
    }

    /// A package laid out the way `xtool new` and `XForge` both produce one.
    @discardableResult
    private func writePackage(
        name: String = "Demo",
        packageSwift: String? = nil,
        files: [String] = ["Demo.swift"]
    ) throws -> URL {
        let project = root.appendingPathComponent(name, isDirectory: true)
        let sources = project.appendingPathComponent("Sources/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let manifest = packageSwift ?? """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            products: [.executable(name: "\(name)", targets: ["\(name)"])],
            targets: [.executableTarget(name: "\(name)", path: "Sources/\(name)")]
        )
        """
        try manifest.write(
            to: project.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        for file in files {
            try "// \(file)\n".write(
                to: sources.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }
        return project
    }

    // MARK: - Plan factory

    func testPlanFindsSourcesAndModule() throws {
        let project = try writePackage(files: ["Demo.swift", "README.md", "helper.c"])

        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdkFixture()
        )

        XCTAssertEqual(plan.moduleName, "Demo")
        XCTAssertEqual(plan.executableName, "Demo")
        XCTAssertEqual(plan.appName, "Demo")
        XCTAssertEqual(plan.swiftSources.count, 1)
        XCTAssertEqual(plan.clangSources.map(\.url.lastPathComponent), ["helper.c"])
        XCTAssertEqual(plan.clangSources.first?.language, "c")
        // A Swift app links UIKit; a C-only one does not, which is why the plan
        // decides this rather than the executor.
        XCTAssertTrue(plan.frameworks.contains("UIKit"))
        XCTAssertTrue(plan.frameworks.contains("Foundation"))
        XCTAssertTrue(plan.hasSwift)
    }

    func testPlanRejectsPackageWithoutSourcesDirectory() throws {
        let project = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n"
            .write(to: project.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdkFixture()
        )) { error in
            guard case NativeBuildPlanError.missingTargetsDirectory = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPlanRejectsMissingManifest() throws {
        XCTAssertThrowsError(try NativeBuildPlanFactory.makePlan(
            root: root,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdkFixture()
        )) { error in
            guard case NativeBuildPlanError.missingPackageManifest = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// The load-bearing refusal: a package manager cannot run inside an app that
    /// may not spawn processes, so a project with dependencies fails by name.
    func testPlanRefusesSwiftPackageDependencies() throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Demo",
            dependencies: [
                .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0")
            ],
            targets: [.executableTarget(name: "Demo", path: "Sources/Demo")]
        )
        """
        let project = try writePackage(packageSwift: manifest)

        XCTAssertThrowsError(try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdkFixture()
        )) { error in
            guard case NativeBuildPlanError.unsupportedSwiftPackageDependencies(let names) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(names, ["swift-argument-parser"])
            XCTAssertTrue(error.localizedDescription.contains("swift-argument-parser"))
        }
    }

    func testDependencyScanIgnoresLocalTargets() throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Demo",
            targets: [.executableTarget(name: "Demo", path: "Sources/Demo")]
        )
        """
        let url = root.appendingPathComponent("Package.swift")
        try manifest.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try NativeBuildPlanFactory.swiftPackageDependencies(manifestURL: url), [])
    }

    func testClangLanguageMapping() {
        XCTAssertEqual(NativeClangSource.language(for: URL(fileURLWithPath: "/a/b.c")), "c")
        XCTAssertEqual(NativeClangSource.language(for: URL(fileURLWithPath: "/a/b.m")), "objective-c")
        XCTAssertEqual(NativeClangSource.language(for: URL(fileURLWithPath: "/a/b.mm")), "objective-c++")
        XCTAssertEqual(NativeClangSource.language(for: URL(fileURLWithPath: "/a/b.cpp")), "c++")
        XCTAssertNil(NativeClangSource.language(for: URL(fileURLWithPath: "/a/b.swift")))
    }

    // MARK: - swift-frontend arguments

    func testSwiftFrontendArgumentsMatchTheEmbeddedFrontendContract() throws {
        let project = try writePackage()
        let sdk = sdkFixture()
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdk
        )
        let source = try XCTUnwrap(plan.swiftSources.first)
        let object = root.appendingPathComponent("Demo.o")

        let arguments = try NativeToolchainInvocation.swiftFrontendArguments(
            source: source,
            object: object,
            plan: plan,
            sdk: sdk
        )

        let target = "arm64-apple-ios\(plan.minimumIOSVersion)"
        XCTAssertEqual(NativeToolchainInvocation.targetTriple(minimumIOSVersion: "17.0"),
                       "arm64-apple-ios17.0")
        XCTAssertTrue(arguments.contains(target))
        XCTAssertTrue(arguments.contains("-sdk"))
        XCTAssertTrue(arguments.contains(sdk.sdkRoot.path))
        XCTAssertTrue(arguments.contains("-resource-dir"))
        XCTAssertTrue(arguments.contains("-module-name"))
        XCTAssertTrue(arguments.contains(plan.moduleName))
        XCTAssertTrue(arguments.contains("-o"))
        XCTAssertTrue(arguments.contains(object.path))
        // -parse-as-library for a file that is not main.swift, and never the
        // driver's own `-frontend`: performFrontend receives argv[2…] and would
        // reject it.
        XCTAssertEqual(arguments.first, "-parse-as-library")
        XCTAssertFalse(arguments.contains("-frontend"))
        XCTAssertTrue(arguments.contains("-Onone"))
    }

    func testMainSwiftDoesNotGetParseAsLibrary() throws {
        let project = try writePackage(files: ["main.swift"])
        let sdk = sdkFixture()
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .release,
            sdk: sdk
        )
        let source = try XCTUnwrap(plan.swiftSources.first)

        let arguments = try NativeToolchainInvocation.swiftFrontendArguments(
            source: source,
            object: root.appendingPathComponent("main.o"),
            plan: plan,
            sdk: sdk
        )

        XCTAssertFalse(arguments.contains("-parse-as-library"))
        XCTAssertTrue(arguments.contains("-O"))
        XCTAssertFalse(arguments.contains("-Onone"))
    }

    func testSwiftFrontendArgumentsRequireSwiftResourceDirectory() throws {
        let project = try writePackage()
        var sdk = sdkFixture()
        sdk = NativeSDKLayout(
            bundle: sdk.bundle,
            sdkRoot: sdk.sdkRoot,
            swiftResources: nil,
            swiftStaticResources: sdk.swiftStaticResources,
            platformLibrarySearchPaths: sdk.platformLibrarySearchPaths
        )
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdk
        )

        XCTAssertThrowsError(try NativeToolchainInvocation.swiftFrontendArguments(
            source: try XCTUnwrap(plan.swiftSources.first),
            object: root.appendingPathComponent("Demo.o"),
            plan: plan,
            sdk: sdk
        ))
    }

    // MARK: - Linker arguments

    func testLinkerArgumentsDescribeAnIOSExecutable() throws {
        let project = try writePackage()
        let sdk = sdkFixture()
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdk
        )
        let object = root.appendingPathComponent("Demo.o")
        let executable = root.appendingPathComponent("Demo")

        let arguments = NativeToolchainInvocation.linkerArguments(
            objects: [object],
            plan: plan,
            sdk: sdk,
            executable: executable,
            fileExists: { _ in true }
        )

        XCTAssertEqual(arguments[0], "-arch")
        XCTAssertEqual(arguments[1], "arm64")
        XCTAssertTrue(arguments.contains("-platform_version"))
        let platformIndex = try XCTUnwrap(arguments.firstIndex(of: "-platform_version"))
        XCTAssertEqual(arguments[platformIndex + 1], "ios")
        XCTAssertEqual(arguments[platformIndex + 2], plan.minimumIOSVersion)
        XCTAssertTrue(arguments.contains("-syslibroot"))
        XCTAssertTrue(arguments.contains(sdk.sdkRoot.path))
        XCTAssertTrue(arguments.contains("-lswiftCore"))
        XCTAssertTrue(arguments.contains("-lSystem"))
        XCTAssertTrue(arguments.contains("-framework"))
        XCTAssertTrue(arguments.contains(object.path))
        XCTAssertTrue(arguments.contains(executable.path))
        XCTAssertEqual(arguments[arguments.count - 1], object.path)
    }

    func testLinkerSkipsSearchPathsThatDoNotExist() throws {
        let project = try writePackage()
        let sdk = sdkFixture()
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdk
        )

        let arguments = NativeToolchainInvocation.linkerArguments(
            objects: [root.appendingPathComponent("Demo.o")],
            plan: plan,
            sdk: sdk,
            executable: root.appendingPathComponent("Demo"),
            fileExists: { _ in false }
        )

        // -lswiftCore stays (a Swift binary cannot run without it) but nothing
        // that names a file that is not there.
        XCTAssertTrue(arguments.contains("-lswiftCore"))
        XCTAssertFalse(arguments.contains("-L"))
        XCTAssertFalse(arguments.contains("-lswift_Concurrency"))
    }

    func testCLanguageLibraryPathsComeFromThePlan() throws {
        let project = try writePackage(files: ["main.c"])
        var sdk = sdkFixture()
        sdk = NativeSDKLayout(
            bundle: sdk.bundle,
            sdkRoot: sdk.sdkRoot,
            swiftResources: sdk.swiftResources,
            swiftStaticResources: sdk.swiftStaticResources,
            platformLibrarySearchPaths: sdk.platformLibrarySearchPaths
        )
        let plan = try NativeBuildPlanFactory.makePlan(
            root: project,
            appInfo: appInfo(),
            configuration: .debug,
            sdk: sdk
        )

        XCTAssertFalse(plan.hasSwift)
        XCTAssertFalse(plan.frameworks.contains("UIKit"))
        XCTAssertTrue(plan.librarySearchPaths.isEmpty)
    }
}
