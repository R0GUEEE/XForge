import Foundation
import SwiftUI

/// Host-side state for the zsign workflow. The actual signer runs in the
/// embedded Alpine guest: zsign is a Linux C++ tool and is not an iOS framework.
/// This service owns only user-selected files, secure-in-memory password state,
/// guest staging and the signed IPA copied back to the app sandbox.
@MainActor
final class IPAConfigureSignService: ObservableObject {
    @Published var inputIPA: URL?
    @Published var provisioningProfile: URL?
    @Published var p12: URL?
    @Published var entitlements: URL?
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

    func clearError() { error = nil }

    func sign() async {
        guard let inputIPA, let provisioningProfile, let p12 else { return }
        isWorking = true; error = nil; signedIPA = nil
        defer { isWorking = false }

        do {
            status = "Starting Alpine…"
            let vm = makeVM()
            await vm.prepareRootfs()
            try await vm.boot()

            let id = UUID().uuidString
            let dir = "/root/xforge/zsign-jobs/\(id)"
            try await run(vm, "mkdir -p \(GuestShell.quote(dir))")

            status = "Copying signing inputs into the guest…"
            let ipaPath = "\(dir)/input.ipa"
            let p12Path = "\(dir)/signing.p12"
            let profilePath = "\(dir)/profile.mobileprovision"
            try await vm.copyIn(hostURL: inputIPA, to: ipaPath)
            try await vm.copyIn(hostURL: p12, to: p12Path)
            try await vm.copyIn(hostURL: provisioningProfile, to: profilePath)
            try await SystemComponents.ensureZsignInstaller(in: vm)

            var command = "sh /root/xforge/install-zsign.sh && zsign -f -k \(GuestShell.quote(p12Path)) -p \(GuestShell.quote(password)) -m \(GuestShell.quote(profilePath))"
            if let entitlements {
                let entitlementsPath = "\(dir)/entitlements.plist"
                try await vm.copyIn(hostURL: entitlements, to: entitlementsPath)
                command += " -e \(GuestShell.quote(entitlementsPath))"
            }
            if !bundleIdentifier.isEmpty { command += " -b \(GuestShell.quote(bundleIdentifier))" }
            if !displayName.isEmpty { command += " -n \(GuestShell.quote(displayName))" }
            if !version.isEmpty { command += " -r \(GuestShell.quote(version))" }
            let outputPath = "\(dir)/signed.ipa"
            command += " -o \(GuestShell.quote(outputPath)) \(GuestShell.quote(ipaPath))"

            status = "Signing in the guest with zsign…"
            try await run(vm, command)
            status = "Copying the signed IPA back…"
            let destination = XForgeEnvironment.documentDirectory
                .appendingPathComponent("Signed-\(inputIPA.deletingPathExtension().lastPathComponent).ipa")
            try await vm.copyOut(guestPath: outputPath, to: destination)
            signedIPA = destination
            status = "Signed IPA ready: \(destination.lastPathComponent)"
            try? await run(vm, "rm -rf \(GuestShell.quote(dir))")
        } catch {
            self.error = error.localizedDescription
            status = "Signing failed."
        }
    }

    private func run(_ vm: any LinuxVM, _ command: String) async throws {
        let status = try await vm.run(command, environment: nil) { [weak self] line in
            Task { @MainActor in self?.status = line }
        }
        guard status == 0 else { throw SignError.commandFailed(status) }
    }

    enum SignError: LocalizedError {
        case commandFailed(Int32)
        var errorDescription: String? {
            switch self { case .commandFailed(let code): return "Guest signing command failed (exit \(code))." }
        }
    }
}
