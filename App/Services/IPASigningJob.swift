import Foundation
import Combine

/// Sign an `.ipa` in this process with XKit.
///
/// This replaces the `zsign` job that used to run inside the embedded Linux. The
/// shape is deliberately the same — IPA + `.p12` + profile + entitlements in, a
/// signed IPA out — because that is the workflow a user has: they have a built
/// (unsigned) IPA from the Build screen and an Apple Developer certificate.
///
/// Two things are narrower than before, both on purpose:
///
///  - the private key never leaves the app. It is imported through the Security
///    framework and handed to the signer in memory; nothing is written to disk,
///    which is why the `zsign` password-file workaround is gone with `zsign`;
///  - the signature is produced by XKit's own signer, so a signed app is one the
///    same code path would produce on a Mac (zsign was a copy of it).
@MainActor
final class IPASigningJob: ObservableObject {
    @Published var inputIPA: URL?
    @Published var p12: URL?
    @Published var provisioningProfile: URL?
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

    var canSign: Bool {
        inputIPA != nil && p12 != nil && !password.isEmpty && !isWorking
    }

    func sign() async {
        guard let inputIPA, let p12 else { return }
        let oneShotPassword = password

        let scoped = [inputIPA, p12, provisioningProfile, entitlements].compactMap { $0 }
            .map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, accessed) in scoped where accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        isWorking = true
        error = nil
        signedIPA = nil
        defer {
            // Do not leave the signing secret in the view model after the attempt.
            password = ""
            isWorking = false
        }

        do {
            status = "Reading the signing identity…"
            let keyMaterial = try PKCS12Identity.load(
                data: try Data(contentsOf: p12),
                password: oneShotPassword
            )

            let profileData = try provisioningProfile.map { try Data(contentsOf: $0) }
            let entitlementsPlist = try entitlements.map { try Data(contentsOf: $0) }

            status = "Unpacking \(inputIPA.lastPathComponent)…"
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("xforge-sign-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: inputIPA, to: work)

            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            let apps = try apps(in: payload)
            guard apps.count == 1, let app = apps.first else {
                throw SigningJobError.expectedOneApp(apps.map(\.lastPathComponent))
            }

            try applyIdentityOverrides(to: app)

            status = "Signing \(app.lastPathComponent)…"
            try await AppBundleSigner.sign(
                appBundleURL: app,
                identity: .init(
                    certificateDER: keyMaterial.certificate,
                    privateKey: keyMaterial.key,
                    provisioningProfile: profileData,
                    entitlementsPlist: entitlementsPlist
                )
            )

            status = "Repackaging…"
            let destination = XForgeEnvironment.documentDirectory.appendingPathComponent(
                "Signed-" + inputIPA.deletingPathExtension().lastPathComponent + ".ipa"
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.zipItem(
                at: payload,
                to: destination,
                shouldKeepParent: true
            )
            signedIPA = destination
            status = "Signed IPA ready: \(destination.lastPathComponent)"
        } catch {
            self.error = error.localizedDescription
            status = "Signing failed."
        }
    }

    // MARK: - Helpers

    private func apps(in payload: URL) throws -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension == "app" }
    }

    /// Apply the identity fields the user typed over the bundle's own plist.
    ///
    /// Only these three: replacing the plist wholesale would drop
    /// `CFBundleExecutable` and produce an app that cannot launch.
    private func applyIdentityOverrides(to app: URL) throws {
        var overrides: [String: Any] = [:]
        if !bundleIdentifier.isEmpty { overrides["CFBundleIdentifier"] = bundleIdentifier }
        if !displayName.isEmpty {
            overrides["CFBundleDisplayName"] = displayName
            overrides["CFBundleName"] = displayName
        }
        if !version.isEmpty { overrides["CFBundleShortVersionString"] = version }
        guard !overrides.isEmpty else { return }

        let plistURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else {
            throw SigningJobError.unreadableInfoPlist
        }
        for (key, value) in overrides { plist[key] = value }
        let updated = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try updated.write(to: plistURL, options: .atomic)
    }
}

enum SigningJobError: LocalizedError {
    case expectedOneApp([String])
    case unreadableInfoPlist

    var errorDescription: String? {
        switch self {
        case .expectedOneApp(let found):
            let list = found.isEmpty ? "none" : found.joined(separator: ", ")
            return "The IPA must contain exactly one .app in Payload/; found \(list)."
        case .unreadableInfoPlist:
            return "The app's Info.plist could not be read."
        }
    }
}
