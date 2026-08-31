import Foundation

/// BuildExecutor backed by the embedded Linux VM.
///
/// Only the genuinely heavy operations cross into the VM (toolchain bootstrap,
/// SDK install, and `swift build`/`xtool dev build`). Everything else is native.
final class EmbeddedLinuxExecutor: BuildExecutor, @unchecked Sendable {
    private let vm: LinuxVM
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
                    continuation.yield(.plan("Verifying Swift toolchain…"))
                    let code = try await vm.run("swift --version 2>/dev/null || echo NO_TOOLCHAIN", environment: nil) { _ in }
                    if code != 0 {
                        continuation.yield(.failed("Swift toolchain missing. Run `EmbeddedLinux/install-toolchain.sh` inside the VM."))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.plan("Verifying xtool…"))
                    _ = try await vm.run("xtool --version 2>/dev/null || echo NO_XTOOL", environment: nil) { _ in }
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
            _ = try await vm.run("swift sdk install '\(path)'", environment: nil) { _ in }
        case .hostedRemote(let url):
            // Download into the guest via the VM's network, then install.
            _ = try await vm.run(
                "curl -fL '\(url.absoluteString)' -o /tmp/darwin.artifactbundle.zip && unzip -qo /tmp/darwin.artifactbundle.zip -d /tmp/darwin-sdk && swift sdk install /tmp/darwin-sdk/darwin.artifactbundle",
                environment: nil
            ) { _ in }
        }
    }

    func createProject(named name: String, organizationIdentifier: String) async throws -> Project {
        if !vm.isBooted { try await vm.boot() }
        let path = "/root/projects/\(name)"
        _ = try await vm.run(
            "mkdir -p '\(path)' && cd '\(path)' && XTOOL_ORG='\(organizationIdentifier)' xtool new --name '\(name)'",
            environment: nil
        ) { _ in }
        return Project(name: name, organizationIdentifier: organizationIdentifier, rootPath: path)
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

                    let ipa = "\(project.rootPath)/.build/\(project.name).ipa"
                    let hostURL = stagingDir.appendingPathComponent("\(project.name).ipa")
                    try await vm.copyOut(guestPath: ipa, to: hostURL)

                    if code != 0 {
                        continuation.yield(.failed("Build failed (exit \(code))."))
                        continuation.finish()
                        return
                    }

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
}
