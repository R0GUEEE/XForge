import Foundation

/// Resolution of XForge's own published release assets.
///
/// The darwin Swift SDK is published under its **own release series**
/// (`darwin-sdk-<n>`, produced by `.github/workflows/build-darwin-sdk.yml`), so
/// `https://github.com/<repo>/releases/latest/download/<asset>` does not find it —
/// `latest` points at the newest release of any kind (usually an XForge IPA),
/// which 404s. This asks the API for the newest matching release instead.
enum XForgeReleases {
    static let repository = "R0GUEEE/XForge"
    static let darwinSDKTagPrefix = "darwin-sdk-"
    static let darwinSDKAssetName = "darwin.artifactbundle.zip"

    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct Release: Decodable, Equatable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    /// Pick the named asset from the newest release whose tag starts with `prefix`.
    ///
    /// Pure so it can be unit-tested against fixture JSON. The GitHub releases
    /// endpoint returns newest-first, so the first match is the newest.
    static func findAsset(in releases: [Release], tagPrefix: String, assetName: String) -> URL? {
        releases
            .first { $0.tagName.hasPrefix(tagPrefix) }?
            .assets.first { $0.name == assetName }?
            .browserDownloadURL
    }

    /// Fetch the release list and resolve an asset.
    static func assetURL(tagPrefix: String, assetName: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("XForge", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.http(response)
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let url = findAsset(in: releases, tagPrefix: tagPrefix, assetName: assetName) else {
            throw DownloadError.assetNotFound("\(assetName) in any \(tagPrefix)* release")
        }
        return url
    }

    /// The newest published darwin Swift SDK bundle.
    static func darwinSDKURL() async throws -> URL {
        try await assetURL(tagPrefix: darwinSDKTagPrefix, assetName: darwinSDKAssetName)
    }
}
