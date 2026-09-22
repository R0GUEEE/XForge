import Foundation
import SwiftUI

/// Host-side state for the zsign workflow. zsign is a Linux C++ command-line
/// signer, so it runs inside the embedded Alpine guest; the host UI only stages
/// files, invokes it, and copies the signed IPA back.
@MainActor
final class IPAConfigureSignService: ObservableObject {
    @Published var inputIPA: URL?
    @Published var provisioningProfile: URL?
    @Published var p12: URL?
    @Published var entitlements: URL?
    /// Never persisted. Cleared immediately after the signing attempt.
    @Published var password = ""
    @Published var bundleIdentifier = ""
    @Published var displayName = ""
    @Published var version = ""
    @Published var status = "Ready to sign."
    @Published var signedIPA: URL?
    @Published var isWorking = false
    @Published var error: String?

    private let makeVM: @MainActor () -> any LinuxVM

    init(makeVM: @escaping @MainActor () -> any LinuxVM = { XForgeEnvironment.makeVM() }) {
        self.makeVM = makeVM
    }

    var canSign: Bool {
        inputIPA != nil && provisioningProfile != nil && p12 != nil && !password.isEmpty && !isWorking
    }

    func sign() async {
        guard let inputIPA, let provisioningProfile, let p12 else { return }
        let oneShotPassword = password
        guard !oneShotPassword.contains("\n"), !oneShotPassword.contains("\r") else {
            password = ""
            error = "The PKCS#12 password cannot contain a newline."
            return
        }
        let ipaScoped = inputIPA.startAccessingSecurityScopedResource()
        let profileScoped = provisioningProfile.startAccessingSecurityScopedResource()
        let p12Scoped = p12.startAccessingSecurityScopedResource()
        let entitlementsScoped = entitlements?.startAccessingSecurityScopedResource() ?? false
        defer {
            if ipaScoped { inputIPA.stopAccessingSecurityScopedResource() }
            if profileScoped { provisioningProfile.stopAccessingSecurityScopedResource() }
            if p12Scoped { p12.stopAccessingSecurityScopedResource() }
            if entitlementsScoped { entitlements?.stopAccessingSecurityScopedResource() }
        }

        isWorking = true
        error = nil
        signedIPA = nil
        defer {
            // Do not leave the signing secret in the view model after the attempt.
            password = ""
            isWorking = false
        }

        let id = UUID().uuidString
        let dir = "/root/xforge/zsign-jobs/\(id)"
        let ipaPath = "\(dir)/input.ipa"
        let p12Path = "\(dir)/signing.p12"
        let profilePath = "\(dir)/profile.mobileprovision"
        let passwordPath = "\(dir)/.p12-password"
        let scriptPath = "\(dir)/run-sign.sh"
        let outputPath = "\(dir)/signed.ipa"
        var vm: (any LinuxVM)?

        do {
            status = "Starting Alpine…"
            let guest = makeVM()
            vm = guest
            await guest.prepareRootfs()
            try await guest.boot()
            try await run(guest, "mkdir -p \(GuestShell.quote(dir)) && chmod 700 \(GuestShell.quote(dir))")

            status = "Copying signing inputs into the guest…"
            try await guest.copyIn(hostURL: inputIPA, to: ipaPath)
            try await guest.copyIn(hostURL: p12, to: p12Path)
            try await guest.copyIn(hostURL: provisioningProfile, to: profilePath)
            try await SystemComponents.ensureZsignInstaller(in: guest)

            // zsign's upstream -p accepts a password as a process argument, which
            // a same-user guest process could read through /proc/<pid>/cmdline.
            // A short-lived file is narrower exposure: random name inside a 700
            // job directory, chmod 600, consumed by the pinned -Q password-file
            // patch and removed with the rest of this per-signing directory.
            let passwordTemp = FileManager.default.temporaryDirectory
                .appendingPathComponent("xforge-p12-\(UUID().uuidString)")
            try Data(oneShotPassword.utf8).write(to: passwordTemp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: passwordTemp.path)
            defer { try? FileManager.default.removeItem(at: passwordTemp) }
            try await guest.copyIn(hostURL: passwordTemp, to: passwordPath)
            try await run(guest, "chmod 600 \(GuestShell.quote(passwordPath))")

            var args = "-f -k \(GuestShell.quote(p12Path)) -m \(GuestShell.quote(profilePath))"
            if let entitlements {
                let path = "\(dir)/entitlements.plist"
                try await guest.copyIn(hostURL: entitlements, to: path)
                args += " -e \(GuestShell.quote(path))"
            }
            if !bundleIdentifier.isEmpty { args += " -b \(GuestShell.quote(bundleIdentifier))" }
            if !displayName.isEmpty { args += " -n \(GuestShell.quote(displayName))" }
            if !version.isEmpty { args += " -r \(GuestShell.quote(version))" }

            // The patched zsign reads its password from this mode-600 file rather
            // than argv, so the signing secret is not exposed in the guest process
            // table. The per-job directory is deleted after the sign on success
            // or failure.
            let script = """
            #!/bin/sh
            set -eu
            umask 077
            exec zsign \(args) -Q \(GuestShell.quote(passwordPath)) -o \(GuestShell.quote(outputPath)) \(GuestShell.quote(ipaPath))
            """
            let hostScript = FileManager.default.temporaryDirectory
                .appendingPathComponent("xforge-zsign-\(UUID().uuidString).sh")
            try Data(script.utf8).write(to: hostScript, options: .atomic)
            defer { try? FileManager.default.removeItem(at: hostScript) }
            try await guest.copyIn(hostURL: hostScript, to: scriptPath)
            try await run(guest, "chmod 700 \(GuestShell.quote(scriptPath))")

            status = "Installing the pinned zsign build in Alpine (first use only)…"
            try await run(guest, "sh /root/xforge/install-zsign.sh")
            status = "Signing in the guest…"
            try await run(guest, "sh \(GuestShell.quote(scriptPath))")

            status = "Copying the signed IPA back…"
            let destination = XForgeEnvironment.documentDirectory
                .appendingPathComponent("Signed-\(inputIPA.deletingPathExtension().lastPathComponent).ipa")
            try await guest.copyOut(guestPath: outputPath, to: destination)
            signedIPA = destination
            status = "Signed IPA ready: \(destination.lastPathComponent)"
        } catch {
            self.error = error.localizedDescription
            status = "Signing failed."
        }

        // Remove the private key, provisioning profile and password-bearing script
        // from the guest even when signing failed. Keep the output IPA (if any).
        if let vm {
            _ = try? await vm.run("rm -rf \(GuestShell.quote(dir))", environment: nil) { _ in }
        }
    }

    private func run(_ vm: any LinuxVM, _ command: String) async throws {
        let box = OutputBox()
        let status = try await vm.run(command, environment: nil) { [weak self] line in
            box.append(line)
            Task { @MainActor in
                // The status panel is a live short line, not a transcript of
                // secrets or command text. Only show guest output that does not
                // contain arguments from the signing script.
                self?.status = line
            }
        }
        guard status == 0 else {
            throw SignError.commandFailed(status, detail: box.value)
        }
    }

    enum SignError: LocalizedError {
        case commandFailed(Int32, detail: String)
        var errorDescription: String? {
            switch self {
            case .commandFailed(let code, let detail):
                let safe = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return safe.isEmpty
                    ? "Guest signing command failed (exit \(code))."
                    : "Guest signing command failed (exit \(code)): \(safe)"
            }
        }
    }
}

/// Thread-safe output accumulator used while a guest command streams from its
/// background tailer.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    func append(_ value: String) { lock.lock(); stored += value; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
}
