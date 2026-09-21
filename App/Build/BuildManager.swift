import Foundation
import Combine

/// Orchestrates the on-device IPA build pipeline. Exposes a `PipelineSnapshot` that
/// drives the GUI's stage UI. Toolchain checks, dependency resolution, compilation,
/// packaging, and SDK tooling all run inside Alpine via `BuildExecutor`.
@MainActor
final class BuildManager: ObservableObject {
    let project: Project

    @Published private(set) var snapshot = PipelineSnapshot()
    @Published var configuration: BuildConfiguration = .debug
    @Published var appInfo: AppInfo

    private var executor: BuildExecutor?
    private var compiledURL: URL?
    private var buildNumber: Int
    private let history = BuildHistoryStore()

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
        buildNumber = Self.nextBuildNumber()
        appInfo.buildNumber = String(buildNumber)
        resetStages()

        // Stop at the first failed stage: later stages fail as a consequence and
        // their messages would bury the real cause.
        await provision()
        if snapshot.error == nil { await ensureSDK() }
        if snapshot.error == nil { await configure() }
        if snapshot.error == nil { await resolve() }
        if snapshot.error == nil { await compile() }
        if snapshot.error == nil { await package() }
        if snapshot.error == nil { await stageArtifact() }

        snapshot.isRunning = false
        history.record(
            projectName: project.name,
            configuration: configuration.rawValue,
            buildNumber: buildNumber,
            result: snapshot.error == nil ? "success" : "failed",
            artifactName: snapshot.lastIpa?.lastPathComponent,
            error: snapshot.error
        )
    }

    // MARK: - Stages

    private func provision() async {
        let executor = makeExecutor()
        markRunning(.provision)
        do {
            let stream = try await executor.bootstrap()
            for try await event in stream { consume(event) }
            guard snapshot.error == nil else {
                snapshot.stages[.provision] = .failed
                return
            }
            markSucceeded(.provision)
        } catch { markFailed(.provision, error) }
    }

    private func ensureSDK() async {
        let executor = makeExecutor()
        markRunning(.sdk)
        do {
            // Resolve the published asset first: the darwin SDK lives under its own
            // `darwin-sdk-*` release series, so `releases/latest/download/…` 404s.
            let url = try await XForgeReleases.darwinSDKURL()
            appendConsole("▸ darwin SDK: \(url.lastPathComponent)")
            try await executor.installSDK(from: .hostedRemote(url))
            markSucceeded(.sdk)
        } catch { markFailed(.sdk, error) }
    }

    /// Make sure the project exists in the guest and record the app identity the
    /// build should produce. Previously this stage only printed a line and
    /// reported success unconditionally, even after provision had failed.
    private func configure() async {
        markRunning(.configure)
        do {
            let vm = XForgeEnvironment.makeVM()
            if !vm.isBooted { try await vm.boot() }

            guard project.hasSafeRootPath else {
                throw ProjectValidationError.unsafePath
            }
            let dir = project.rootPath
            let mkdir = try await vm.run(
                "mkdir -p \(GuestShell.quote(dir))",
                environment: nil
            ) { _ in }
            guard mkdir == 0 else { throw BuildError.stepFailed("mkdir \(dir)", mkdir) }

            let metadata = BuildMetadata(
                bundleIdentifier: appInfo.bundleIdentifier,
                displayName: appInfo.displayName,
                version: appInfo.version,
                buildNumber: appInfo.buildNumber,
                minimumOSVersion: appInfo.minimumOSVersion,
                configuration: configuration.rawValue
            )
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("xforge-app-\(UUID().uuidString).json")
            try JSONEncoder().encode(metadata).write(to: temp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temp) }
            try await vm.copyIn(hostURL: temp, to: "\(dir)/xforge-app.json")

            appendConsole("▸ bundle \(appInfo.bundleIdentifier) · \(configuration.rawValue)")
            appendConsole("▸ wrote app identity to \(dir)/xforge-app.json")
            markSucceeded(.configure)
        } catch {
            markFailed(.configure, error)
        }
    }

    private func resolve() async {
        let executor = makeExecutor()
        markRunning(.resolve)
        do {
            let stream = try await executor.resolve(project)
            for try await event in stream { consume(event) }
            guard snapshot.error == nil else {
                snapshot.stages[.resolve] = .failed
                return
            }
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
            guard snapshot.error == nil else {
                snapshot.stages[.compile] = .failed
                return
            }
            guard let produced else {
                markFailed(.compile, BuildError.noArtifact)
                return
            }
            compiledURL = produced
            markSucceeded(.compile)
        } catch { markFailed(.compile, error) }
    }

    /// Packaging belongs to xtool inside Alpine. The host receives only the final
    /// IPA for export; it never runs build or SDK tooling.
    private func package() async {
        guard let compiled = compiledURL,
              compiled.pathExtension.lowercased() == "ipa" else {
            markFailed(.package, BuildError.noArtifact)
            return
        }
        markRunning(.package)
        snapshot.lastIpa = compiled
        appendConsole("✓ .ipa packaged by xtool inside Alpine")
        markSucceeded(.package)
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
        // Keep the FIRST failure — it is the root cause; everything after it
        // fails as a consequence and would only obscure what actually went wrong.
        if snapshot.error == nil { snapshot.error = error.localizedDescription }
        appendConsole("[failed] \(stage.title): \(error.localizedDescription)")
    }
    private func consume(_ event: BuildEvent) {
        switch event {
        case .plan(let s): appendConsole("▶ \(s)")
        case .output(let s): appendConsole(s)
        case .artifact(let url): snapshot.lastIpa = url
        case .finished: break
        case .failed(let s):
            if snapshot.error == nil { snapshot.error = s }
            appendConsole("[failed] \(s)")
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

private struct BuildMetadata: Encodable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let buildNumber: String
    let minimumOSVersion: String
    let configuration: String
}

enum BuildError: LocalizedError {
    case noArtifact
    case notProvisioned
    case stepFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .noArtifact:
            return "The build did not produce an artifact."
        case .notProvisioned:
            return "The embedded Linux is not provisioned."
        case .stepFailed(let step, let status):
            return "\(step) failed inside the embedded Linux (exit \(status))."
        }
    }
}
