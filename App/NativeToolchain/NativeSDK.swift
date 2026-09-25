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
    case notABundle(String)
    case invalidMetadata
    case missingTarget
    case missingSDK(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "No native Darwin SDK is installed."
        case .notABundle(let name):
            return "\(name) is not a Darwin SDK bundle and not an Xcode.xip. A bundle is a "
                + "folder (or a zip of one) containing darwin.artifactbundle or swift-sdk.json; "
                + "an Xcode archive starts with 'xar!'."
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

        throw NativeSDKError.notABundle(downloaded.lastPathComponent)
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
    /// What an import did, so the screen can say more than "done".
    struct ImportReport: Sendable {
        var files: Int = 0
        var bytes: Int64 = 0
        /// Things that did not stop the install but will bite later.
        var warnings: [String] = []
    }

    ///  - a `darwin.artifactbundle` **folder** — already built, perhaps by
    ///    `xtool sdk build` on a Mac;
    ///  - a **zip** of one, which is how the hosted bundle is published;
    ///  - an Apple **`Xcode.xip`**, which `DarwinSDKBuilder` turns into one here.
    ///    That is the case that needs a Mac otherwise, and the reason the picker no
    ///    longer filters for folders only.
    ///
    /// Which one it is decided by what the file *is*, not what it is called: the
    /// picker hands over whatever the user chose, and "that is a zip, not a xip" is a
    /// better answer than a bundle search that fails for the wrong reason.
    @discardableResult
    static func installImported(from source: URL,
                                progress: (@Sendable (DarwinSDKBuilder.Progress) -> Void)? = nil) throws -> ImportReport {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let kind = source.pathExtension.lowercased()
        let header = firstBytes(of: source)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // The log is the only way to see this on a device: what was picked, whether
        // the sandbox let us read it, how big it is and what it actually is.
        XForgeLog.note("sdk import: \(source.lastPathComponent) "
                       + "(\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))), "
                       + "kind=\(kind.isEmpty ? "none" : kind), "
                       + "readable=\(accessed), header=\(hex(header))")

        if exists, isDirectory.boolValue {
            try install(from: source)
            return ImportReport()
        }
        if header == Data("xar!".utf8) || kind == "xip" {
            let built = try DarwinSDKBuilder.build(fromXip: source,
                                                   into: XForgeEnvironment.nativeSDKDirectory,
                                                   progress: progress)
            try install(preparedBundle: built.bundle)
            return ImportReport(files: built.files, bytes: built.bytes,
                                warnings: built.hasSwiftStaticRuntime ? [] : [
                                    "the archive has no Swift static runtime "
                                    + "(Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static/iphoneos), "
                                    + "so linking Swift needs one from elsewhere",
                                ])
        }
        if header.starts(with: Data("PK".utf8)) || kind == "zip" {
            if try installAppleXcodeZipIfPresent(at: source, progress: progress) {
                return ImportReport(files: 0, bytes: 0,
                                    warnings: ["imported Apple Xcode Content stream"])
            }
            try installDownloadedArchive(at: source)
            return ImportReport()
        }
        throw NativeSDKError.notABundle(source.lastPathComponent)
    }

    /// Apple Developer's Xcode download can reach Files as a ZIP wrapper containing
    /// `Xcode_27/Content` and `Metadata`, rather than as a file named `.xip`. Do not
    /// unzip it: `Content` declares a ~10 GB cpio and the ZIP itself can already be
    /// 2 GB. Copy just that one compressed member to a temporary file, then use the
    /// same streaming pbzx/cpio builder as a xar xip.
    private static func installAppleXcodeZipIfPresent(
        at source: URL,
        progress: (@Sendable (DarwinSDKBuilder.Progress) -> Void)?
    ) throws -> Bool {
        let archive = try Archive(url: source, accessMode: .read)
        guard let contentEntry = archive.first(where: {
            $0.path == "Xcode_27/Content" ||
            ($0.path.hasSuffix("/Content") && $0.path.split(separator: "/").count == 2)
        }) else { return false }

        let contentURL = XForgeEnvironment.nativeSDKDirectory
            .appendingPathComponent("xcode-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: XForgeEnvironment.nativeSDKDirectory,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contentURL) }

        var completed = Int64(0)
        try archive.extract(contentEntry, to: contentURL) { bytes in
            completed += Int64(bytes)
            if let progress, contentEntry.uncompressedSize > 0 {
                let fraction = min(0.95, Double(completed) / Double(contentEntry.uncompressedSize))
                progress(DarwinSDKBuilder.Progress(fraction: fraction,
                                                    message: "Copying Xcode Content — \(Int(fraction * 100))%"))
            }
            return true
        }

        let staging = XForgeEnvironment.nativeSDKDirectory
            .appendingPathComponent("darwin.artifactbundle.building-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let built = try DarwinSDKBuilder.buildPBZX(from: contentURL, into: staging,
                                                   progress: progress)
        try install(preparedBundle: built.bundle)
        return true
    }

    /// The first four bytes, read without mapping a multi-gigabyte file into memory.
    private static func firstBytes(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) ?? Data()
    }

    private static func hex(_ data: Data) -> String {
        data.isEmpty ? "none" : data.map { String(format: "%02x", $0) }.joined()
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
