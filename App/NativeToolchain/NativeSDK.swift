import Foundation

struct NativeSDKLayout: Sendable {
    let bundle: URL
    let sdkRoot: URL
    let swiftResources: URL?
    let swiftStaticResources: URL?
    let platformLibrarySearchPaths: [URL]
}

enum NativeSDKError: LocalizedError {
    case missingBundle
    case invalidMetadata
    case missingTarget
    case missingSDK(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "No native Darwin SDK is installed."
        case .invalidMetadata:
            return "The native Darwin SDK has an invalid swift-sdk.json."
        case .missingTarget:
            return "The Darwin SDK does not define arm64-apple-ios."
        case .missingSDK(let path):
            return "The iPhoneOS SDK is missing at \(path)."
        }
    }
}

/// Reads the same swift-sdk.json layout that xtool's Darwin SDK builder emits,
/// but resolves it directly from the iOS app sandbox rather than through SwiftPM
/// in the Alpine guest.
enum NativeSDK {
    static var installedBundle: URL {
        XForgeEnvironment.nativeSDKDirectory
            .appendingPathComponent("darwin.artifactbundle", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBundle.path)
    }

    static func layout(at bundle: URL = installedBundle) throws -> NativeSDKLayout {
        let metadata = bundle.appendingPathComponent("swift-sdk.json")
        guard let data = try? Data(contentsOf: metadata),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let triples = json["targetTriples"] as? [String: Any],
              let target = triples["arm64-apple-ios"] as? [String: Any] else {
            if !FileManager.default.fileExists(atPath: bundle.path) {
                throw NativeSDKError.missingBundle
            }
            throw NativeSDKError.invalidMetadata
        }

        guard let sdkRootPath = target["sdkRootPath"] as? String else {
            throw NativeSDKError.missingTarget
        }
        let sdkRoot = bundle.appendingPathComponent(sdkRootPath)
        guard FileManager.default.fileExists(atPath: sdkRoot.path) else {
            throw NativeSDKError.missingSDK(sdkRoot.path)
        }

        func optionalURL(_ key: String) -> URL? {
            guard let path = target[key] as? String else { return nil }
            return bundle.appendingPathComponent(path)
        }

        let libraryPaths = (target["librarySearchPaths"] as? [String] ?? [])
            .map { bundle.appendingPathComponent($0) }

        return NativeSDKLayout(
            bundle: bundle,
            sdkRoot: sdkRoot,
            swiftResources: optionalURL("swiftResourcesPath"),
            swiftStaticResources: optionalURL("swiftStaticResourcesPath"),
            platformLibrarySearchPaths: libraryPaths
        )
    }

    static func install(from source: URL) throws {
        let fm = FileManager.default
        let destinationRoot = XForgeEnvironment.nativeSDKDirectory
        let destination = installedBundle
        try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let staging = destinationRoot.appendingPathComponent(
            "darwin.artifactbundle.installing-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: source, to: staging)
        _ = try layout(at: staging)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    static func remove() throws {
        guard FileManager.default.fileExists(atPath: installedBundle.path) else { return }
        try FileManager.default.removeItem(at: installedBundle)
    }
}
