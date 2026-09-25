import Foundation

/// Failures of a network download.
///
/// This used to live in `DownloadManager`, which served the Downloads screen and
/// the Xcode.xip staging flow — both of which went with the guest. The error type
/// stayed because two things still download: `XForgeReleases` (release metadata and
/// asset URLs) and `NativeSDK` (the Darwin SDK bundle). Its cases are the ones those
/// two raise; the `.notDownloaded` case went with the download manager that could
/// report a partial file.
enum DownloadError: LocalizedError {
    case http(status: Int, url: URL)
    case invalidResponse(URL)
    case assetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let url):
            return "The server returned HTTP \(status) for \(url.lastPathComponent)."
        case .invalidResponse(let url):
            return "Unexpected response from \(url.host ?? "the server")."
        case .assetNotFound(let what):
            return "No published release asset found: \(what)."
        }
    }
}
