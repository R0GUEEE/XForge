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
/// app's Documents/downloads), which is also where the guest shell sees staged files
/// (mounted as /root/downloads in the embedded Linux).
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    let folder: URL

    init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.folder = base.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func enqueue(name: String, url: URL) -> UUID {
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
            let (temp, response) = try await URLSession.shared.download(from: items[idx].url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.http(response)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            items[idx].state = .done
            items[idx].destination = dest
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

    /// Forward a downloaded file into the guest's view of the filesystem so the shell
    /// can reach it at /root/downloads/<name> (and the build executor's copyIn can push
    /// it into the running guest).
    func stageToGuest(_ item: DownloadItem) throws -> URL {
        guard let source = item.destination ?? folder.appendingPathComponent(item.name) else {
            throw DownloadError.notDownloaded
        }
        let guestDir = XForgeEnvironment.embeddedRoot
            .appendingPathComponent("root/downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: guestDir, withIntermediateDirectories: true)
        let dest = guestDir.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
}

enum DownloadError: LocalizedError {
    case http(URLResponse?)
    case notDownloaded
    var errorDescription: String? {
        switch self {
        case .http: return "The server returned an error."
        case .notDownloaded: return "The file has not finished downloading."
        }
    }
}
