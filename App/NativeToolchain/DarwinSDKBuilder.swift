import Foundation

/// Builds a `darwin.artifactbundle` — the Darwin SDK the native compiler reads —
/// out of an `Xcode.xip`, on the device.
///
/// This is what `xtool sdk build <Xcode.xip>` does on a Mac, and it has to exist
/// here because that is exactly what a phone cannot do: xtool is a macOS program
/// that shells out to `xar`, and there is no guest to run it in any more. The
/// layout it produces is reproduced rather than invented, so a bundle this writes
/// is the same shape as the one the app downloads:
///
/// ```
/// darwin.artifactbundle/
///   swift-sdk.json                 the metadata NativeSDK reads
///   darwin-sdk-version.txt
///   Developer/
///     Platforms/iPhoneOS.platform/
///       Info.plist
///       Developer/SDKs/iPhoneOS27.0.sdk/…
///       Developer/usr/lib/…             (the tbd stubs' link paths)
///       Developer/Library/Frameworks/…  (XCTest and friends, linked from the SDK)
///     Toolchains/XcodeDefault.xctoolchain/usr/lib/
///       swift/…                          the Swift modules and resource dir
///       swift_static/iphoneos/…          the static runtime a sideloaded app links
///       clang/…                          the clang resource dir
/// ```
///
/// Which paths are kept is not a guess: `SDKBuilder.wanted` in xtool enumerates
/// them, and this follows it. One deliberate difference — xtool builds a bundle for
/// three platforms (device, simulator, macOS) because a Mac builds for all of them;
/// XForge only ever compiles for the device, so only `iPhoneOS.platform` is kept and
/// `swift-sdk.json` declares only `arm64-apple-ios`. That is roughly a third of the
/// extraction work and a third of the disk for exactly the same capability.
enum DarwinSDKBuilder {
    /// What the caller gets back. `bundle` is inside the staging directory; the
    /// caller installs it (`NativeSDK.install(preparedBundle:)`).
    struct Result {
        var bundle: URL
        var sdkRoot: String
        var files: Int
        var bytes: Int64
        var skipped: Int
        /// False when the archive carries no `swift_static/iphoneos`. That is a
        /// warning rather than a failure: the SDK's headers and tbd stubs are what C,
        /// Objective-C and Objective-C++ targets need, and refusing the whole import
        /// over a missing Swift runtime would take those away too.
        var hasSwiftStaticRuntime: Bool
    }

    struct Progress: Sendable {
        /// 0…1 over the whole job (extraction dominates).
        var fraction: Double
        var message: String
    }

    enum Error: LocalizedError {
        case noXcodeInside
        case noiPhoneOSSDK
        case notEnoughSpace(needed: Int64, available: Int64)
        var errorDescription: String? {
            switch self {
            case .noXcodeInside:
                return "The .xip does not contain an Xcode.app."
            case .noiPhoneOSSDK:
                return "Xcode was found, but it has no iPhoneOS SDK — the xip is probably "
                    + "a Command Line Tools or a simulator-only archive."
            case .notEnoughSpace(let needed, let available):
                return "Not enough space: building the SDK needs about \(Self.size(needed)) "
                    + "free, and there is \(Self.size(available)). Delete some projects or "
                    + "downloads and try again."
            }
        }

        private static func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Roughly what the iPhoneOS-only bundle occupies. Used for the space guard
    /// before the expensive part starts, not as a hard limit.
    static let estimatedBytes: Int64 = 1_500_000_000

    // MARK: - Entry point

    /// Extract an `Xcode.xip` into `destination/<darwin.artifactbundle>`.
    ///
    /// - Parameters:
    ///   - xip: the archive, wherever the document picker put it.
    ///   - destination: the directory the bundle is written into (its parent, not
    ///     the bundle itself) — `NativeSDK`'s staging directory, in practice.
    ///   - progress: called often, from the calling thread.
    static func build(fromXip xip: URL,
                      into destination: URL,
                      progress: (@Sendable (Progress) -> Void)? = nil) throws -> Result {
        let available = availableBytes(at: destination)
        if available > 0, available < estimatedBytes {
            throw Error.notEnoughSpace(needed: estimatedBytes, available: available)
        }

        let staging = destination.appendingPathComponent(
            "darwin.artifactbundle.building-\(UUID().uuidString)", isDirectory: true)
        do {
            let content = try XipArchive.content(of: xip)
            let writer = Writer(staging: staging)
            XForgeLog.note("xip: Content at byte \(content.offset), \(content.length) bytes")

            // Extraction is essentially all of the wall clock, so the fraction of the
            // compressed member that has been consumed is the honest fraction of the
            // whole job; the metadata write at the end gets the last few percent.
            try XipArchive.forEachEntry(in: xip, content: content, progress: { fraction in
                progress?(Progress(fraction: fraction * 0.95,
                                   message: "Extracting Xcode — \(Int(fraction * 100))%"))
            }) { entry, payload in
                try writer.accept(entry, payload)
            }

            let result = try writer.finish(progress: progress)

            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Which paths become the bundle

    /// The subset of `Xcode.app/Contents/Developer` a Darwin SDK needs.
    ///
    /// Mirrors `SDKBuilder.SDKEntry.wanted` in xtool, restricted to the device
    /// platform, plus its one exclusion (`swift/prebuilt-modules`, which is
    /// per-configuration build output measured in gigabytes).
    ///
    /// Written as explicit list comparisons rather than the nested matcher xtool
    /// uses: there are five leaves, and a reader can check this against xtool's table
    /// line by line.
    static func isWanted(_ path: String) -> Bool {
        var components = path.split(separator: "/").map(String.init)
        if components.first == "." { components.removeFirst() }
        // The archive's own root is `Xcode.app/…`; stripping it lets the same filter
        // read both that and a bare `Contents/Developer/…`.
        if components.first?.hasSuffix(".app") == true { components.removeFirst() }

        guard components.starts(with: ["Contents", "Developer"]) else { return false }
        let rest = Array(components.dropFirst(2))

        // The toolchain: the Swift modules, the static runtime, the clang resource
        // directory. These are the parts a compiler needs that the SDK does not carry.
        if rest.starts(with: ["Toolchains", "XcodeDefault.xctoolchain", "usr", "lib"]) {
            let tail = Array(rest.dropFirst(4))
            guard let name = tail.first,
                  ["swift", "swift_static", "clang"].contains(name) else { return false }
            // Prebuilt modules are generated per platform/configuration and are
            // enormous. The published darwin bundle proves the intended layout:
            // it has no prebuilt-modules entries for iphoneos (or any other Swift
            // platform). Check the path by component, not only for
            // `swift/prebuilt-modules`: real Xcodes use
            // `swift/iphoneos/prebuilt-modules/...`.
            if name == "swift", tail.dropFirst().contains("prebuilt-modules") { return false }
            return true
        }

        guard rest.starts(with: ["Platforms", "iPhoneOS.platform"]) else { return false }
        let tail = Array(rest.dropFirst(2))

        // `Info.plist` describes the platform, and the SDK's own tooling reads it.
        if tail == ["Info.plist"] { return true }

        guard tail.first == "Developer" else { return false }
        let developer = Array(tail.dropFirst())
        if developer.first == "SDKs" || developer.first == "usr" { return true }
        // XCTest and Testing live in the platform's Library rather than in the SDK,
        // and the SDK links to them from there (see `swift-sdk.json`'s search paths).
        return developer.starts(with: ["Library", "Frameworks"])
            || developer.starts(with: ["Library", "PrivateFrameworks"])
    }

    // MARK: - Writing the bundle

    /// Turns entries into the bundle tree, one at a time.
    ///
    /// Stateful because the archive is: a hard link is only recognisable once its
    /// first occurrence has been seen, and a directory entry is the only thing that
    /// says a directory exists at all.
    private final class Writer {
        private let staging: URL
        private var hardLinks: [UInt64: URL] = [:]
        private var files = 0
        private var bytes: Int64 = 0
        private var skipped = 0
        private var sdkRoot: String?
        private var sdkVersion: String?
        private var sawSwiftStaticRuntime = false
        private var sawDeveloperTree = false

        init(staging: URL) {
            self.staging = staging
        }

        func accept(_ entry: XipArchive.Entry, _ payload: XipArchive.Payload) throws {
            // Noted before the filter: an archive with no `Contents/Developer` at all is
            // not an Xcode, and saying that is better than "it has no iPhoneOS SDK".
            if entry.name.contains("Contents/Developer") {
                sawDeveloperTree = true
            }
            // `Self` here is `Writer`, so the outer type is named in full.
            guard DarwinSDKBuilder.isWanted(entry.name) else {
                skipped += 1
                return
            }
            // `Xcode.app/` prefixes everything; the bundle re-roots at `Developer/`,
            // which is what `swift-sdk.json`'s paths are relative to.
            let relative = Self.bundlePath(for: entry.name)
            let target = staging.appendingPathComponent(relative)

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                if relative.contains("Developer/SDKs/"), relative.hasSuffix(".sdk") {
                    // `iPhoneOS.sdk` is a symlink to `iPhoneOS27.0.sdk` in recent
                    // Xcodes; the versioned name is the one worth declaring, so it
                    // wins whenever it turns up.
                    let name = target.lastPathComponent
                    if sdkRoot == nil || name != "iPhoneOS.sdk" {
                        sdkRoot = relative
                        sdkVersion = Self.platformVersion(fromSDKName: name)
                    }
                }
            } else if entry.isSymlink {
                let link = String(decoding: try payload.readAll(), as: UTF8.self)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(atPath: target.path,
                                                           withDestinationPath: link)
                files += 1
            } else if entry.isRegular {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

                // A second occurrence of the same inode is a hard link, and Xcode's
                // trees are full of them: writing the bytes again would multiply the
                // bundle by the link count. When the first occurrence was filtered out
                // there is nothing to link to, and the data is written instead.
                if entry.linkCount > 1 {
                    let key = UInt64(entry.device) << 32 | UInt64(entry.inode)
                    if let original = hardLinks[key] {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.linkItem(at: original, to: target)
                        files += 1
                        return
                    }
                    hardLinks[key] = target
                }

                if relative.contains("swift_static/iphoneos/") {
                    sawSwiftStaticRuntime = true
                }
                try payload.write(to: target)
                files += 1
                bytes += entry.size
            } else {
                // Device nodes, fifos and sockets: nothing an SDK is built from.
                skipped += 1
            }
        }

        /// Write the metadata, having seen the whole tree.
        func finish(progress: (@Sendable (Progress) -> Void)?) throws -> Result {
            guard sawDeveloperTree else { throw Error.noXcodeInside }
            guard let sdkRoot else { throw Error.noiPhoneOSSDK }
            progress?(Progress(fraction: 0.97, message: "Writing swift-sdk.json…"))

            let json = SDKDefinition(
                schemaVersion: "4.0",
                // One triple, unlike xtool's five: XForge compiles for the device.
                targetTriples: [
                    "arm64-apple-ios": SDKDefinition.Triple(
                        sdkRootPath: sdkRoot,
                        includeSearchPaths: ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                        librarySearchPaths: ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                        swiftResourcesPath: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                        swiftStaticResourcesPath: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static"
                    ),
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(json).write(to: staging.appendingPathComponent("swift-sdk.json"))

            // xtool's marker, with the platform version rather than an SDK-build
            // counter: this bundle was not built by xtool, and claiming otherwise
            // would make `xtool sdk` try to update it.
            try Data("\(sdkVersion ?? "unknown")\n".utf8)
                .write(to: staging.appendingPathComponent("darwin-sdk-version.txt"))

            progress?(Progress(fraction: 1, message: "Done"))
            let result = Result(bundle: staging, sdkRoot: sdkRoot, files: files,
                                bytes: bytes, skipped: skipped,
                                hasSwiftStaticRuntime: sawSwiftStaticRuntime)
            XForgeLog.note("xip: \(result.files) files (\(result.bytes) bytes), "
                           + "skipped \(result.skipped), sdkRoot \(result.sdkRoot), "
                           + "swift_static=\(result.hasSwiftStaticRuntime)")
            return result
        }

        /// `Xcode.app/Contents/Developer/…` → `Developer/…`.
        ///
        /// Only `Contents` is dropped: `Developer` is kept because it *is* the
        /// bundle's root — `swift-sdk.json` names `Developer/Platforms/…`, and
        /// dropping it too would put the SDK where the metadata does not look for it.
        static func bundlePath(for entry: String) -> String {
            var components = entry.split(separator: "/").map(String.init)
            if components.first == "." { components.removeFirst() }
            if components.first?.hasSuffix(".app") == true { components.removeFirst() }
            if components.first == "Contents" { components.removeFirst() }
            return components.joined(separator: "/")
        }

        /// `iPhoneOS27.0.sdk` → `27.0`; a bare `iPhoneOS.sdk` has no version to give.
        static func platformVersion(fromSDKName name: String) -> String? {
            let trimmed = name.hasSuffix(".sdk") ? String(name.dropLast(4)) : name
            let digits = trimmed.drop { !$0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }
    }

    // MARK: - Metadata

    private struct SDKDefinition: Encodable {
        struct Triple: Encodable {
            var sdkRootPath: String
            var includeSearchPaths: [String]
            var librarySearchPaths: [String]
            var swiftResourcesPath: String
            var swiftStaticResourcesPath: String
            // xtool also writes `toolsetPaths`, pointing at a `toolset.json` it
            // generates for macro plugins. XForge never runs a plugin (a macro is a
            // separate process, and iOS has none), so listing a file that is not
            // there would be a worse lie than omitting the key.
        }

        var schemaVersion: String
        var targetTriples: [String: Triple]
    }

    /// Build from the pbzx `Content` member extracted from Apple's ZIP wrapper.
    static func buildPBZX(from content: URL, into destination: URL,
                          progress: (@Sendable (Progress) -> Void)? = nil) throws -> Result {
        let staging = destination
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let writer = Writer(staging: staging)
        try XipArchive.forEachPBZX(at: content, progress: progress) { entry, payload in
            try writer.accept(entry, payload)
        }
        return try writer.finish(progress: progress)
    }

    /// Free space on the volume the bundle will be written to.
    static func availableBytes(at url: URL) -> Int64 {
        let probe = url.deletingLastPathComponent().path
        let values = try? URL(fileURLWithPath: probe)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
