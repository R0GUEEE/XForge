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

                    // Whether the root carries the toolchain is the root's own
                    // business: the published one has xtool and Swift baked in
                    // (EmbeddedLinux/build-rootfs.sh, XFORGE_PROVISION=all), and a
                    // plain one installs them on demand with
                    // `install-toolchain.sh`. This check reports what the guest
                    // can actually do rather than what it was supposed to arrive
                    // with, and the message names the installer rather than
                    // calling a plain root broken.
                    continuation.yield(.plan("Checking the Alpine toolchain…"))
                    guard try await buildEnvironmentIsReady() else {
                        continuation.yield(.failed(
                            "The Alpine build toolchain is not ready. "
                            + "Run `sh /root/install-toolchain.sh all` in the Terminal tab."
                        ))
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

    /// Verify only; this must never invoke the installer. The executable and apk
    /// checks make a stale or partially restored installation fail clearly.
    ///
    /// Whether the guest has the toolchain XForge builds with: the apk build
    /// dependencies, Swift, and xtool.
    ///
    /// These are what the bundled rootfs *is* expected to carry — the published
    /// root is built with `XFORGE_PROVISION=all` and arrives with them installed
    /// (`EmbeddedLinux/build-rootfs.sh`) — but they are also exactly what the
    /// guest's own installer puts there (`install-toolchain.sh`), so a plain root
    /// that has been provisioned by hand answers yes too, and a false result is
    /// answered with the installer rather than treated as a broken release.
    ///
    /// Every probe here is a separate guest process, and their output goes to a
    /// *file*, never `/dev/null`: this engine kills a forked guest program whose
    /// stdout/stderr is `/dev/null` (found with the engine-smoke harness —
    /// `swift --version >/dev/null 2>&1` died where the unredirected form ran
    /// fine). A probe killed that way reports "not installed" for a toolchain
    /// that is, which is worse than a noisy log line.
    private func buildEnvironmentIsReady() async throws -> Bool {
        let silence = ">/tmp/xforge-probe.log 2>&1"
        let status = try await vm.run(
            "apk info -e clang lld cmake ninja git \(silence) && "
            + "swift --version \(silence) && xtool --version \(silence)",
            environment: nil
        ) { _ in }
        return status == 0
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
