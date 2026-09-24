import Foundation

/// Argument construction for the in-process toolchain.
///
/// Pure functions, on purpose: the compiler itself only exists inside a device
/// build (the LLVM/Swift libraries are linked in by `NativeToolchain.generated.xcconfig`,
/// which is disabled on a plain clone), so a mis-built argument list could only be
/// discovered on a phone with a real SDK. Splitting it out means the unit tests
/// exercise the exact strings the frontend and linker receive, on a simulator,
/// with no compiler present.
enum NativeToolchainInvocation {
    /// `arm64-apple-ios17.0` — the triple every iOS arm64 tool in the stack uses.
    static func targetTriple(minimumIOSVersion: String) -> String {
        "arm64-apple-ios\(minimumIOSVersion)"
    }

    /// `swift-frontend` arguments, exactly as `swift::performFrontend` expects
    /// them.
    ///
    /// The convention is not obvious and is worth stating: the driver's own main
    /// calls `performFrontend(argv[2…], argv[0], …)` for a `swift-frontend -frontend …`
    /// command line, so the array must contain neither the program name nor
    /// `-frontend`. Passing `-frontend` makes `CompilerInvocation::parseArgs`
    /// reject the whole invocation.
    static func swiftFrontendArguments(
        source: URL,
        object: URL,
        plan: NativeBuildPlan,
        sdk: NativeSDKLayout
    ) throws -> [String] {
        guard let swiftResources = sdk.swiftResources else {
            throw NativeToolchainError.io(
                "The Darwin SDK does not declare swiftResourcesPath, so the Swift standard library cannot be found."
            )
        }

        var arguments = [
            // `-parse-as-library` unless the file *is* main.swift: an app's entry
            // point is `@main`, and without this the frontend treats top-level
            // code as the entry point and rejects the attribute.
            "-parse-as-library",
            "-c", source.path,
            "-target", targetTriple(minimumIOSVersion: plan.minimumIOSVersion),
            "-sdk", sdk.sdkRoot.path,
            "-resource-dir", swiftResources.path,
            "-module-name", plan.moduleName,
            "-o", object.path,
        ]
        if source.lastPathComponent == "main.swift" {
            arguments.removeFirst()
        }
        arguments.append(plan.configuration == .release ? "-O" : "-Onone")
        // DebugInfo makes a crash in a built app diagnosable; it costs object size
        // only, and the linker strips what the app does not use.
        arguments.append(contentsOf: ["-g", "-debug-info-format=dwarf"])
        return arguments
    }

    /// `ld64.lld` arguments for an arm64 iOS executable.
    ///
    /// `fileExists` is injected so the Swift runtime libraries are only named when
    /// the SDK bundle actually carries them: naming `-lswift_Concurrency` for a
    /// bundle that predates the split would fail the link with "library not
    /// found", and a Swift 5.7+ runtime has it inside `libswiftCore` anyway.
    static func linkerArguments(
        objects: [URL],
        plan: NativeBuildPlan,
        sdk: NativeSDKLayout,
        executable: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [String] {
        let deploymentTarget = plan.minimumIOSVersion
        var arguments = [
            "-arch", "arm64",
            // lld needs the platform *and* the version pair explicitly; without
            // it the Mach-O records no LC_BUILD_VERSION and iOS refuses to load
            // the binary.
            "-platform_version", "ios", deploymentTarget, deploymentTarget,
            "-syslibroot", sdk.sdkRoot.path,
            "-o", executable.path,
        ]

        for path in plan.librarySearchPaths where fileExists(path) {
            arguments.append(contentsOf: ["-L", path.path])
        }
        for path in plan.frameworkSearchPaths where fileExists(path) {
            arguments.append(contentsOf: ["-F", path.path])
        }

        if plan.hasSwift {
            arguments.append(contentsOf: ["-lswiftCore", "-lswift_Concurrency", "-lswift_StringProcessing"]
                .filter { library in
                    // -lswiftCore is unconditional: a Swift binary cannot run
                    // without it. The other two merged into it over time.
                    library == "-lswiftCore" || swiftLibraryExists(library, sdk: sdk, fileExists: fileExists)
                })
        }

        arguments.append(contentsOf: ["-lSystem"])
        for framework in plan.frameworks {
            arguments.append(contentsOf: ["-framework", framework])
        }
        arguments.append(contentsOf: objects.map(\.path))
        return arguments
    }

    private static func swiftLibraryExists(
        _ flag: String,
        sdk: NativeSDKLayout,
        fileExists: (URL) -> Bool
    ) -> Bool {
        let name = String(flag.dropFirst(2)) // "-lswift_Concurrency" → "swift_Concurrency"
        return sdk.swiftRuntimeLibraryPaths.contains { directory in
            fileExists(directory.appendingPathComponent("lib\(name).a"))
        }
    }
}
