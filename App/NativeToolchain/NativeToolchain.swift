import Foundation

struct NativeToolchainResult: Sendable {
    let exitCode: Int32
    let diagnostics: String

    var succeeded: Bool { exitCode == 0 }
}

enum NativeToolchainError: LocalizedError {
    case unavailable
    case io(String)
    case compile(String)
    case link(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native LLVM/Clang/LLD backend is not linked into this XForge build."
        case .io(let message):
            return message
        case .compile(let message):
            return "Native compilation failed: \(message)"
        case .link(let message):
            return "Native linking failed: \(message)"
        }
    }
}

/// Thin Swift wrapper around the in-process C++ compiler/linker bridge.
///
/// There are deliberately no Process/posix_spawn calls here. Once LLVM is linked,
/// compilation and Mach-O linking happen in XForge's own process on the iPhone.
enum NativeToolchain {
    static var isAvailable: Bool { xf_native_toolchain_available() }

    static var version: String {
        String(cString: xf_native_toolchain_version())
    }

    static func compileC(
        source: URL,
        object: URL,
        sdk: URL,
        target: String = "arm64-apple-ios16.0.0",
        language: String = "c"
    ) throws -> NativeToolchainResult {
        guard isAvailable else { throw NativeToolchainError.unavailable }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NativeToolchainError.io("Source file does not exist: \(source.path)")
        }
        guard FileManager.default.fileExists(atPath: sdk.path) else {
            throw NativeToolchainError.io("iPhoneOS SDK does not exist: \(sdk.path)")
        }

        var diagnostics = [CChar](repeating: 0, count: 64 * 1024)
        let code: Int32 = source.path.withCString { sourcePath in
            object.path.withCString { objectPath in
                sdk.path.withCString { sdkPath in
                    target.withCString { targetTriple in
                        language.withCString { lang in
                            Int32(xf_native_clang_compile(
                                sourcePath,
                                objectPath,
                                sdkPath,
                                targetTriple,
                                lang,
                                &diagnostics,
                                diagnostics.count
                            ))
                        }
                    }
                }
            }
        }
        return NativeToolchainResult(
            exitCode: code,
            diagnostics: String(cString: diagnostics)
        )
    }

    static func linkMachO(arguments: [String]) throws -> NativeToolchainResult {
        guard isAvailable else { throw NativeToolchainError.unavailable }
        guard !arguments.isEmpty else {
            throw NativeToolchainError.link("No LLD arguments were supplied.")
        }

        let duplicated: [UnsafeMutablePointer<CChar>] = arguments.compactMap { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        guard duplicated.count == arguments.count else {
            throw NativeToolchainError.io("Could not allocate linker arguments.")
        }

        let argv: [UnsafePointer<CChar>?] = duplicated.map { UnsafePointer($0) }
        var diagnostics = [CChar](repeating: 0, count: 64 * 1024)
        let code = argv.withUnsafeBufferPointer { buffer -> Int32 in
            Int32(xf_native_lld_link(
                Int32(arguments.count),
                buffer.baseAddress,
                &diagnostics,
                diagnostics.count
            ))
        }
        return NativeToolchainResult(
            exitCode: code,
            diagnostics: String(cString: diagnostics)
        )
    }

    /// End-to-end smoke test used before wiring the native backend into normal projects.
    /// Produces an arm64 iOS object file entirely in-process.
    static func smokeCompile(sdk: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-native-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let source = dir.appendingPathComponent("main.c")
        let object = dir.appendingPathComponent("main.o")
        try "int xforge_native_smoke(void) { return 42; }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        let result = try compileC(source: source, object: object, sdk: sdk)
        guard result.succeeded else {
            throw NativeToolchainError.compile(result.diagnostics)
        }
        guard FileManager.default.fileExists(atPath: object.path) else {
            throw NativeToolchainError.compile("Clang returned success but produced no object file.")
        }
        return object
    }
}
