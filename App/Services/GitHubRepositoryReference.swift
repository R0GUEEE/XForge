import Foundation

/// A public GitHub repository at a particular revision, as typed by the user.
///
/// This is deliberately a *reference to a snapshot*, not a clone: XForge has no
/// `git` (there is no process to run it in), so import fetches GitHub's zipball
/// for one revision. The parser is the one place that decides what a user-entered
/// URL means, and it accepts only shapes that identify a repository:
///
///  - `https://github.com/owner/repo`
///  - `https://github.com/owner/repo.git`
///  - `https://github.com/owner/repo/tree/<ref>` (a branch, tag or commit page)
///  - `owner/repo` and `owner/repo@<ref>` (shorthand)
///
/// Anything else — a host that is not GitHub, an issue or pull-request link, a
/// `blob` link that names a file rather than a revision — is rejected rather than
/// guessed at.
struct GitHubRepositoryReference: Equatable, Hashable, Sendable {
    let owner: String
    let repository: String
    /// Branch, tag or commit. `nil` means GitHub's default branch.
    let ref: String?

    var fullName: String { "\(owner)/\(repository)" }

    /// `owner/repo@ref`, or just `owner/repo` for the default branch.
    var displayName: String {
        guard let ref else { return fullName }
        return "\(fullName)@\(ref)"
    }

    /// GitHub's zipball endpoint for this revision.
    ///
    /// `codeload.github.com` is the host `api.github.com/repos/…/zipball/…`
    /// redirects to. Asking it directly avoids the API's unauthenticated rate
    /// limit, which is 60 requests an hour per IP and would otherwise make import
    /// fail with a 403 that has nothing to do with the repository. `HEAD` is
    /// GitHub's name for the default branch in this endpoint.
    ///
    /// The URL is built from values `parse` has already restricted to ASCII
    /// letters, digits and `-_.` (owner/repository) and `-_.~/` (ref), so there is
    /// nothing left for percent-encoding to do and a ref containing `/` stays a
    /// path separator, which is how GitHub names branches like `feature/login`.
    var zipballURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "codeload.github.com"
        components.path = "/\(owner)/\(repository)/zipball/\(ref ?? "HEAD")"
        // Every component is validated, so the URL is representable; the fallback
        // exists only to keep this a total function.
        return components.url ?? URL(string: "https://codeload.github.com")!
    }

    // MARK: - Parsing

    static func parse(_ input: String,
                      ref explicitRef: String? = nil) throws -> GitHubRepositoryReference {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubImportError.invalidRepositoryURL }

        var owner: String
        var repository: String
        var linkRef: String?

        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased() else {
                throw GitHubImportError.invalidRepositoryURL
            }
            guard scheme == "https" else {
                throw GitHubImportError.insecureRepositoryURL
            }
            guard host == "github.com" || host == "www.github.com" else {
                throw GitHubImportError.unsupportedHost(host)
            }
            guard components.query == nil, components.fragment == nil,
                  components.user == nil, components.password == nil else {
                throw GitHubImportError.unsupportedLink
            }

            let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard path.count >= 2 else {
                throw GitHubImportError.missingRepositoryName
            }
            owner = path[0]
            repository = path[1]
            repository = try strippedGitSuffix(repository)

            if path.count > 2 {
                // `/tree/<ref…>` is a link to a revision, and a ref may itself
                // contain slashes, so the rest of the path is the ref. `blob` links
                // name a file inside the tree, which cannot be told apart from a
                // ref containing slashes, so they are refused rather than truncated
                // to something the user did not ask for.
                guard path[2] == "tree" else {
                    throw GitHubImportError.unsupportedLink
                }
                guard path.count > 3 else {
                    throw GitHubImportError.missingRef
                }
                linkRef = path[3...].joined(separator: "/")
            }
        } else {
            var shorthand = trimmed
            if let at = shorthand.lastIndex(of: "@") {
                linkRef = String(shorthand[shorthand.index(after: at)...])
                shorthand = String(shorthand[..<at])
            }
            let parts = shorthand.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw GitHubImportError.missingRepositoryName
            }
            owner = String(parts[0])
            repository = try strippedGitSuffix(String(parts[1]))
        }

        guard isValidOwner(owner) else {
            throw GitHubImportError.invalidOwner(owner)
        }
        guard isValidRepository(repository) else {
            throw GitHubImportError.invalidRepositoryName(repository)
        }

        let requestedRef = try combinedRef(explicit: explicitRef, link: linkRef)
        return GitHubRepositoryReference(owner: owner, repository: repository, ref: requestedRef)
    }

    // MARK: - Validation

    /// Git refs are restricted to what can safely appear in a URL path and on a
    /// filesystem, and traversal is refused outright. GitHub itself applies
    /// `git check-ref-format`; this is the subset an importer needs to be safe.
    static func validatedRef(_ value: String) throws -> String {
        let ref = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard !ref.isEmpty, ref.count <= 200,
              !ref.hasPrefix("-"), !ref.hasPrefix("/"), !ref.hasSuffix("/"),
              !ref.hasPrefix("."), !ref.hasSuffix("."),
              !ref.contains(".."), !ref.contains("//"), !ref.contains("\\"),
              !ref.hasSuffix(".lock"),
              ref.unicodeScalars.allSatisfy(allowed.contains),
              ref.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw GitHubImportError.invalidRef(value)
        }
        return ref
    }

    private static func combinedRef(explicit: String?, link: String?) throws -> String? {
        var explicitRef: String?
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            explicitRef = try validatedRef(explicit)
        }
        var linkRef: String?
        if let link, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            linkRef = try validatedRef(link)
        }
        if let explicitRef, let linkRef, explicitRef != linkRef {
            throw GitHubImportError.conflictingRef(explicitRef, linkRef)
        }
        return explicitRef ?? linkRef
    }

    private static func strippedGitSuffix(_ value: String) throws -> String {
        let name = value.hasSuffix(".git") ? String(value.dropLast(4)) : value
        guard !name.isEmpty else { throw GitHubImportError.missingRepositoryName }
        return name
    }

    private static func isValidOwner(_ owner: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return !owner.isEmpty && owner.count <= 100
            && owner != "." && owner != ".."
            && owner.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidRepository(_ repository: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !repository.isEmpty && repository.count <= 100
            && repository != "." && repository != ".."
            && repository.unicodeScalars.allSatisfy(allowed.contains)
    }
}
