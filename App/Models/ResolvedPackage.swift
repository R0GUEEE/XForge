import CoreFoundation
import Foundation

// MARK: - Limits

/// Hard bounds applied to a `Package.resolved` document before any of it is trusted.
///
/// A lockfile is attacker-controlled input whenever it arrives with a cloned or
/// downloaded repository, so the parser refuses anything bigger or stranger than a
/// real lockfile instead of growing to fit it. Every limit is a stored property so
/// a caller (or a test) can tighten one without changing the rest.
struct ResolvedPackageLimits: Sendable, Equatable {
    /// Bytes read from disk. A real lockfile is a few kilobytes; 2 MB leaves room
    /// for thousands of pins while keeping parse time and memory bounded.
    var maxBytes: Int = 2 * 1024 * 1024
    /// Pins in one document. The largest real-world graphs are in the low hundreds.
    var maxPins: Int = 2_000
    /// Nesting depth of the JSON itself, so a pathological document cannot make
    /// `JSONSerialization` recurse without bound.
    var maxJSONDepth: Int = 32
    /// SwiftPM caps package identities at 100 characters; so does this parser.
    var maxIdentityLength: Int = 100
    /// The v1 `package` display name.
    var maxDisplayNameLength: Int = 128
    /// The `location` / `repositoryURL` string, before it is parsed as a URL.
    var maxLocationLength: Int = 512
    /// A semver string such as `5.8.1`.
    var maxVersionLength: Int = 128
    /// A branch name recorded in `state`.
    var maxBranchLength: Int = 256
    /// The v3 `originHash`.
    var maxOriginHashLength: Int = 128

    static let `default` = ResolvedPackageLimits()
}

// MARK: - Models

/// The only dependency source XForge can act on.
///
/// The enum exists (rather than the parser simply omitting `kind`) so callers can
/// state the assumption in code: local, file-system, registry and edited pins are
/// refused by `ResolvedPackageLockfile.read(data:)`, never represented here.
enum ResolvedPackageKind: String, Hashable, Sendable {
    case remoteSourceControl
}

/// One locked remote package.
///
/// `location` is **canonical**, not the raw string from the file: the parser
/// rebuilds it from the validated owner and name, so it is always
/// `https://github.com/<owner>/<name>` with no `.git` suffix and no trailing
/// slash. That makes it safe to compare, hash and turn into a directory name.
struct ResolvedPackagePin: Identifiable, Hashable, Sendable {
    /// SwiftPM's canonical package identity, always lower case.
    let identity: String
    /// Canonical `https://github.com/<owner>/<name>`.
    let location: String
    /// The 40-character Git commit SHA, normalized to lower case.
    let revision: String
    /// The resolved semantic version, when the pin is version-based.
    let version: String?
    /// Always `.remoteSourceControl`; kept explicit for callers and diagnostics.
    let kind: ResolvedPackageKind

    var id: String { identity }

    init(identity: String,
         location: String,
         revision: String,
         version: String?,
         kind: ResolvedPackageKind = .remoteSourceControl) {
        self.identity = identity
        self.location = location
        self.revision = revision
        self.version = version
        self.kind = kind
    }
}

/// A parsed GitHub repository, kept while validating so duplicate repositories are
/// detected independently of how a pin spells the owner's case.
struct ResolvedRepository: Hashable, Sendable {
    let owner: String
    let name: String
    /// `https://github.com/<owner>/<name>`, without `.git` or a trailing slash.
    let url: URL

    /// `owner/name` as written in the lockfile (GitHub is case-insensitive).
    var slug: String { "\(owner)/\(name)" }

    /// `owner/name` folded to lower case, for duplicate detection.
    var normalizedSlug: String { slug.lowercased() }
}

/// Where the pins array lived in the document.
///
/// v1 and v2 are written by SwiftPM as `object.pins`; v3 writes `pins` at the root.
/// Both are accepted for every schema version because tools in the wild emit both,
/// but a document containing both arrays is rejected rather than guessed at.
enum ResolvedPackageLayout: String, Sendable {
    case object
    case root
}

/// A parsed, validated `Package.resolved`.
struct ResolvedPackageLockfile: Sendable, Equatable {
    /// The declared schema version, always 1, 2 or 3.
    let schemaVersion: Int
    /// Pins in file order.
    let pins: [ResolvedPackagePin]
    /// The v3 `originHash`, when present. Not used for resolution.
    let originHash: String?
    let layout: ResolvedPackageLayout

    /// Identities in file order, for display.
    var identities: [String] { pins.map(\.identity) }

    /// The pin for `identity` (case-insensitive), if any.
    func pin(identity: String) -> ResolvedPackagePin? {
        let wanted = identity.lowercased()
        return pins.first { $0.identity == wanted }
    }

    // MARK: Reading

    /// Parse lockfile bytes the caller already holds. No network, no filesystem.
    static func read(data: Data,
                     limits: ResolvedPackageLimits = .default) throws -> ResolvedPackageLockfile {
        guard data.count <= limits.maxBytes else {
            throw ResolvedPackageError.tooLarge(actual: data.count, limit: limits.maxBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResolvedPackageError.notUTF8
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResolvedPackageError.notJSON("the file is empty")
        }
        try ensureDepth(text, limit: limits.maxJSONDepth)

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ResolvedPackageError.notJSON(error.localizedDescription)
        }
        guard let root = json as? [String: Any] else {
            throw ResolvedPackageError.malformedDocument("the top level is not a JSON object")
        }

        let object = try dictionary(root["object"], name: "object")
        let rootVersion = try schemaVersionValue(root["version"], name: "version")
        let objectVersion = try schemaVersionValue(object?["version"], name: "object.version")
        if let rootVersion, let objectVersion, rootVersion != objectVersion {
            throw ResolvedPackageError.contradictoryVersions(root: rootVersion, object: objectVersion)
        }
        guard let schemaVersion = rootVersion ?? objectVersion else {
            throw ResolvedPackageError.missingSchemaVersion
        }
        guard (1...3).contains(schemaVersion) else {
            throw ResolvedPackageError.unsupportedSchema(schemaVersion)
        }

        let objectPins = object?["pins"]
        let rootPins = root["pins"]
        let hasObjectPins = objectPins.map { !($0 is NSNull) } ?? false
        let hasRootPins = rootPins.map { !($0 is NSNull) } ?? false
        if hasObjectPins && hasRootPins {
            throw ResolvedPackageError.contradictoryPins
        }

        let rawPins: Any
        let layout: ResolvedPackageLayout
        if hasObjectPins {
            guard let value = objectPins else { throw ResolvedPackageError.missingPins }
            rawPins = value
            layout = .object
        } else if hasRootPins {
            guard let value = rootPins else { throw ResolvedPackageError.missingPins }
            rawPins = value
            layout = .root
        } else {
            throw ResolvedPackageError.missingPins
        }

        guard let pinValues = rawPins as? [Any] else {
            let name = layout == .object ? "object.pins" : "pins"
            throw ResolvedPackageError.malformedDocument("“\(name)” is not an array")
        }
        guard pinValues.count <= limits.maxPins else {
            throw ResolvedPackageError.tooManyPins(limit: limits.maxPins)
        }

        var pins: [ResolvedPackagePin] = []
        pins.reserveCapacity(pinValues.count)
        var identities = Set<String>()
        var repositories = Set<String>()
        for (index, value) in pinValues.enumerated() {
            let parsed = try parsePin(value, index: index,
                                      schemaVersion: schemaVersion, limits: limits)
            guard identities.insert(parsed.pin.identity).inserted else {
                throw ResolvedPackageError.duplicateIdentity(parsed.pin.identity)
            }
            guard repositories.insert(parsed.repository.normalizedSlug).inserted else {
                throw ResolvedPackageError.duplicateRepository(parsed.repository.slug)
            }
            pins.append(parsed.pin)
        }

        let originHash = try originHashValue(root["originHash"], limits: limits)
        return ResolvedPackageLockfile(
            schemaVersion: schemaVersion,
            pins: pins,
            originHash: originHash,
            layout: layout
        )
    }

    /// Read and parse the lockfile at `url`.
    ///
    /// `url` must be a `file:` URL. The guard is not cosmetic: `Data(contentsOf:)`
    /// would otherwise follow an `https:` URL and turn this into a network call.
    static func read(contentsOf url: URL,
                     limits: ResolvedPackageLimits = .default) throws -> ResolvedPackageLockfile {
        guard url.isFileURL else {
            throw ResolvedPackageError.notAFile(url.absoluteString)
        }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == false {
            throw ResolvedPackageError.notAFile(url.lastPathComponent)
        }
        if let size = values?.fileSize, size > limits.maxBytes {
            throw ResolvedPackageError.tooLarge(actual: size, limit: limits.maxBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ResolvedPackageError.unreadable(url.lastPathComponent)
        }
        return try read(data: data, limits: limits)
    }

    // MARK: Document helpers

    /// Reject documents nested deeper than `limit` before `JSONSerialization`
    /// recurses through them. A byte scan is enough: in JSON, `{`/`[` outside a
    /// string are the only things that open a level, and multi-byte UTF-8
    /// sequences never contain ASCII quote or backslash bytes.
    private static func ensureDepth(_ text: String, limit: Int) throws {
        guard limit > 0 else { throw ResolvedPackageError.tooDeep(limit: limit) }
        var depth = 0
        var inString = false
        var escaped = false
        for byte in text.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // backslash
                    escaped = true
                } else if byte == 0x22 { // quote
                    inString = false
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B, 0x5B: // { [
                    depth += 1
                    if depth > limit { throw ResolvedPackageError.tooDeep(limit: limit) }
                case 0x7D, 0x5D: // } ]
                    depth = max(0, depth - 1)
                default:
                    break
                }
            }
        }
    }

    private static func dictionary(_ value: Any?, name: String) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let dictionary = value as? [String: Any] else {
            throw ResolvedPackageError.malformedDocument("“\(name)” is not a JSON object")
        }
        return dictionary
    }

    private static func schemaVersionValue(_ value: Any?, name: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let version = integer(value) else {
            throw ResolvedPackageError.malformedDocument("“\(name)” must be a whole number")
        }
        return version
    }

    /// `JSONSerialization` represents booleans as `NSNumber`; a `true` schema
    /// version must not silently become `1`.
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double == double.rounded(),
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private static func originHashValue(_ value: Any?,
                                        limits: ResolvedPackageLimits) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let hash = value as? String else {
            throw ResolvedPackageError.malformedDocument("“originHash” is not a string")
        }
        guard hash.count <= limits.maxOriginHashLength else {
            throw ResolvedPackageError.malformedDocument(
                "“originHash” is longer than \(limits.maxOriginHashLength) characters")
        }
        guard !hash.isEmpty, hash.utf8.allSatisfy(isHexByte) else {
            throw ResolvedPackageError.malformedDocument("“originHash” is not a hexadecimal hash")
        }
        return hash.lowercased()
    }

    // MARK: Pin parsing

    private struct ParsedPin {
        let pin: ResolvedPackagePin
        let repository: ResolvedRepository
    }

    private static func parsePin(_ value: Any,
                                 index: Int,
                                 schemaVersion: Int,
                                 limits: ResolvedPackageLimits) throws -> ParsedPin {
        let label = "Pin #\(index + 1)"
        guard let pin = value as? [String: Any] else {
            throw ResolvedPackageError.malformedPin(index: index, reason: "it is not a JSON object")
        }

        let rawIdentity: String?
        let locationField: String
        if schemaVersion == 1 {
            rawIdentity = nil
            // Read for validation (and for the limit) even though v1's `package`
            // name is not part of the canonical pin model: it is a field the parser
            // promises to have checked.
            _ = try requiredString(pin["package"], field: "package",
                                   index: index, limit: limits.maxDisplayNameLength)
            locationField = "repositoryURL"
        } else {
            rawIdentity = try requiredString(pin["identity"], field: "identity",
                                             index: index, limit: limits.maxIdentityLength)
            locationField = "location"
        }

        let location = try requiredString(pin[locationField], field: locationField,
                                          index: index, limit: limits.maxLocationLength)

        // `kind` did not exist in v1, so it is only required for v2/v3. When it is
        // present in a v1 file it still has to say remoteSourceControl.
        if let kindValue = pin["kind"], !(kindValue is NSNull) {
            guard let kind = kindValue as? String else {
                throw ResolvedPackageError.malformedPin(index: index,
                                                        reason: "“kind” is not a string")
            }
            guard kind == "remoteSourceControl" else {
                throw ResolvedPackageError.unsupportedKind(pin: label, kind: excerpt(kind))
            }
        } else if schemaVersion >= 2 {
            throw ResolvedPackageError.malformedPin(
                index: index,
                reason: "it has no “kind”; only remoteSourceControl pins are supported")
        }

        let repository = try repository(from: location, pin: label, limits: limits)
        let identity = try makeIdentity(rawIdentity, repository: repository,
                                        index: index, limits: limits)

        guard let stateValue = pin["state"], !(stateValue is NSNull) else {
            throw ResolvedPackageError.malformedPin(index: index, reason: "“state” is missing")
        }
        guard let state = stateValue as? [String: Any] else {
            throw ResolvedPackageError.malformedPin(index: index,
                                                    reason: "“state” is not a JSON object")
        }

        let rawRevision = try requiredString(state["revision"], field: "state.revision",
                                             index: index, limit: 64)
        let revision = try validatedRevision(rawRevision, index: index)

        let version = try optionalString(state["version"], field: "state.version",
                                        index: index, limit: limits.maxVersionLength)
        if let version {
            guard !version.isEmpty else {
                throw ResolvedPackageError.malformedPin(index: index,
                                                        reason: "“state.version” is empty")
            }
            guard version.utf8.first.map(isDigitByte) == true,
                  version.utf8.allSatisfy(isVersionByte) else {
                throw ResolvedPackageError.malformedPin(
                    index: index,
                    reason: "“state.version” “\(excerpt(version))” is not a version")
            }
        }

        // A branch pin is still reproducible through `revision`; the branch name is
        // validated only so a malformed value is reported rather than ignored.
        if let branch = try optionalString(state["branch"], field: "state.branch",
                                           index: index, limit: limits.maxBranchLength) {
            guard !branch.isEmpty else {
                throw ResolvedPackageError.malformedPin(index: index,
                                                        reason: "“state.branch” is empty")
            }
            guard isValidBranch(branch) else {
                throw ResolvedPackageError.malformedPin(
                    index: index,
                    reason: "“state.branch” “\(excerpt(branch))” is not a valid branch name")
            }
        }

        return ParsedPin(
            pin: ResolvedPackagePin(
                identity: identity,
                location: repository.url.absoluteString,
                revision: revision,
                version: version
            ),
            repository: repository
        )
    }

    private static func requiredString(_ value: Any?,
                                       field: String,
                                       index: Int,
                                       limit: Int) throws -> String {
        guard let value, !(value is NSNull) else {
            throw ResolvedPackageError.malformedPin(index: index, reason: "“\(field)” is missing")
        }
        guard let string = value as? String else {
            throw ResolvedPackageError.malformedPin(index: index,
                                                    reason: "“\(field)” is not a string")
        }
        guard !string.isEmpty else {
            throw ResolvedPackageError.malformedPin(index: index, reason: "“\(field)” is empty")
        }
        guard string.count <= limit else {
            throw ResolvedPackageError.fieldTooLong(pin: "Pin #\(index + 1)",
                                                    field: field, limit: limit)
        }
        return string
    }

    private static func optionalString(_ value: Any?,
                                       field: String,
                                       index: Int,
                                       limit: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            throw ResolvedPackageError.malformedPin(index: index,
                                                    reason: "“\(field)” is not a string")
        }
        guard string.count <= limit else {
            throw ResolvedPackageError.fieldTooLong(pin: "Pin #\(index + 1)",
                                                    field: field, limit: limit)
        }
        return string
    }

    // MARK: Identity

    /// SwiftPM's v1 format has no `identity`, so the repository name — folded to
    /// lower case, exactly as SwiftPM derives it — becomes the identity.
    private static func makeIdentity(_ raw: String?,
                                     repository: ResolvedRepository,
                                     index: Int,
                                     limits: ResolvedPackageLimits) throws -> String {
        let candidate = raw ?? repository.name.lowercased()
        guard !candidate.isEmpty else {
            throw ResolvedPackageError.malformedPin(index: index,
                                                    reason: "it has no package identity")
        }
        guard candidate.count <= limits.maxIdentityLength else {
            throw ResolvedPackageError.fieldTooLong(pin: "Pin #\(index + 1)",
                                                    field: "identity",
                                                    limit: limits.maxIdentityLength)
        }
        guard candidate == candidate.lowercased() else {
            throw ResolvedPackageError.malformedPin(
                index: index,
                reason: "“identity” “\(excerpt(candidate))” must be lower case")
        }
        guard isValidIdentity(candidate) else {
            throw ResolvedPackageError.malformedPin(
                index: index,
                reason: "“identity” “\(excerpt(candidate))” contains unsupported characters")
        }
        return candidate
    }

    /// Lower-case ASCII letters, digits, `-`, `_` and `.`; must start with a letter
    /// or digit. Rejecting everything else keeps identities usable as directory
    /// names and keys without further escaping.
    private static func isValidIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isAlphanumericByte(first) else { return false }
        guard bytes.allSatisfy({ isAlphanumericByte($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }) else {
            return false
        }
        return !value.contains("..")
    }

    // MARK: Repository URLs

    /// Parse a pin's `location` / `repositoryURL`.
    ///
    /// Only `https://github.com/<owner>/<name>` (optionally `www.`, a trailing
    /// slash, or a `.git` suffix) is accepted. Everything else is refused by
    /// name — schemes, hosts, credentials, ports, queries, fragments, percent
    /// escapes and paths that point inside a repository — because these URLs are
    /// the only thing that will later be turned into fetch requests and directory
    /// names.
    private static func repository(from raw: String,
                                   pin: String,
                                   limits: ResolvedPackageLimits) throws -> ResolvedRepository {
        guard raw.count <= limits.maxLocationLength else {
            throw ResolvedPackageError.fieldTooLong(pin: pin, field: "location",
                                                    limit: limits.maxLocationLength)
        }
        let invalid: (String) -> ResolvedPackageError = { reason in
            .invalidRepositoryURL(pin: pin, value: excerpt(raw), reason: reason)
        }

        guard raw.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
            throw invalid("it contains whitespace, control characters or non-ASCII characters")
        }
        guard !raw.contains("%") else {
            throw invalid("percent-encoded characters are not accepted")
        }
        guard !raw.contains("\\") else {
            throw invalid("it contains a backslash")
        }
        guard let components = URLComponents(string: raw) else {
            throw invalid("it is not a URL")
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw invalid("it has no scheme; use https://github.com/owner/repository")
        }
        guard scheme == "https" else {
            let reason = scheme == "http"
                ? "plain http is not allowed; use https"
                : "the “\(scheme)” scheme is not supported; use https"
            throw invalid(reason)
        }
        guard components.user == nil, components.password == nil else {
            throw invalid("it contains credentials")
        }
        guard let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw invalid("only public github.com repositories are supported")
        }
        guard components.port == nil else {
            throw invalid("it specifies a port")
        }
        guard components.query == nil, components.fragment == nil else {
            throw invalid("it has a query or fragment")
        }

        guard components.path.hasPrefix("/") else {
            throw invalid("it does not name an owner and a repository")
        }
        var parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw invalid("it does not name an owner and a repository")
        }
        guard parts.count == 2 else {
            throw invalid("it points inside a repository; use the repository root")
        }

        let owner = parts[0]
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") {
            name.removeLast(4)
        }
        guard isValidGitHubOwner(owner) else {
            throw invalid("“\(excerpt(owner, limit: 60))” is not a valid GitHub owner name")
        }
        guard isValidGitHubName(name) else {
            throw invalid("“\(excerpt(name, limit: 60))” is not a valid GitHub repository name")
        }
        guard let url = URL(string: "https://github.com/\(owner)/\(name)") else {
            throw invalid("it cannot be represented as a canonical https URL")
        }
        return ResolvedRepository(owner: owner, name: name, url: url)
    }

    /// 1–39 characters, letters, digits and inner hyphens only.
    private static func isValidGitHubOwner(_ owner: String) -> Bool {
        let bytes = Array(owner.utf8)
        guard (1...39).contains(bytes.count) else { return false }
        guard isAlphanumericByte(bytes[0]), isAlphanumericByte(bytes[bytes.count - 1]) else {
            return false
        }
        return bytes.allSatisfy { isAlphanumericByte($0) || $0 == 0x2D }
    }

    /// 1–100 characters from GitHub's repository-name alphabet.
    private static func isValidGitHubName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...100).contains(bytes.count) else { return false }
        guard name != ".", name != ".." else { return false }
        return bytes.allSatisfy {
            isAlphanumericByte($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E
        }
    }

    // MARK: Revision, version, branch

    private static func validatedRevision(_ raw: String, index: Int) throws -> String {
        let bytes = Array(raw.utf8)
        guard bytes.count == 40, bytes.allSatisfy(isHexByte) else {
            throw ResolvedPackageError.invalidRevision(pin: "Pin #\(index + 1)",
                                                       value: excerpt(raw, limit: 64))
        }
        return raw.lowercased()
    }

    /// Semver characters only, starting with a digit. The parser does not compare
    /// versions; it just refuses strings that could not be one.
    private static func isVersionByte(_ byte: UInt8) -> Bool {
        isAlphanumericByte(byte) || byte == 0x2E || byte == 0x2B || byte == 0x2D
    }

    private static func isValidBranch(_ branch: String) -> Bool {
        let forbidden = " ~^:?*[\\"
        guard branch.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else { return false }
        guard !branch.contains(".."), !branch.hasPrefix("-"), branch != "@" else {
            return false
        }
        return !branch.contains(where: { forbidden.contains($0) })
    }

    // MARK: Byte helpers

    private static func isAlphanumericByte(_ byte: UInt8) -> Bool {
        isDigitByte(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isDigitByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        isDigitByte(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// Keep error messages readable when the offending value is a megabyte long.
    private static func excerpt(_ value: String, limit: Int = 120) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

// MARK: - Errors

/// Every way a lockfile can be refused, with the detail needed to fix it.
enum ResolvedPackageError: LocalizedError, Equatable, Sendable {
    /// The URL was not a local file. Remote URLs are refused so parsing can never
    /// turn into a network request.
    case notAFile(String)
    case unreadable(String)
    case tooLarge(actual: Int, limit: Int)
    case notUTF8
    case notJSON(String)
    case tooDeep(limit: Int)
    case malformedDocument(String)
    case missingSchemaVersion
    case unsupportedSchema(Int)
    case contradictoryVersions(root: Int, object: Int)
    case contradictoryPins
    case missingPins
    case malformedPin(index: Int, reason: String)
    case tooManyPins(limit: Int)
    case duplicateIdentity(String)
    case duplicateRepository(String)
    case unsupportedKind(pin: String, kind: String)
    case invalidRevision(pin: String, value: String)
    case invalidRepositoryURL(pin: String, value: String, reason: String)
    case fieldTooLong(pin: String, field: String, limit: Int)

    var errorDescription: String? {
        switch self {
        case .notAFile(let location):
            return "“\(location)” is not a local file. A Package.resolved must be read "
                + "from disk; XForge does not fetch lockfiles over the network."
        case .unreadable(let name):
            return "“\(name)” could not be read."
        case .tooLarge(let actual, let limit):
            return "The lockfile is \(actual) bytes, larger than the \(limit)-byte limit."
        case .notUTF8:
            return "The lockfile is not valid UTF-8."
        case .notJSON(let detail):
            return "The lockfile is not valid JSON: \(detail)"
        case .tooDeep(let limit):
            return "The lockfile is nested more than \(limit) levels deep."
        case .malformedDocument(let reason):
            return "The lockfile is not a usable Package.resolved: \(reason)."
        case .missingSchemaVersion:
            return "The lockfile has no “version” field; XForge reads Package.resolved "
                + "versions 1, 2 and 3."
        case .unsupportedSchema(let version):
            return "Package.resolved version \(version) is not supported; XForge reads "
                + "versions 1, 2 and 3."
        case .contradictoryVersions(let root, let object):
            return "The lockfile declares version \(root) at the top level but \(object) "
                + "inside “object”."
        case .contradictoryPins:
            return "The lockfile has pins both at the top level and inside “object”; it is "
                + "not possible to tell which list is authoritative."
        case .missingPins:
            return "The lockfile contains no pins array."
        case .malformedPin(let index, let reason):
            return "Pin #\(index + 1) is invalid: \(reason)."
        case .tooManyPins(let limit):
            return "The lockfile contains more than \(limit) pins."
        case .duplicateIdentity(let identity):
            return "Two pins resolve to the same package identity “\(identity)”."
        case .duplicateRepository(let slug):
            return "Two pins point at the same repository “\(slug)”."
        case .unsupportedKind(let pin, let kind):
            return "\(pin) is a \(kind) dependency; only remoteSourceControl pins are "
                + "supported."
        case .invalidRevision(let pin, let value):
            return "\(pin) is not pinned to a 40-character Git commit SHA (“\(value)”)."
        case .invalidRepositoryURL(let pin, let value, let reason):
            return "\(pin) has an unusable repository URL “\(value)”: \(reason)."
        case .fieldTooLong(let pin, let field, let limit):
            return "\(pin) has a “\(field)” longer than \(limit) characters."
        }
    }
}
