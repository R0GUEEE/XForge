import Foundation
import Combine

/// One downloadable item with live state.
struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var url: URL
    var state: State = .idle
    var destination: URL?
    var error: String?

    enum State: String, Equatable {
        case idle, downloading, done, failed
    }
}

/// Real host-side downloads with state tracking. Files land in `folder` (default the
/// app's Documents/downloads), which is shared into the guest Linux at `/host/downloads`.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    let folder: URL

    init(folder: URL? = nil) {
        let base = folder ?? XForgeEnvironment.downloadsDirectory
        self.folder = base
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func enqueue(name: String, url: URL) -> UUID {
        if let existing = items.firstIndex(where: { $0.name == name }) {
            items[existing].url = url
            items[existing].state = .idle
            items[existing].error = nil
            return items[existing].id
        }
        let item = DownloadItem(name: name, url: url)
        items.append(item)
        return item.id
    }

    func start(_ id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .downloading
        items[idx].error = nil
        do {
            let dest = folder.appendingPathComponent(items[idx].name)
            let url = try await DownloadManager.download(items[idx].url, to: dest) { _ in }
            items[idx].state = .done
            items[idx].destination = url
        } catch {
            items[idx].state = .failed
            items[idx].error = error.localizedDescription
        }
    }

    func retry(_ id: UUID) async {
        await start(id)
    }

    func remove(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let dest = items[idx].destination {
            try? FileManager.default.removeItem(at: dest)
        }
        items.remove(at: idx)
    }

    /// Download `url` to `destination`, replacing anything already there.
    /// One-shot helper for services that don't need the observable list.
    @discardableResult
    nonisolated static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse(url)
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw DownloadError.http(status: http.statusCode, url: url)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        progress(1.0)
        return destination
    }
}

enum DownloadError: LocalizedError {
    case http(status: Int, url: URL)
    case invalidResponse(URL)
    case notDownloaded
    case assetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let url):
            return "The server returned HTTP \(status) for \(url.lastPathComponent)."
        case .invalidResponse(let url):
            return "Unexpected response from \(url.host ?? "the server")."
        case .notDownloaded:
            return "The file has not finished downloading."
        case .assetNotFound(let what):
            return "No published release asset found: \(what)."
        }
    }
}
