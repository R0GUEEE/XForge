import Foundation

/// The stages of the on-device IPA build pipeline.
enum BuildStage: String, CaseIterable, Identifiable {
    case provision
    case sdk
    case configure
    case resolve
    case compile
    case package
    case artifact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provision: return "Provision embedded Linux"
        case .sdk: return "Install Darwin SDK"
        case .configure: return "Configure app"
        case .resolve: return "Resolve dependencies"
        case .compile: return "Compile (arm64-apple-ios)"
        case .package: return "Package & sign .ipa"
        case .artifact: return "Stage artifact"
        }
    }
}

/// Runtime state of one pipeline stage.
enum BuildStageState: Equatable {
    case pending
    case running
    case succeeded
    case failed
}

/// A per-stage outcome after a build.
struct BuildStageOutcome: Equatable {
    let stage: BuildStage
    let state: BuildStageState
    let duration: TimeInterval
}

/// Everything needed to produce one `.ipa`.
struct BuildRequest {
    var project: Project
    var configuration: BuildConfiguration
    var appInfo: AppInfo
    var identity: SigningIdentity?
}

/// The finished product of a build.
struct BuildResult {
    let ipaURL: URL
    let outcomes: [BuildStageOutcome]
    let buildNumber: Int
}

/// A snapshot of the pipeline for the UI.
struct PipelineSnapshot: Equatable {
    var stages: [BuildStage: BuildStageState] = [:]
    var consoleText: String = ""
    var isRunning = false
    var lastIpa: URL?
    var error: String?

    subscript(_ stage: BuildStage) -> BuildStageState {
        stages[stage] ?? .pending
    }

    var activeStage: BuildStage? {
        stages.first { $0.value == .running }?.key
    }
}
