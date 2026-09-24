import Foundation

/// On-device diagnostics.
///
/// Plain file writes, no `os_log`: the point is a file the user can share from the
/// app, and `os_log` messages are only readable with a console attached.
///
/// The engine that used to share this file — the embedded Linux, whose `printk`
/// went to file descriptor 555 through the ish bridge — is gone, so this is now
/// only XForge's own breadcrumb trail.
enum XForgeLog {
    /// `<Documents>/logs` — the same container the Files app shows.
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("xforge.log") }

    /// Rotate past this size so the file stays shareable.
    static let maxBytes = 512 * 1024

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Create the log directory and rotate an oversized log.
    ///
    /// Kept as a separate step from `note(_:)` so the directory exists before the
    /// first breadcrumb, and so a caller that wants the log path can ask for it
    /// without writing anything.
    @discardableResult
    static func prepare() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int,
           size > maxBytes {
            // Keep the tail: what precedes a crash is worth more than the start.
            let tail = (try? String(contentsOf: url, encoding: .utf8))?.suffix(maxBytes / 2)
            try? fm.removeItem(at: url)
            if let tail {
                try? String(tail).write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return true
    }

    /// Append one timestamped breadcrumb line.
    ///
    /// Best effort by design: a diagnostic that can fail a build is worse than a
    /// diagnostic that is missing a line.
    static func note(_ line: String) {
        let entry = "\(timestamp.string(from: Date())) \(line)\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            _ = prepare()
            try? entry.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(entry.utf8))
#if DEBUG
        print("[XForge] \(line)")
#endif
    }

    /// The log as text (empty when nothing has been written yet).
    static func text() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func byteCount() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
