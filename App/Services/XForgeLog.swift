import Foundation

/// On-device diagnostics for the embedded Linux.
///
/// Two writers, one file:
///
///  - **The engine.** Its `printk` — every kernel message, including the one
///    `die()` prints immediately before it calls `abort()` — goes to file
///    descriptor 555 (`kernel/log.c`'s dprintf handler). Nothing in an iOS app
///    opens that descriptor, so without `prepare()` a guest crash kills the app
///    and leaves no trace anywhere.
///  - **This app.** `note(_:)` writes a breadcrumb through the same bridge call,
///    so the last line of the file says how far an install got before the app
///    disappeared — which is the difference between "it crashes" and a bug
///    report.
///
/// Plain file writes, no `os_log`: the point is a file the user can share from
/// the app, and `os_log` messages are only readable with a console attached.
enum XForgeLog {
    /// `<Documents>/logs` — the same container the Files app shows.
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("engine.log") }

    /// Rotate past this size so the file stays shareable.
    static let maxBytes = 512 * 1024

    /// Point the bridge (and therefore the engine) at the log file.
    /// Safe to call repeatedly; also safe to call after the guest has booted.
    @discardableResult
    static func prepare() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

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

        return url.path.withCString { xf_ish_set_log_file($0) } == 0
    }

    /// Append one breadcrumb line, timestamped by the bridge.
    static func note(_ line: String) {
        _ = line.withCString { xf_ish_log($0) }
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
