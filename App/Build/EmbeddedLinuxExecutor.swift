import Foundation

/// Thread-safe accumulator for output delivered from the VM's `@Sendable` callback.
private final class ExecOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

/// BuildExecutor backed by the embedded Linux VM.
///
/// Commands run in the shared Alpine guest through its interactive login terminal.
/// Every guest command's exit status is checked — a build that did not run must
/// never report success.
@MainActor
final class EmbeddedLinuxExecutor: BuildExecutor {
    let vm: LinuxVM
    private let stagingDir: URL
    private(set) var stagedOutputs: [URL] = []

    init(vm: LinuxVM, stagingDir: URL) {
        self.vm = vm
        self.stagingDir = stagingDir
    }

    func bootstrap() -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.plan("Booting embedded Alpine Linux…"))
                    await vm.prepareRootfs()
                    try await vm.boot()

                    // A bundled minirootfs deliberately contains only Alpine itself.
                    // Before every build, the guest verifies its required packages and
                    // toolchain. The script is idempotent, so an already-ready rootfs
                    // only performs inexpensive checks.
                    try await provisionGuestForBuild(continuation: continuation)

                    continuation.yield(.plan("Verifying Swift toolchain…"))
                    let swift = try await vm.run("swift --version", environment: nil) {
                        continuation.yield(.output($0))
                    }
                    guard swift == 0 else {
                        continuation.yield(.failed("The Swift toolchain could not run in the embedded Linux."))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.plan("Verifying xtool…"))
                    let xtool = try await vm.run("xtool --version", environment: nil) {
                        continuation.yield(.output($0))
                    }
                    guard xtool == 0 else {
                        continuation.yield(.failed("xtool could not run in the embedded Linux."))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func installSDK(from source: SDKSource) async throws {
        switch source {
        case .bundled(let path):
            // Already inside the guest filesystem.
            let status = try await vm.run(
                "swift sdk install \(GuestShell.quote(path))",
                environment: nil
            ) { _ in }
            guard status == 0 else { throw BuildError.stepFailed("swift sdk install", status) }
        case .hostedRemote(let url):
            // Alpine downloads, extracts, and installs the published SDK directly
            // into its rootfs. The iOS host only provides the resolved asset URL.
            try await SDKInstaller.install(vm: vm, remoteURL: url) { _, _ in }
        }
    }

    /// Stages the app-owned provisioning script inside Alpine and executes every
    /// required step there. The script itself checks installed packages before
    /// calling apk, so this is safe to run at the start of each build.
    private func provisionGuestForBuild(
        continuation: AsyncThrowingStream<BuildEvent, Error>.Continuation
    ) async throws {
        guard let script = Bundle.main.url(forResource: "install-toolchain", withExtension: "sh") else {
            throw ToolchainError.scriptMissing
        }

        let guestPath = "/root/install-toolchain.sh"
        try await vm.copyIn(hostURL: script, to: guestPath)

        for step in ToolchainManager.ProvisionStep.allCases {
            continuation.yield(.plan("Alpine: \(step.title)…"))
            let status = try await vm.run(
                "sh \(GuestShell.quote(guestPath)) \(GuestShell.quote(step.rawValue))",
                environment: nil
            ) {
                continuation.yield(.output($0))
            }
            guard status == 0 else {
                throw BuildError.stepFailed("Alpine \(step.title)", status)
            }
        }
    }

    func createProject(named name: String, organizationIdentifier: String) async throws -> Project {
        if !vm.isBooted { try await vm.boot() }
        let validatedName = try Project.validatedName(name)
        let path = Project.path(forValidatedName: validatedName)
        let status = try await vm.run(
            "mkdir -p \(GuestShell.quote(path)) && cd \(GuestShell.quote(path)) "
            + "&& XTOOL_ORG=\(GuestShell.quote(organizationIdentifier)) "
            + "xtool new --name \(GuestShell.quote(validatedName))",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw BuildError.stepFailed("xtool new", status) }
        return Project(name: validatedName, organizationIdentifier: organizationIdentifier, rootPath: path)
    }

    func resolve(_ project: Project) -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if !vm.isBooted { try await vm.boot() }
                    continuation.yield(.plan("Resolving dependencies for \(project.name)…"))
                    guard project.hasSafeRootPath else {
                        throw ProjectValidationError.unsafePath
                    }
                    let status = try await vm.run(
                        "cd \(GuestShell.quote(project.rootPath)) && swift package resolve",
                        environment: nil
                    ) { line in
                        continuation.yield(.output(line))
                    }
                    if status != 0 {
                        continuation.yield(.failed("Dependency resolution failed (exit \(status))."))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func build(_ project: Project, configuration: BuildConfiguration) -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if !vm.isBooted { try await vm.boot() }

                    var flags = "-s -i"   // sign + output .ipa
                    if configuration == .release { flags = "-c release -s -i" }

                    continuation.yield(.plan("Building \(project.name) (\(configuration.rawValue))…"))
                    guard project.hasSafeRootPath else {
                        throw ProjectValidationError.unsafePath
                    }
                    let code = try await vm.run(
                        "cd \(GuestShell.quote(project.rootPath)) && xtool dev build \(flags)",
                        environment: nil
                    ) { line in
                        continuation.yield(.output(line))
                    }

                    // Report the build's own failure before trying to collect an
                    // artifact, otherwise the user sees a misleading copy error.
                    guard code == 0 else {
                        continuation.yield(.failed("Build failed (exit \(code))."))
                        continuation.finish()
                        return
                    }

                    guard let guestIPA = try await newestIPA(in: project) else {
                        continuation.yield(.failed("The build finished but produced no .ipa in .build."))
                        continuation.finish()
                        return
                    }

                    let hostURL = stagingDir.appendingPathComponent((guestIPA as NSString).lastPathComponent)
                    try await vm.copyOut(guestPath: guestIPA, to: hostURL)

                    stagedOutputs = [hostURL]
                    continuation.yield(.artifact(hostURL))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Newest `*.ipa` under the project's `.build`, rather than assuming a name
    /// (xtool's output filename is not guaranteed).
    private func newestIPA(in project: Project) async throws -> String? {
        let box = ExecOutputBox()
        let status = try await vm.run(
            "find \(GuestShell.quote("\(project.rootPath)/.build")) -maxdepth 1 -type f "
            + "-name '*.ipa' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1",
            environment: nil
        ) { box.append($0) }
        guard status == 0 else { return nil }
        let path = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
