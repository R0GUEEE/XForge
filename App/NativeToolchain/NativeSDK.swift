import Foundation
import ZIPFoundation

struct NativeSDKLayout: Sendable {
    let bundle: URL
    let sdkRoot: URL
    let swiftResources: URL?
    let swiftStaticResources: URL?
    let platformLibrarySearchPaths: [URL]
}

extension NativeSDKLayout {
    /// `-L` paths that make `-lswiftCore` and friends resolvable when linking
    /// statically.
    ///
    /// A sideloaded app links the Swift runtime into the binary — there is no
    /// system-wide `/usr/lib/swift` on iOS to load it from at runtime — so the
    /// linker has to be pointed at the static runtime the Darwin SDK carries.
    /// `swift-sdk.json` names it as `swiftStaticResourcesPath`, and the compiled
    /// libraries for the device live one directory below it (`…/iphoneos`).
    /// `librarySearchPaths` from the same file is the fallback for bundles that
    /// lay it out differently, and both are merged rather than chosen between:
    /// a duplicate `-L` costs nothing, a missing one fails the link.
    var swiftRuntimeLibraryPaths: [URL] {
        var paths: [URL] = []
        if let swiftStaticResources {
            paths.append(swiftStaticResources)
            paths.append(swiftStaticResources.appendingPathComponent("iphoneos", isDirectory: true))
        }
        paths.append(contentsOf: platformLibrarySearchPaths)
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }
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

/// Reads the same `swift-sdk.json` layout that xtool's Darwin SDK builder emits,
/// but resolves it directly from the app's container: SwiftPM's SDK store is a
/// directory inside a toolchain installation, and there is no installation here —
/// the bundle is a folder the app downloaded and unpacked itself.
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

    static func installLatestPrebuilt() async throws {
        let remote = try await XForgeReleases.darwinSDKURL()
        try await install(fromRemote: remote)
    }

    /// Download and install a Darwin SDK archive from an explicit URL.
    ///
    /// The URL-parameterised form is the one the build pipeline uses: the release
    /// lookup happens in the caller, so a caller that already resolved an asset
    /// (or pinned one) does not pay for a second lookup.
    static func install(fromRemote remote: URL) async throws {
        let (downloaded, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(status: http.statusCode, url: remote)
        }
        try installDownloadedArchive(at: downloaded)
    }

    private static func installDownloadedArchive(at downloaded: URL) throws {
        let fm = FileManager.default
        let extractionRoot = XForgeEnvironment.nativeSDKDirectory
            .appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: extractionRoot) }

        try fm.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        try fm.unzipItem(at: downloaded, to: extractionRoot)

        let direct = extractionRoot.appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        if fm.fileExists(atPath: direct.path) {
            try install(from: direct)
            return
        }

        let children = try fm.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let bundle = children.first(where: { $0.lastPathComponent == "darwin.artifactbundle" }) {
            try install(from: bundle)
            return
        }

        // Some release zips contain the bundle contents at the archive root.
        if fm.fileExists(atPath: extractionRoot.appendingPathComponent("swift-sdk.json").path) {
            try install(from: extractionRoot)
            return
        }

        throw NativeSDKError.missingBundle
    }

    static func remove() throws {
        guard FileManager.default.fileExists(atPath: installedBundle.path) else { return }
        try FileManager.default.removeItem(at: installedBundle)
    }

    // MARK: - Importing

    /// Install a bundle the app built itself.
    ///
    /// A *move* where `install(from:)` copies: this bundle is already inside the
    /// app's container, so copying a gigabyte only to delete the original costs a
    /// gigabyte of writes and a second gigabyte of free space for nothing.
    static func install(preparedBundle: URL) throws {
        let fm = FileManager.default
        let destination = installedBundle
        try fm.createDirectory(at: XForgeEnvironment.nativeSDKDirectory,
                               withIntermediateDirectories: true)
        _ = try layout(at: preparedBundle)  // validate before replacing what is there
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: preparedBundle, to: destination)
    }

    /// Install from whatever the document picker handed over.
    ///
    /// Three shapes arrive this way, and they are told apart by what they are rather
    /// than by what they are called:
    ///
    ///  - a `darwin.artifactbundle` **folder** — already built, perhaps by
    ///    `xtool sdk build` on a Mac;
    ///  - a **zip** of one, which is how the hosted bundle is published;
    ///  - an Apple **`Xcode.xip`**, which `DarwinSDKBuilder` turns into one here.
    ///    That is the case that needs a Mac otherwise, and the reason the picker no
    ///    longer filters for folders only.
    static func installImported(from source: URL,
                                progress: (@Sendable (DarwinSDKBuilder.Progress) -> Void)? = nil) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let kind = source.pathExtension.lowercased()

        if exists, isDirectory.boolValue {
            try install(from: source)
        } else if kind == "xip" {
            let built = try DarwinSDKBuilder.build(fromXip: source,
                                                   into: XForgeEnvironment.nativeSDKDirectory,
                                                   progress: progress)
            try install(preparedBundle: built.bundle)
        } else if kind == "zip" {
            try installDownloadedArchive(at: source)
        } else {
            throw NativeSDKError.missingBundle
        }
    }

    /// Delete the copy the document picker made of an imported archive.
    ///
    /// `fileImporter` hands over a copy inside the app's own container, and for an
    /// `Xcode.xip` that copy is ~10 GB: leaving it behind would fill the device on
    /// the first import. Only a file that really is one of ours is removed — the
    /// picker's import directories are under `tmp/`, and a URL the picker returned
    /// in place (or a folder the user owns) is left alone.
    static func discardImportCopy(at source: URL) {
        let fm = FileManager.default
        let path = source.standardizedFileURL.path
        let temporary = fm.temporaryDirectory.standardizedFileURL.path
        let inbox = XForgeEnvironment.documentDirectory
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        guard path.hasPrefix(temporary + "/") || path.hasPrefix(inbox + "/") else { return }
        try? fm.removeItem(at: source)
    }
}
