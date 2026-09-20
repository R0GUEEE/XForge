import Foundation
import Combine

/// One downloadable item with live state.
struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var url: URL
    var state: State = .idle
    var progress: Double = 0
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
            items[existing].progress = 0
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
        items[idx].progress = 0
        items[idx].error = nil
        let name = items[idx].name
        let url = items[idx].url
        do {
            let dest = folder.appendingPathComponent(name)
            let saved = try await DownloadManager.download(url, to: dest) { fraction in
                // Called from the session's delegate queue.
                Task { @MainActor [weak self] in
                    guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[i].progress = fraction
                }
            }
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].state = .done
                items[i].progress = 1
                items[i].destination = saved
            }
        } catch {
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].state = .failed
                items[i].error = error.localizedDescription
            }
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

    /// Download `url` to `destination`, replacing anything already there and
    /// reporting byte progress.
    ///
    /// Retries on failure: a 456 MB download dropped its connection 22 seconds
    /// in on a real device, and one dropped connection is not a reason to make
    /// the user start over. A server-side answer (404/403) is not retried --
    /// it will not change.
    @discardableResult
    nonisolated static func download(
        _ url: URL,
        to destination: URL,
        attempts: Int = 3,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lastError: Error = DownloadError.invalidResponse(url)
        for attempt in 1...max(1, attempts) {
            do {
                let temp = try await ProgressDownload(url: url, progress: progress).start()

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                progress(1.0)
                return destination
            } catch let error as DownloadError {
                throw error
            } catch {
                lastError = error
                XForgeLog.note("download: attempt \(attempt)/\(attempts) of "
                    + "\(url.lastPathComponent) failed: \(error.localizedDescription)")
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        throw lastError
    }
}

/// A single download that reports progress.
///
/// `URLSession.download(from:)` cannot report anything until it is finished, and
/// the files here are hundreds of megabytes — so a delegate does the work and
/// this object keeps the session, the delegate and the continuation together
/// for as long as the transfer lasts.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let progress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var finished = false

    init(url: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.progress = progress
    }

    /// Returns the finished download's temporary file, which the caller owns.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` is deleted when this returns, so take it now.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.http(status: http.statusCode, url: url)))
            return
        }
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-\(UUID().uuidString).download")
        do {
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Success already went through didFinishDownloadingTo; a non-nil error
        // here is the transfer giving up (connection lost, timeout, ...).
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(DownloadError.invalidResponse(url)))
        }
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
