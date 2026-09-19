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

    /// Build a `.ipa` from a compiled `.app` bundle.
    ///   - appBundle: the compiled `Foo.app`
    ///   - appInfo: identity to apply to the app's Info.plist
    ///   - outputDir: where to write the `.ipa`
    /// - Returns: the URL of the produced `.ipa`
    ///
    /// Only the identity keys are overridden — the compiled bundle's other keys are
    /// preserved. Replacing the whole Info.plist with a minimal dictionary would drop
    /// `CFBundleExecutable` and produce an app that cannot launch.
    @discardableResult
    static func buildIPA(appBundle: URL, appInfo: AppInfo, outputDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appBundle.path) else { throw BuilderError.appNotFound }

        let staging = outputDir
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // 1. Payload/<Name>.app from the compiled bundle.
        let appName = "\(appInfo.displayName).app"
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent(appName, isDirectory: true)
        try? fm.removeItem(at: payload)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.copyItem(at: appBundle, to: destApp)

        // 2. Merge the identity into the compiled bundle's Info.plist.
        try applyInfoPlist(to: destApp, appInfo: appInfo)

        // Entitlements are NOT written into the bundle: they belong to the code
        // signature, and a stray Entitlements.plist inside the .app is inert at
        // best and confusing at worst.

        // 3. Zip Payload/ → <Name>.ipa
        let ipaURL = staging.appendingPathComponent(
            "\(appName.replacingOccurrences(of: ".app", with: "")).ipa")
        try? fm.removeItem(at: ipaURL)
        do {
            try fm.zipItem(at: payload, to: ipaURL, shouldKeepParent: true)
        } catch {
            throw BuilderError.archiveFailed(error.localizedDescription)
        }
        return ipaURL
    }

    // MARK: - Info.plist

    /// The identity keys XForge sets. Everything else in the compiled bundle's
    /// Info.plist is preserved.
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
        ]
    }

    private static func applyInfoPlist(to app: URL, appInfo: AppInfo) throws {
        let infoURL = app.appendingPathComponent("Info.plist")

        var merged: [String: Any] = [:]
        if let data = try? Data(contentsOf: infoURL),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = existing as? [String: Any] {
            merged = dict
        }
        for (key, value) in infoPlistDictionary(appInfo) {
            merged[key] = value
        }
        if merged["CFBundleExecutable"] == nil {
            // Keep the executable name in step with the binary that is actually there.
            merged["CFBundleExecutable"] = executableName(in: app)
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: merged, format: .xml, options: 0)
        do {
            try data.write(to: infoURL)
        } catch {
            throw BuilderError.infoPlistFailed
        }
    }

    /// The bundle's Mach-O executable: the existing `Info.plist` value if it names a
    /// real file, otherwise the first executable regular file at the bundle root.
    private static func executableName(in app: URL) -> String {
        let fm = FileManager.default
        let declared = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            .flatMap { ($0 as? [String: Any])?["CFBundleExecutable"] as? String }
        if let declared, fm.fileExists(atPath: app.appendingPathComponent(declared).path) {
            return declared
        }
        let contents = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.isExecutableKey])) ?? []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isExecutableKey, .isRegularFileKey])
            if values?.isRegularFile == true, values?.isExecutable == true {
                return url.lastPathComponent
            }
        }
        return app.deletingPathExtension().lastPathComponent
    }
}
