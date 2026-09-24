import Foundation
import XKit

/// Signing an app bundle with XKit, in this process.
///
/// This is the replacement for running `zsign` inside the embedded Linux guest.
/// XKit is xtool's own library and the app already depends on it; its signer is
/// the bundled C implementation, so this stays in-process, needs no subprocess,
/// and never has to copy a private key anywhere the app cannot see it.
///
/// What it does *not* replace: the Apple ID session. Obtaining a certificate
/// without one means anisette + GrandSlam + 2FA (XKit's `SigningContext` /
/// `DeveloperServices` path), which is a separate, device-only piece of work. This
/// signs with an identity the user already has (a `.p12` and a profile).
enum AppBundleSigner {
    struct Identity {
        /// DER bytes of the signing certificate.
        var certificateDER: Data
        /// The private key, in the format `PrivateKey(data:)` accepts (PEM).
        var privateKey: Data
        /// `embedded.mobileprovision` contents, when the identity has one.
        var provisioningProfile: Data?
        /// Entitlements to seal into the signature. Empty means none beyond the
        /// profile's own.
        var entitlements: [String: Any]?
    }

    enum SigningError: LocalizedError {
        case noSignerAvailable
        case entitlementsUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .noSignerAvailable:
                return "XKit reported no usable codesigning backend in this build."
            case .entitlementsUnreadable(let detail):
                return "The entitlements could not be read: \(detail)"
            }
        }
    }

    /// Sign `appBundleURL` in place.
    ///
    /// The profile has to be inside the bundle *before* signing: the signer reads
    /// it to decide which entitlements the signature may carry, and a bundle whose
    /// signature does not match its profile is rejected at install time rather than
    /// at signing time.
    static func sign(appBundleURL: URL, identity: Identity) async throws {
        let certificate = try Certificate(data: identity.certificateDER)
        let privateKey = try PrivateKey(data: identity.privateKey)

        if let profile = identity.provisioningProfile {
            try profile.write(
                to: appBundleURL.appendingPathComponent("embedded.mobileprovision"),
                options: .atomic
            )
        }

        let entitlements = try entitlements(from: identity.entitlements)

        let signer = try Signer.first()
        try await signer.sign(
            app: appBundleURL,
            identity: .real(certificate, privateKey),
            entitlementMapping: [appBundleURL: entitlements],
            progress: { _ in }
        )
    }

    /// `Entitlements` decodes from a property list, so a dictionary has to be
    /// serialized back into one. Building the type directly is not public API.
    private static func entitlements(from dictionary: [String: Any]?) throws -> Entitlements {
        guard let dictionary, !dictionary.isEmpty else {
            return try Entitlements(entitlements: [])
        }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
            return try PropertyListDecoder().decode(Entitlements.self, from: data)
        } catch {
            throw SigningError.entitlementsUnreadable(error.localizedDescription)
        }
    }
}

/// Loading a `.p12` into an `AppBundleSigner.Identity` using the Security
/// framework, which is the only PKCS#12 reader available on iOS.
enum PKCS12Identity {
    enum LoadError: LocalizedError {
        case badPassword
        case noIdentity
        case missingCertificate(Int32)
        case missingKey(Int32)

        var errorDescription: String? {
            switch self {
            case .badPassword:
                return "The PKCS#12 password is wrong, or the file is not a .p12."
            case .noIdentity:
                return "That file holds no signing identity (certificate + private key)."
            case .missingCertificate(let status):
                return "Could not export the certificate (OSStatus \(status))."
            case .missingKey(let status):
                return "Could not export the private key (OSStatus \(status))."
            }
        }
    }

    /// Import a `.p12` and return the certificate and key bytes.
    ///
    /// The key is exported as PKCS#1 DER and then wrapped in a PEM envelope,
    /// which is the form the signer's parser reads. A key that cannot be exported
    /// this way (a hardware-backed one, say) fails here with the Security status
    /// rather than somewhere inside the signer.
    static func load(data: Data, password: String) throws -> (certificate: Data, key: Data) {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else { throw LoadError.badPassword }

        guard let entries = items as? [[String: Any]] else { throw LoadError.noIdentity }
        for entry in entries {
            guard let identityRef = entry[kSecImportItemIdentity as String] else { continue }
            let identity = identityRef as! SecIdentity

            var certificateRef: SecCertificate?
            let certStatus = SecIdentityCopyCertificate(identity, &certificateRef)
            guard certStatus == errSecSuccess, let certificate = certificateRef else {
                throw LoadError.missingCertificate(certStatus)
            }

            var keyRef: SecKey?
            let keyStatus = SecIdentityCopyPrivateKey(identity, &keyRef)
            guard keyStatus == errSecSuccess, let key = keyRef else {
                throw LoadError.missingKey(keyStatus)
            }

            let certificateData = SecCertificateCopyData(certificate) as Data
            var error: Unmanaged<CFError>?
            guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
                let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? -1
                throw LoadError.missingKey(Int32(code))
            }
            return (certificateData, pem(keyData))
        }
        throw LoadError.noIdentity
    }

    /// Wrap raw private-key bytes in a PEM envelope.
    private static func pem(_ der: Data) -> Data {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let text = "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
        return Data(text.utf8)
    }
}
