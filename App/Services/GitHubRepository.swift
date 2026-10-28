import Foundation

/// A public GitHub repository plus the revision a snapshot import should fetch.
///
/// Import is an *archive download of one revision*, not a clone: there is no `git`
/// in an iOS process, GitHub serves `https://github.com/<owner>/<repo>/archive/…zip`
/// over plain HTTPS, and an archive is exactly what the feature promises — the
/// files at one commit, without history. Parsing the URL is therefore a security
/// boundary: everything that reaches a file path or a request URL is validated
/// here, not in the view.
///
/// Accepted input:
///  - `https://github.com/owner/repo`, with or without a trailing `.git` or `/`
///  - `git@github.com:owner/repo.git`
///  - `owner/repo` (the shorthand people paste from a README)
///  - any of the above with `@ref` appended (`owner/repo@v1.2.3`)
///  - `?ref=<ref>` in the query, for refs that contain `/`
///  - `/tree/<ref>` when the ref is a single path component
///
/// `tree`/`blob` URLs whose ref contains slashes are rejected rather than guessed
/// at: `tree/release/6.0` is either branch `release` and folder `6.0`, or branch
/// `release/6.0`, and picking one would import the wrong revision. The UI has a
/// separate ref field for that case.
struct GitHubRepository: Hashable, Sendable {
    let owner: String
    let name: String
    /// Branch, tag or commit. `nil` means the repository's default branch.
    let ref: String?

    /// `owner/repository`, for storage and display.
    var slug: String { "\(owner)/\(name)" }

    /// The archive URL for this revision.
    ///
    /// `HEAD` is GitHub's spelling for "the default branch", and using it (rather
    /// than asking the API which branch that is) keeps the default-branch import to
    /// a single request. A ref is percent-encoded for the path but its `/` is kept,
    /// so `feature/login` survives.
    var archiveURL: URL {
        let revision = ref.map(Self.pathEncoded) ?? "HEAD"
        // Every component is validated ASCII, so this cannot fail; the fallback is
        // still a real URL rather than a crash.
        return URL(string: "https://github.com/\(owner)/\(name)/archive/\(revision).zip")
            ?? URL(string: "https://github.com/\(owner)/\(name)/archive/HEAD.zip")!
    }

    // MARK: - Parsing

    /// Parse user input. `explicitRef` (the UI's separate Ref field) wins over a
    /// ref found in the text, because typing in one field is a deliberate choice and
    /// a stale `@ref` in the pasted URL should not silently override it.
    static func parse(_ input: String, explicitRef: String? = nil) throws -> GitHubRepository {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubRepositoryError.emptyInput }
        guard trimmed.count <= 400 else { throw GitHubRepositoryError.notARepository(trimmed) }

        var repository: GitHubRepository

        if let scp = scpStylePath(trimmed) {
            repository = try parseSlug(scp)
        } else if let components = URLComponents(string: trimmed), let scheme = components.scheme {
            guard scheme.lowercased() == "https" || scheme.lowercased() == "http" else {
                throw GitHubRepositoryError.unsupportedScheme(scheme)
            }
            guard let host = components.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" else {
                throw GitHubRepositoryError.notGitHub
            }

            let parts = components.path.split(separator: "/").map(String.init)
            repository = try parsePathComponents(parts)

            if let queryRef = components.queryItems?.first(where: { $0.name == "ref" })?.value,
               !queryRef.isEmpty {
                repository = GitHubRepository(
                    owner: repository.owner,
                    name: repository.name,
                    ref: try validatedRef(queryRef)
                )
            }
        } else {
            var path = trimmed
            for prefix in ["github.com/", "www.github.com/"] where path.lowercased().hasPrefix(prefix) {
                path = String(path.dropFirst(prefix.count))
                break
            }
            repository = try parseSlug(path)
        }

        if let explicitRef = explicitRef?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitRef.isEmpty {
            repository = GitHubRepository(
                owner: repository.owner,
                name: repository.name,
                ref: try validatedRef(explicitRef)
            )
        }

        return repository
    }

    /// `git@github.com:owner/repo.git` → `owner/repo.git`.
    private static func scpStylePath(_ text: String) -> String? {
        let prefix = "git@github.com:"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    /// `owner/repo[@ref]`, optionally with `/tree/<ref>` already stripped.
    private static func parseSlug(_ path: String) throws -> GitHubRepository {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return try parsePathComponents(parts)
    }

    private static func parsePathComponents(_ rawParts: [String]) throws -> GitHubRepository {
        // `https://github.com/owner/repo.git` — the `.git` suffix is a clone URL,
        // not part of the repository's name.
        let parts = rawParts
        guard parts.count >= 2 else {
            throw GitHubRepositoryError.notARepository(parts.joined(separator: "/"))
        }

        guard let owner = validatedOwner(parts[0]) else {
            throw GitHubRepositoryError.invalidOwner(parts[0])
        }
        var repositoryName = parts[1]

        // `owner/repo@v1.2.3`: split the ref off the last component. Done before
        // stripping `.git` so `repo.git@v1` also works.
        var inlineRef: String?
        if let at = repositoryName.lastIndex(of: "@"), at != repositoryName.startIndex {
            inlineRef = String(repositoryName[repositoryName.index(after: at)...])
            repositoryName = String(repositoryName[..<at])
        }
        if repositoryName.lowercased().hasSuffix(".git") {
            repositoryName = String(repositoryName.dropLast(4))
        }
        guard let name = validatedName(repositoryName) else {
            throw GitHubRepositoryError.invalidName(repositoryName)
        }

        var ref = inlineRef
        if parts.count >= 4, ["tree", "blob", "commit"].contains(parts[2].lowercased()) {
            let remainder = Array(parts[3...])
            guard remainder.count == 1 else {
                throw GitHubRepositoryError.ambiguousRef(remainder.joined(separator: "/"))
            }
            ref = remainder[0]
        } else if parts.count > 2, !parts[2].isEmpty {
            // `/issues`, `/releases`, `/archive` … are pages, not revisions. Only a
            // repository and an optional revision are meaningful here.
            throw GitHubRepositoryError.notARepository(parts.joined(separator: "/"))
        }

        return GitHubRepository(
            owner: owner,
            name: name,
            ref: try ref.map(validatedRef)
        )
    }

    private static func validatedOwner(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 39,
              raw.first != "-", raw.last != "-",
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }
        return raw
    }

    private static func validatedName(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 100,
              raw != ".", raw != "..",
              !raw.hasPrefix("."),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            return nil
        }
        return raw
    }

    /// Refs are git ref names: no control characters, no spaces, no `..`, and no
    /// leading/trailing slash or dot. A commit SHA passes the same check, which is
    /// why there is no separate "is this a SHA" path.
    static func validatedRef(_ raw: String) throws -> String {
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        guard !ref.isEmpty, ref.count <= 200,
              !ref.hasPrefix("/"), !ref.hasSuffix("/"),
              !ref.hasPrefix("."), !ref.hasPrefix("-"), !ref.hasSuffix("."),
              !ref.contains(".."), !ref.contains("//"),
              ref.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GitHubRepositoryError.invalidRef(ref)
        }
        return ref
    }

    private static func pathEncoded(_ ref: String) -> String {
        // `.urlPathAllowed` permits `?`, `#` and other delimiters; this set is the
        // exact alphabet `validatedRef` accepts plus the `/` a ref may contain.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
    }

    // MARK: - Revision identity

    /// Ask the public API which commit a ref points at, so the project record keeps
    /// the immutable identity even after the branch moves.
    ///
    /// Best effort by design: the import itself does not depend on this, the
    /// unauthenticated API is rate-limited, and a network hiccup here must not fail
    /// an import that already downloaded a valid archive.
    static func resolveCommit(for repository: GitHubRepository,
                              session: URLSession = .shared) async -> String? {
        let revision = repository.ref ?? "HEAD"
        guard var components = URLComponents(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/commits") else {
            return nil
        }
        // `sha=` is a query parameter so refs containing slashes remain one ref
        // instead of being interpreted as a nested path by the API router.
        components.queryItems = [URLQueryItem(name: "sha", value: revision)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            let sha: String?
            if let object = json as? [String: Any] {
                sha = object["sha"] as? String
            } else if let commits = json as? [[String: Any]] {
                sha = commits.first?["sha"] as? String
            } else {
                sha = nil
            }
            guard let sha, sha.count == 40 else { return nil }
            return sha
        } catch {
            return nil
        }
    }
}

enum GitHubRepositoryError: LocalizedError, Equatable {
    case emptyInput
    case notGitHub
    case unsupportedScheme(String)
    case notARepository(String)
    case invalidOwner(String)
    case invalidName(String)
    case invalidRef(String)
    case ambiguousRef(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a GitHub repository, for example owner/repo."
        case .notGitHub:
            return "Only github.com repositories can be imported."
        case .unsupportedScheme(let scheme):
            return "The repository URL uses \(scheme); paste an https://github.com/... URL."
        case .notARepository(let path):
            return "“\(path)” is not a GitHub repository. Use owner/repo."
        case .invalidOwner(let owner):
            return "“\(owner)” is not a valid GitHub owner name."
        case .invalidName(let name):
            return "“\(name)” is not a valid GitHub repository name."
        case .invalidRef(let ref):
            return "“\(ref)” is not a valid branch, tag or commit."
        case .ambiguousRef(let ref):
            return "The ref in this URL contains slashes (“\(ref)”). Enter that ref in the "
                + "Ref field so it is not confused with a folder path."
        }
    }
}
