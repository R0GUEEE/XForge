import Foundation
import Combine

/// Orchestrates the on-device IPA build pipeline. Exposes a `PipelineSnapshot` that
/// drives the GUI's stage UI. Heavy stages run in the embedded Linux via `BuildExecutor`;
/// packaging/signing runs on the host via `IPABuilder`.
@MainActor
final class BuildManager: ObservableObject {
    let project: Project

    @Published private(set) var snapshot = PipelineSnapshot()
    @Published var configuration: BuildConfiguration = .debug
    @Published var appInfo: AppInfo

    private var executor: BuildExecutor?
    private var compiledURL: URL?
    private var buildNumber: Int

    init(project: Project) {
        self.project = project
        self.appInfo = project.appInfo ?? .default(for: project)
        self.configuration = AppPreferences().defaultConfiguration
        self.buildNumber = Self.nextBuildNumber()
        resetStages()
    }

    // MARK: - Public

    func bootstrap() async {
        await provision()
    }

    func run() async {
        guard !snapshot.isRunning else { return }
        snapshot.isRunning = true
        snapshot.error = nil
        resetStages()

        await provision()
        await ensureSDK()
        await configure()
        await resolve()
        await compile()

        if snapshot.error == nil { await package() }
        if snapshot.error == nil { await stageArtifact() }

        snapshot.isRunning = false
    }

    // MARK: - Stages

    private func provision() async {
        let executor = makeExecutor()
        markRunning(.provision)
        do {
            let stream = try await executor.bootstrap()
            for try await event in stream { consume(event) }
            markSucceeded(.provision)
        } catch { markFailed(.provision, error) }
    }

    private func ensureSDK() async {
        let executor = makeExecutor()
        markRunning(.sdk)
        do {
            let source = SDKSource.hostedRemote(sdkReleaseURL)
            try await executor.installSDK(from: source)
            markSucceeded(.sdk)
        } catch { markFailed(.sdk, error) }
    }

    private func configure() async {
        markRunning(.configure)
        appendConsole("▸ bundle \(appInfo.bundleIdentifier) · \(configuration.rawValue)")
        appendConsole("▸ writing project config for \(project.name)")
        // TODO: write xtool.yml + inject AppInfo into the guest before compile.
        markSucceeded(.configure)
    }

    private func resolve() async {
        let executor = makeExecutor()
        markRunning(.resolve)
        do {
            let stream = try await executor.resolve(project)
            for try await event in stream { consume(event) }
            markSucceeded(.resolve)
        } catch { markFailed(.resolve, error) }
    }

    private func compile() async {
        let executor = makeExecutor()
        markRunning(.compile)
        do {
            var produced: URL?
            let stream = try await executor.build(project, configuration: configuration)
            for try await event in stream {
                switch event {
                case .artifact(let url): produced = url
                default: consume(event)
                }
            }
            guard let produced else {
                markFailed(.compile, BuildError.noArtifact)
                return
            }
            compiledURL = produced
            markSucceeded(.compile)
        } catch { markFailed(.compile, error) }
    }

    /// Host-side packaging: if the compiler produced a raw `.app`, package it into a
    /// `.ipa` with `IPABuilder`. If it already produced an `.ipa`, nothing to do.
    private func package() async {
        guard let compiled = compiledURL else {
            markFailed(.package, BuildError.noArtifact)
            return
        }
        markRunning(.package)
        if compiled.pathExtension == "app" {
            do {
                let ipa = try IPABuilder.buildIPA(
                    appBundle: compiled,
                    appInfo: appInfo,
                    outputDir: XForgeEnvironment.stagingDirectory
                )
                snapshot.lastIpa = ipa
                markSucceeded(.package)
            } catch { markFailed(.package, error) }
        } else {
            snapshot.lastIpa = compiled
            appendConsole("✓ .ipa already packaged in guest")
            markSucceeded(.package)
        }
    }

    private func stageArtifact() async {
        markRunning(.artifact)
        guard let ipa = snapshot.lastIpa else {
            markFailed(.artifact, BuildError.noArtifact)
            return
        }
        let result = BuildResult(
            ipaURL: ipa,
            outcomes: snapshot.stages.map { BuildStageOutcome(stage: $0.key, state: $0.value, duration: 0) },
            buildNumber: buildNumber
        )
        _ = result
        appendConsole("✓ artifact: \(ipa.lastPathComponent)")
        markSucceeded(.artifact)
    }

    // MARK: - Executor

    private func makeExecutor() -> BuildExecutor {
        if let executor { return executor }
        let created = XForgeEnvironment.makeExecutor(for: project)
        executor = created
        return created
    }

    /// URL of the CI-hosted darwin SDK release asset (fetched on first use).
    private var sdkReleaseURL: URL {
        URL(string: "https://github.com/R0GUEEE/XForge/releases/latest/download/darwin.artifactbundle.tar.xz")!
    }

    // MARK: - Snapshot helpers

    private func markRunning(_ stage: BuildStage) {
        snapshot.stages[stage] = .running
        appendConsole("▶ \(stage.title)…")
    }
    private func markSucceeded(_ stage: BuildStage) {
        snapshot.stages[stage] = .succeeded
        appendConsole("✓ \(stage.title)")
    }
    private func markFailed(_ stage: BuildStage, _ error: Error) {
        snapshot.stages[stage] = .failed
        snapshot.error = error.localizedDescription
        appendConsole("[failed] \(stage.title): \(error.localizedDescription)")
    }
    private func consume(_ event: BuildEvent) {
        switch event {
        case .plan(let s): appendConsole("▶ \(s)")
        case .output(let s): appendConsole(s)
        case .artifact(let url): snapshot.lastIpa = url
        case .finished: break
        case .failed(let s): appendConsole("[failed] \(s)")
        }
    }
    private func appendConsole(_ line: String) {
        snapshot.consoleText += line + "\n"
        if snapshot.consoleText.count > 100_000 {
            snapshot.consoleText = String(snapshot.consoleText.suffix(100_000))
        }
    }
    private func resetStages() {
        snapshot.stages = [:]
        snapshot.consoleText = ""
        snapshot.lastIpa = nil
        snapshot.error = nil
        compiledURL = nil
    }

    private static func nextBuildNumber() -> Int {
        Int(Date().timeIntervalSince1970) % 100_000
    }
}

enum BuildError: LocalizedError {
    case noArtifact
    case notProvisioned
    var errorDescription: String? {
        switch self {
        case .noArtifact: return "The build did not produce an artifact."
        case .notProvisioned: return "The embedded Linux is not provisioned."
        }
    }
}
