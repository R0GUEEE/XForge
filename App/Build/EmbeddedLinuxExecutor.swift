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
/// Only the genuinely heavy operations cross into the VM (toolchain bootstrap,
/// SDK install, and `swift package resolve` / `xtool dev build`). Everything else
/// is native. Every guest command's exit status is checked — a build that did not
/// run must never report success.
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
                    if !vm.isBooted {
                        continuation.yield(.plan("Booting embedded Linux…"))
                        try await vm.boot()
                    }
                    // Probe with commands whose exit status is meaningful. A
                    // trailing `|| echo …` would make any probe "succeed".
                    continuation.yield(.plan("Verifying Swift toolchain…"))
                    let swift = try await vm.run("command -v swift", environment: nil) { _ in }
                    guard swift == 0 else {
                        continuation.yield(.failed(
                            "The Swift toolchain is not provisioned. Install it on the "
                            + "Toolchain screen (or run `sh /root/install-toolchain.sh` in the Terminal)."))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.plan("Verifying xtool…"))
                    let xtool = try await vm.run("command -v xtool", environment: nil) { _ in }
                    guard xtool == 0 else {
                        continuation.yield(.failed(
                            "xtool is not provisioned. Install it on the Toolchain screen."))
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
            let status = try await vm.run("swift sdk install '\(path)'", environment: nil) { _ in }
            guard status == 0 else { throw BuildError.stepFailed("swift sdk install", status) }
        case .hostedRemote:
            // Resolve the published asset, stage it on the host and install it in
            // the guest (see SDKInstaller). No progress sink here: a build drives
            // this, and the pipeline view has its own console.
            try await SDKInstaller.install(vm: vm) { _, _ in }
        }
    }

    func createProject(named name: String, organizationIdentifier: String) async throws -> Project {
        if !vm.isBooted { try await vm.boot() }
        let path = "/root/projects/\(name)"
        let status = try await vm.run(
            "mkdir -p '\(path)' && cd '\(path)' && XTOOL_ORG='\(organizationIdentifier)' xtool new --name '\(name)'",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw BuildError.stepFailed("xtool new", status) }
        return Project(name: name, organizationIdentifier: organizationIdentifier, rootPath: path)
    }

    func resolve(_ project: Project) -> AsyncThrowingStream<BuildEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if !vm.isBooted { try await vm.boot() }
                    continuation.yield(.plan("Resolving dependencies for \(project.name)…"))
                    let status = try await vm.run(
                        "cd '\(project.rootPath)' && swift package resolve",
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
                    let code = try await vm.run(
                        "cd '\(project.rootPath)' && xtool dev build \(flags)",
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
            "ls -t '\(project.rootPath)/.build'/*.ipa 2>/dev/null | head -1",
            environment: nil
        ) { box.append($0) }
        guard status == 0 else { return nil }
        let path = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
