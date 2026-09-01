import Foundation
import ZIPFoundation

/// Host-side IPA packager: turns a compiled `.app` bundle into a valid, sideloadable
/// `.ipa`. Fully testable without the VM. Real provisioning signing is layered on via
/// `CodeSigner` (XKit Zupersign); unsigned/ad-hoc IPAs are exactly what SideStore wants.
struct IPABuilder {
    enum BuilderError: LocalizedError {
        case appNotFound
        case infoPlistFailed
        case archiveFailed(String)
        var errorDescription: String? {
            switch self {
            case .appNotFound: return "The compiled .app bundle was not found."
            case .infoPlistFailed: return "Could not write the app Info.plist."
            case .archiveFailed(let m): return "Archive failed: \(m)"
            }
        }
    }

    static let fileManager = FileManager.default

    /// Build a `.ipa` from a compiled `.app` bundle.
    /// - Parameters:
    ///   - appBundle: the compiled `Foo.app`
    ///   - appInfo: Info.plist settings to apply
    ///   - outputDir: where to write the `.ipa` (defaults to the staging directory)
    /// - Returns: the URL of the produced `.ipa`
    @discardableResult
    static func buildIPA(appBundle: URL, appInfo: AppInfo, outputDir: URL) throws -> URL {
        let staging = outputDir
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        // 1. Build the Payload/<Name>.app from the compiled bundle.
        let appName = "\(appInfo.displayName).app"
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent(appName, isDirectory: true)
        try? fileManager.removeItem(at: payload)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        try fileManager.copyItem(at: appBundle, to: destApp)

        // 2. Write the Info.plist from AppInfo.
        try writeInfoPlist(to: destApp, appInfo: appInfo)

        // 3. Write minimal entitlements (sideload-oriented; real team entitlements later).
        try writeEntitlements(to: destApp, appInfo: appInfo)

        // 4. Zip Payload/ → <Name>.ipa
        let ipaURL = staging.appendingPathComponent("\(appName.replacingOccurrences(of: ".app", with: "")).ipa")
        try? fileManager.removeItem(at: ipaURL)
        do {
            try fileManager.zipItem(at: payload, to: ipaURL, shouldKeepParent: true)
        } catch {
            throw BuilderError.archiveFailed(error.localizedDescription)
        }

        return ipaURL
    }

    // MARK: - Info.plist

    static func infoPlistDictionary(_ appInfo: AppInfo) -> [String: Any] {
        [
            "CFBundleIdentifier": appInfo.bundleIdentifier,
            "CFBundleDisplayName": appInfo.displayName,
            "CFBundleName": appInfo.displayName,
            "CFBundleShortVersionString": appInfo.version,
            "CFBundleVersion": appInfo.buildNumber,
            "CFBundlePackageType": "APPL",
            "MinimumOSVersion": appInfo.minimumOSVersion,
            "LSRequiresIPhoneOS": true,
            "UILaunchScreen": [String: Any](),
        ]
    }

    private static func writeInfoPlist(to app: URL, appInfo: AppInfo) throws {
        let plist = infoPlistDictionary(appInfo)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let infoURL = app.appendingPathComponent("Info.plist")
        guard (try? data.write(to: infoURL)) != nil else {
            throw BuilderError.infoPlistFailed
        }
    }

    // MARK: - Entitlements

    static func entitlementsDictionary(_ appInfo: AppInfo) -> [String: Any] {
        [
            "get-task-allow": true,
            "application-identifier": appInfo.bundleIdentifier,
        ]
    }

    private static func writeEntitlements(to app: URL, appInfo: AppInfo) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entitlementsDictionary(appInfo),
            format: .xml,
            options: 0
        )
        try data.write(to: app.appendingPathComponent("Entitlements.plist"))
    }
}
