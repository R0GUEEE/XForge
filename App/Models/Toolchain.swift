import Foundation

/// Status of the on-device build infrastructure: the embedded Linux, the Swift
/// toolchain, xtool, and the `darwin` Swift SDK.
struct ToolchainStatus: Codable, Equatable {
    var embeddedLinuxInstalled = false
    var swiftVersion: String?
    var xtoolVersion: String?
    var sdkInstalled = false
    var sdkVersion: String?

    static let placeholder = ToolchainStatus()
}

/// One step of the build pipeline, for the progress UI.
struct BuildStep: Identifiable {
    let id: String
    let title: String
    var state: BuildStepState = .pending
}

enum BuildStepState {
    case pending
    case running
    case succeeded
    case failed

    var symbol: String {
        switch self {
        case .pending: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
