import Foundation
import CryptoKit
import ZIPFoundation

/// A Darwin SDK that ships **inside** the app bundle, so a freshly installed
/// XForge can compile without downloading ~456 MB first.
///
/// The archive is placed in the app bundle's `BundledSDK/` folder by the IPA
/// workflow (`.github/workflows/build-ipa.yml`) or, locally, by
/// `Tools/fetch-bundled-sdk.sh`. Beside it sits `bundled-sdk.json`, which records
/// what the archive is and where it came from — release tag, source URL, byte
/// count and SHA-256 — because an app that installs a gigabyte of Apple's
/// headers should be able to say exactly which artifact it installed.
///
/// Three rules shape everything here, and they are the reason this is a type of
/// its own rather than a branch inside `NativeSDK`:
///
///  1. **Nothing is deleted that the user did not ask to delete.** An automatic
///     install only runs when there is no SDK at all; an explicit install asks
///     first when it would replace one (`NativeSDK.install(preparedBundle:)`
///     validates the new bundle before it removes anything); the bundled archive
///     inside the app is never touched.
///  2. **No silent network fallback.** If this build carries a bundle, that
///     bundle is the source. A label that cannot be installed fails and says why
///     — it does not quietly pull a different SDK from GitHub, which is exactly
///     how a verified artifact turns into an unverified one.
///  3. **First run happens once.** An attempt is recorded before the expensive
///     part starts, so a failure does not become a re-extraction on every launch;
///     a user who removed the SDK is remembered as having declined *that* build,
///     so it does not come back behind their back.
///
/// The archive is verified against the manifest's SHA-256 before a single byte is
/// unpacked, and the unpacked tree is validated by `NativeSDK.layout` before it
/// replaces anything. Redistribution of the contents is a licensing question, not
/// a technical one — see `Docs/BUNDLED-SDK.md`.
enum BundledDarwinSDK {
    // MARK: - What the bundle looks like

    /// The folder inside the app bundle (`Bundle.main.resourceURL/BundledSDK`).
    ///
    /// `project.yml` adds it as a *folder reference* resource, so the directory
    /// survives into the `.app` with its own name and everything inside it — the
    /// alternative (individual file references) would mean every new artifact
    /// name needs a project file change.
    static let folderName = "BundledSDK"
    static let archiveName = "darwin.artifactbundle.zip"
    static let manifestName = "bundled-sdk.json"
    static let bundleDirectoryName = "darwin.artifactbundle"

    /// Conservative size of the unpacked, iPhoneOS-only bundle.
    ///
    /// Used only as a preflight estimate when the manifest does not carry a
    /// measured `installedByteCount` (the published zip does not, because
    /// measuring it in CI would mean unpacking 1.5 GB on the runner). A device
    /// with less free space than this gets a clear refusal instead of a
    /// half-written tree that has to be cleaned up afterwards.
    static let estimatedInstalledBytes: Int64 = 1_600_000_000
    /// Slack on top of the estimate: the container also holds the project, the
    /// staged IPA and the log.
    static let headroomBytes: Int64 = 250_000_000

    // MARK: - Manifest

    /// `BundledSDK/bundled-sdk.json`.
    ///
    /// Written by the tooling, never by the app. `schemaVersion` is checked so a
    /// future layout change is refused rather than misread, and the hashes are
    /// what make the archive's provenance checkable on a device that has no
    /// network.
    struct Manifest: Codable, Equatable, Sendable {
        var schemaVersion: Int
        /// e.g. `darwin-sdk-7`.
        var releaseTag: String
        /// e.g. `darwin.artifactbundle.zip`.
        var assetName: String
        /// The release asset URL the file was fetched from.
        var sourceURL: String
        /// Lower-case hex SHA-256 of the archive.
        var sha256: String
        /// Size of the archive in bytes.
        var byteCount: Int64
        /// Size of the unpacked bundle, when it has been measured.
        var installedByteCount: Int64?
        /// Platform version from the SDK's `darwin-sdk-version.txt`, when known.
        var sdkVersion: String?
        /// Free-form provenance/licensing note. Never interpreted by the app.
        var license: String?
        /// ISO-8601 timestamp of when the manifest was written.
        var generatedAt: String?

        static let currentSchemaVersion = 1
    }

    /// What a lookup found in the app bundle.
    enum Discovery: Equatable, Sendable {
        /// This build carries no SDK. Not an error: a plain clone has none.
        case notBundled
        /// Archive + manifest, both present and readable.
        case bundled(archive: URL, manifest: Manifest)
        /// An archive with no usable manifest: present, but nothing to verify it
        /// against. Installable on request, never automatically.
        case unverified(archive: URL, reason: String)
    }

    /// What an automatic install should do.
    enum Decision: Equatable, Sendable {
        case install
        case alreadyInstalled
        case notBundled
        /// The user removed an SDK that came from this exact release.
        case declined
        /// This release was attempted before (and either failed or was removed).
        case previouslyAttempted
        /// Present but unverifiable — a button, not a first-run action.
        case unverified
    }

    /// Persisted per-install bookkeeping, at
    /// `<Documents>/native-sdk/bundled-sdk-state.json`.
    ///
    /// Deliberately *outside* `darwin.artifactbundle`, so removing the SDK does
    /// not remove the memory of why it was removed.
    struct State: Codable, Equatable, Sendable {
        var attempts: [String] = []
        var declined: [String] = []
        var lastError: String?
    }

    // MARK: - Errors

    enum Error: LocalizedError {
        case notBundled
        case unverified(String)
        case integrity(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case noBundleInsideArchive(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This build of XForge does not carry a Darwin SDK. Download one "
                    + "from the Toolchain screen, or install a release built with the SDK "
                    + "bundled."
            case .unverified(let reason):
                return "The bundled Darwin SDK cannot be verified: \(reason). Nothing was "
                    + "installed. Install the SDK from the Toolchain screen instead."
            case .integrity(let reason):
                return "The bundled Darwin SDK failed its integrity check: \(reason). "
                    + "Nothing was installed; reinstall XForge from a fresh download."
            case .notEnoughSpace(let needed, let available):
                return "Not enough space to install the bundled SDK: it needs about "
                    + "\(Self.size(needed)) free and there is \(Self.size(available)). "
                    + "Delete some projects or downloads and try again."
            case .noBundleInsideArchive(let name):
                return "\(name) does not contain a darwin.artifactbundle "
                    + "(no swift-sdk.json inside)."
            case .installFailed(let message):
                return "The bundled Darwin SDK could not be installed: \(message)"
            }
        }

        private static func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    // MARK: - Discovery

    /// Where the folder may land in a built `.app`.
    ///
    /// A folder-reference resource normally copies to the bundle root, but Xcode
    /// also produces `<App>.app/Resources/<folder>` — for framework targets, and
    /// for projects whose "Copy Bundle Resources" phase keeps the group layout —
    /// so both are searched rather than one being assumed. `bundleURL` catches a
    /// bundle whose `resourceURL` is not the app root.
    static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The `BundledSDK` folder, if this build has one.
    static func folder(in roots: [URL] = defaultSearchRoots()) -> URL? {
        let fm = FileManager.default
        for root in roots {
            for relative in [folderName, "Resources/\(folderName)"] {
                let candidate = root.appendingPathComponent(relative, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Read what is in `directory` (the `BundledSDK` folder, not its parent).
    ///
    /// Parameterised rather than reading `Bundle.main` so the decision table below
    /// can be tested against fixtures; the app passes `Bundle.main.resourceURL`.
    static func discovery(in directory: URL?) -> Discovery {
        let fm = FileManager.default
        guard let directory else { return .notBundled }
        let archive = directory.appendingPathComponent(archiveName)
        guard fm.fileExists(atPath: archive.path) else { return .notBundled }

        let manifestURL = directory.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .unverified(archive: archive,
                               reason: "\(manifestName) is missing, so there is no digest to check")
        }
        do {
            return .bundled(archive: archive, manifest: try decodeManifest(data))
        } catch {
            return .unverified(archive: archive, reason: error.localizedDescription)
        }
    }

    /// The app-bundle lookup as the app performs it.
    static func currentDiscovery() -> Discovery {
        discovery(in: folder())
    }

    static var isBundled: Bool {
        if case .notBundled = currentDiscovery() { return false }
        return true
    }

    /// Decode and validate a manifest. Pure, so the schema check is testable.
    static func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw Error.unverified("bundled-sdk.json is not a valid manifest: \(error.localizedDescription)")
        }
        guard manifest.schemaVersion == Manifest.currentSchemaVersion else {
            throw Error.unverified("bundled-sdk.json has schemaVersion \(manifest.schemaVersion), "
                                   + "this build understands \(Manifest.currentSchemaVersion)")
        }
        guard manifest.byteCount > 0 else {
            throw Error.unverified("bundled-sdk.json records no size")
        }
        let hex = manifest.sha256.lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw Error.unverified("bundled-sdk.json does not carry a SHA-256 digest")
        }
        return manifest
    }

    // MARK: - The decision table

    /// Whether an *automatic* (first-run) install should happen.
    ///
    /// Pure and exhaustive: every combination of "already installed", "what the
    /// app carries" and "what happened before" maps to exactly one answer, and
    /// the order of the guards is the policy.
    static func decision(isInstalled: Bool, discovery: Discovery, state: State) -> Decision {
        // An existing SDK is never replaced by an automatic install — that is the
        // user's SDK, possibly one they imported or built from a xip.
        if isInstalled { return .alreadyInstalled }

        switch discovery {
        case .notBundled:
            return .notBundled
        case .unverified:
            return .unverified
        case .bundled(_, let manifest):
            if state.declined.contains(manifest.releaseTag) { return .declined }
            if state.attempts.contains(manifest.releaseTag) { return .previouslyAttempted }
            return .install
        }
    }

    /// The decision for this app and its stored state.
    static func currentDecision(isInstalled: Bool = NativeSDK.isInstalled) -> Decision {
        decision(isInstalled: isInstalled,
                 discovery: currentDiscovery(),
                 state: loadState())
    }

    // MARK: - Persisted state

    static var stateURL: URL {
        XForgeEnvironment.nativeSDKDirectory.appendingPathComponent("bundled-sdk-state.json")
    }

    static func loadState(at url: URL = stateURL) -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    /// Best-effort: bookkeeping that cannot be written is not a reason to fail an
    /// install, but it is worth a log line because it changes what happens next
    /// launch.
    static func saveState(_ state: State, at url: URL = stateURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            XForgeLog.note("sdk bundle: could not write \(url.lastPathComponent): "
                           + error.localizedDescription)
        }
    }

    /// Remember that an install of `tag` was started. Called *before* extraction so
    /// a crash or a force-quit mid-install does not turn into a retry loop on every
    /// launch.
    static func recordAttempt(tag: String, at url: URL = stateURL) {
        var state = loadState(at: url)
        if !state.attempts.contains(tag) { state.attempts.append(tag) }
        saveState(state, at: url)
    }

    /// The user removed an SDK that came from `tag`: do not bring it back
    /// automatically. Called by the Toolchain screen's Remove button.
    static func recordUserRemoval(tag: String, at url: URL = stateURL) {
        var state = loadState(at: url)
        if !state.declined.contains(tag) { state.declined.append(tag) }
        saveState(state, at: url)
    }

    static func recordFailure(_ message: String, at url: URL = stateURL) {
        var state = loadState(at: url)
        state.lastError = message
        saveState(state, at: url)
    }

    // MARK: - Integrity

    /// Streamed SHA-256 of a file. Streaming, not `Data(contentsOf:)`: the archive
    /// is ~456 MB and the app has better uses for that memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Installing

    struct Progress: Sendable {
        var fraction: Double
        var message: String
    }

    struct Report: Sendable {
        var releaseTag: String
        var archiveBytes: Int64
        var verified: Bool
        /// False when there was nothing to replace (the normal first-run case).
        var replacedExisting: Bool
    }

    /// Serialises installs so a first-run install and a build stage cannot both
    /// unpack into `native-sdk/`.
    ///
    /// A class rather than a bare `NSLock` static: Swift 6 requires a global's type
    /// to be `Sendable`, and saying so explicitly here is cheaper than depending on
    /// the SDK's annotation for `NSLock`.
    private final class InstallLock: @unchecked Sendable {
        private let lock = NSLock()
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }
    private static let installLock = InstallLock()

    /// Install the SDK carried by this build.
    ///
    /// Async because it is minutes of work: callers are UI tasks and build stages,
    /// and neither should block the main actor. The work itself is synchronous and
    /// runs on a detached task.
    static func install(discovery: Discovery,
                        in root: URL = XForgeEnvironment.nativeSDKDirectory,
                        stateURL: URL = BundledDarwinSDK.stateURL,
                        replacing: Bool = false,
                        progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Report {
        try await Task.detached(priority: .userInitiated) {
            try installSynchronously(discovery: discovery, in: root, stateURL: stateURL,
                                     replacing: replacing, progress: progress)
        }.value
    }

    /// Install whatever this app carries, with no network fallback of any kind.
    ///
    /// `replacing` is false for the first-run path and for build stages: an SDK
    /// that appears at the destination while this runs belongs to someone else.
    /// Only the Toolchain screen's confirmed "Reinstall" passes true.
    static func installBundled(replacing: Bool = false,
                               progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Report {
        try await install(discovery: currentDiscovery(), replacing: replacing, progress: progress)
    }

    /// The synchronous core. Internal so tests can drive the unpacking half.
    static func installSynchronously(discovery: Discovery,
                                     in root: URL,
                                     stateURL: URL,
                                     replacing: Bool = false,
                                     progress: (@Sendable (Progress) -> Void)? = nil) throws -> Report {
        let fm = FileManager.default
        let archive: URL
        let manifest: Manifest?

        switch discovery {
        case .notBundled:
            throw Error.notBundled
        case .unverified(let url, let reason):
            // Present but unverifiable: refuse rather than "try it and see". A
            // corrupt SDK that installs is worse than no SDK at all.
            throw Error.unverified(reason + " (at \(url.lastPathComponent))")
        case .bundled(let url, let parsed):
            archive = url
            manifest = parsed
        }

        // One install at a time, and a re-check inside the lock: another install
        // (a build stage, or the launch task) may have finished while this waited.
        // The destination is derived from `root`, not read from the environment:
        // a test (or any caller with its own directory) never touches the app's
        // installed SDK, and the commit below is scoped to the same path.
        let destination = NativeSDK.installedBundle(in: root)

        return try installLock.withLock {
            guard !fm.fileExists(atPath: destination.path) else {
                // Something is already there. An automatic install must not
                // replace it — it could be the user's import, or a build that
                // finished while this waited. `replacing` is only ever true after
                // an explicit, confirmed request.
                guard replacing else {
                    throw NativeSDKError.destinationOccupied(destination.path)
                }
                return try performInstall(archive: archive, manifest: manifest, root: root,
                                          destination: destination, stateURL: stateURL,
                                          replacing: true, progress: progress)
            }
            return try performInstall(archive: archive, manifest: manifest, root: root,
                                      destination: destination, stateURL: stateURL,
                                      replacing: false, progress: progress)
        }
    }

    /// Verify, preflight, unpack and commit — the body of an install, run under
    /// the lock.
    private static func performInstall(archive: URL,
                                       manifest: Manifest?,
                                       root: URL,
                                       destination: URL,
                                       stateURL: URL,
                                       replacing: Bool,
                                       progress: (@Sendable (Progress) -> Void)?) throws -> Report {
        let fm = FileManager.default

        progress?(Progress(fraction: 0.01, message: "Checking the bundled SDK…"))
        if let manifest {
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size == Int(manifest.byteCount) else {
                throw Error.integrity("the archive is \(size) bytes, the manifest says \(manifest.byteCount)")
            }
            let digest = try sha256Hex(of: archive)
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
                throw Error.integrity("sha256 \(digest) does not match \(manifest.sha256)")
            }
            XForgeLog.note("sdk bundle: verified \(archive.lastPathComponent) "
                           + "(\(manifest.releaseTag), \(size) bytes, sha256 \(digest))")
        }

        // Space, from the archive's own central directory: the sum of every
        // entry's uncompressed size. That is the number that matters — the zip is
        // ~456 MB and unpacks to well over a gigabyte — and it costs a metadata
        // pass, not a decompression. The manifest's figure and a conservative
        // estimate are only fallbacks.
        let measured = uncompressedBytes(of: archive)
        let neededBase = measured
            ?? manifest?.installedByteCount
            ?? estimatedInstalledBytes
        let needed = neededBase + max(headroomBytes, neededBase / 20)
        let available = availableBytes(at: root)
        if available > 0, available < needed {
            throw Error.notEnoughSpace(needed: needed, available: available)
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("bundled-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        progress?(Progress(fraction: 0.05,
                           message: "Unpacking the Darwin SDK — "
                             + ByteCountFormatter.string(fromByteCount: neededBase, countStyle: .file)))
        let unpacked = try unpack(archive, into: staging)

        progress?(Progress(fraction: 0.95, message: "Installing the Darwin SDK…"))
        // `commit` validates the staged bundle before it looks at the destination,
        // refuses to replace one it did not just check for, and swaps rather than
        // removing first. The unpacked tree is *moved*, so peak disk stays at
        // archive + unpacked tree with no second copy.
        let replaced = fm.fileExists(atPath: destination.path)
        do {
            try NativeSDK.commit(preparedBundle: unpacked, to: destination, replacing: replacing)
        } catch {
            recordFailure(error.localizedDescription, at: stateURL)
            throw Error.installFailed(error.localizedDescription)
        }
        _ = try NativeSDK.layout(at: destination)   // must parse, not just exist

        if let manifest {
            recordAttempt(tag: manifest.releaseTag, at: stateURL)
        }
        progress?(Progress(fraction: 1, message: "Darwin SDK installed"))
        XForgeLog.note("sdk bundle: installed \(manifest?.releaseTag ?? "unverified archive") at "
                       + destination.path)

        return Report(releaseTag: manifest?.releaseTag ?? "unknown",
                      archiveBytes: manifest?.byteCount ?? 0,
                      verified: manifest != nil,
                      replacedExisting: replaced)
    }

    /// Aggregate uncompressed size from the archive's central directory.
    ///
    /// `nil` when the archive cannot be read as a zip; the caller then falls back
    /// to the manifest or to the conservative estimate.
    static func uncompressedBytes(of archive: URL) -> Int64? {
        guard let zip = try? Archive(url: archive, accessMode: .read) else { return nil }
        var total: Int64 = 0
        for entry in zip { total += Int64(entry.uncompressedSize) }
        return total > 0 ? total : nil
    }

    /// Unzip `archive` into `root` and return the directory that holds
    /// `swift-sdk.json`.
    ///
    /// Three shapes are accepted, because the published zip has changed shape
    /// before: `darwin.artifactbundle/` at the root, the bundle's *contents* at the
    /// root, and a single wrapper directory. Anything else is refused rather than
    /// guessed at.
    ///
    /// `ZIPFoundation` normalises entry paths and refuses traversal outside the
    /// destination, so nothing here has to re-implement that.
    static func unpack(_ archive: URL, into root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.unzipItem(at: archive, to: root)

        let direct = root.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        if fm.fileExists(atPath: direct.appendingPathComponent("swift-sdk.json").path) {
            return direct
        }
        if fm.fileExists(atPath: root.appendingPathComponent("swift-sdk.json").path) {
            return root
        }
        let entries = (try? fm.subpathsOfDirectory(atPath: root.path)) ?? []
        let candidates = entries.filter {
            $0 == "swift-sdk.json" || $0.hasSuffix("/swift-sdk.json")
        }.map { root.appendingPathComponent($0).deletingLastPathComponent() }
        if candidates.count == 1 { return candidates[0] }
        throw Error.noBundleInsideArchive(archive.lastPathComponent)
    }

    /// Free space on the volume `url` lives on (0 when it cannot be read).
    static func availableBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - First-run install

/// An immutable, Sendable capture for progress callbacks that hop back to the
/// main actor. Capturing a weak local `self` variable directly in the nested
/// @Sendable callback is diagnosed as a mutable capture under Swift 6.
private struct WeakBundledSDKMonitor: @unchecked Sendable {
    weak var value: BundledSDKMonitor?
    init(_ value: BundledSDKMonitor) { self.value = value }
}

/// Runs the bundled-SDK install once, in the background, and lets the Toolchain
/// screen show what it is doing.
///
/// A launch-time install is the difference between "the app works after
/// downloading 456 MB" and "the app works". It is deliberately *not* awaited by
/// launch: extracting ~1.5 GB takes minutes, so it runs detached with an
/// `InstallAssertion` holding the app awake, and both the Toolchain and Build
/// screens observe `isInstalling` rather than blocking on it.
@MainActor
final class BundledSDKMonitor: ObservableObject {
    static let shared = BundledSDKMonitor()

    @Published private(set) var isInstalling = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var status: String?
    /// The last line the screen should show: success, a skip, or the failure.
    @Published private(set) var outcome: String?

    private var task: Task<Void, Never>?

    /// Called from launch. Does nothing — with no error, no alert — unless this
    /// build carries a verified SDK, none is installed, and this exact release has
    /// not been attempted or declined before.
    func startAutomaticInstallIfNeeded() {
        guard task == nil, !isInstalling else { return }
        let discovery = BundledDarwinSDK.currentDiscovery()
        let decision = BundledDarwinSDK.decision(isInstalled: NativeSDK.isInstalled,
                                                 discovery: discovery,
                                                 state: BundledDarwinSDK.loadState())
        switch decision {
        case .alreadyInstalled, .notBundled, .declined, .previouslyAttempted:
            return
        case .unverified:
            outcome = "A Darwin SDK ships in this app but has no manifest to verify it "
                + "against. Install it from the Toolchain screen."
            return
        case .install:
            break
        }

        guard case .bundled(_, let manifest) = discovery else { return }
        // Recorded before the work starts: a crash mid-extraction must not become a
        // fresh attempt on every launch.
        BundledDarwinSDK.recordAttempt(tag: manifest.releaseTag)

        isInstalling = true
        fraction = 0
        status = "Installing the bundled Darwin SDK (\(manifest.releaseTag))…"
        let assertion = InstallAssertion.begin(reason: "sdk-bundled")
        let owner = WeakBundledSDKMonitor(self)
        task = Task { [weak self, owner] in
            defer { assertion.end() }
            do {
                let report = try await BundledDarwinSDK.install(
                    discovery: discovery,
                    progress: { update in
                        Task { @MainActor in
                            owner.value?.fraction = update.fraction
                            owner.value?.status = update.message
                        }
                    })
                self?.fraction = 1
                self?.outcome = "Installed the bundled Darwin SDK (\(report.releaseTag))."
                XForgeLog.note("sdk bundle: first-run install of \(report.releaseTag) finished")
            } catch {
                XForgeLog.note("sdk bundle: first-run install failed: \(error)")
                self?.outcome = error.localizedDescription
                BundledDarwinSDK.recordFailure(error.localizedDescription)
            }
            self?.isInstalling = false
            self?.status = nil
            self?.task = nil
        }
    }

    /// An explicit install, from the Toolchain screen.
    ///
    /// `replacing` is the *confirmed* "Reinstall" case: the user chose to replace
    /// the SDK that is there. It is false otherwise, so even a manual install
    /// cannot delete an SDK that arrived from an import while the screen was open —
    /// it fails with "already installed" instead.
    func installExplicitly(replacing: Bool = false) {
        guard task == nil, !isInstalling else { return }
        let discovery = BundledDarwinSDK.currentDiscovery()
        isInstalling = true
        fraction = 0
        status = "Installing the bundled Darwin SDK…"
        outcome = nil
        let assertion = InstallAssertion.begin(reason: "sdk-bundled-manual")
        let owner = WeakBundledSDKMonitor(self)
        task = Task { [weak self, owner] in
            defer { assertion.end() }
            do {
                let report = try await BundledDarwinSDK.install(
                    discovery: discovery,
                    replacing: replacing,
                    progress: { update in
                        Task { @MainActor in
                            owner.value?.fraction = update.fraction
                            owner.value?.status = update.message
                        }
                    })
                self?.fraction = 1
                self?.outcome = report.replacedExisting
                    ? "Replaced the installed SDK with the bundled \(report.releaseTag)."
                    : "Installed the bundled Darwin SDK (\(report.releaseTag))."
            } catch {
                XForgeLog.note("sdk bundle: install failed: \(error)")
                self?.outcome = error.localizedDescription
                BundledDarwinSDK.recordFailure(error.localizedDescription)
            }
            self?.isInstalling = false
            self?.status = nil
            self?.task = nil
        }
    }
}
