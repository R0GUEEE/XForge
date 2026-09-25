import Foundation

/// What this build of XForge can actually compile with.
///
/// The toolchain is linked in at *link* time through
/// `Support/NativeToolchain.generated.xcconfig`, so a plain clone — and every CI
/// build — has no compiler at all, while a build that installed the toolchain
/// bundle has some or all of it (Clang and LLD for a long time, the Swift
/// frontend only once its libraries exist for iOS). Reporting that honestly is
/// the difference between "this project needs a toolchain" and a build that fails
/// somewhere in the middle with a linker error.
struct NativeToolchainCapabilities: Sendable, Equatable {
    let hasClang: Bool
    let hasLLDMachO: Bool
    let hasSwiftFrontend: Bool
    let backendDescription: String
    let sdkInstalled: Bool

    static var current: NativeToolchainCapabilities {
        NativeToolchainCapabilities(
            hasClang: NativeToolchain.isAvailable,
            hasLLDMachO: NativeToolchain.isAvailable,
            hasSwiftFrontend: NativeToolchain.isSwiftAvailable,
            backendDescription: NativeToolchain.isAvailable
                ? NativeToolchain.version
                : "not linked",
            sdkInstalled: NativeSDK.isInstalled
        )
    }

    /// Whether anything can be compiled at all. The Swift frontend is deliberately
    /// not required: a C/Objective-C target links fine without it, and refusing to
    /// start would be wrong about why the build fails.
    var canCompile: Bool { hasClang && hasLLDMachO }

    var unavailableReason: String? {
        guard !canCompile else { return nil }
        return """
        The native compiler is not linked into this build of XForge, so it cannot \
        compile anything. Install the toolchain bundle (NativeToolchain/install-bundle.sh) \
        and rebuild, or use a release that ships it.
        """
    }

    /// Lines for the build console: one per component, present or missing.
    var report: [String] {
        [
            "clang: \(hasClang ? "linked" : "missing")",
            "ld64.lld: \(hasLLDMachO ? "linked" : "missing")",
            "swift-frontend: \(hasSwiftFrontend ? "linked" : "missing")",
            "darwin SDK: \(sdkInstalled ? "installed" : "missing")",
            "backend: \(backendDescription)",
        ]
    }
}
