import SwiftUI
import UIKit

/// Thread-safe accumulator for guest listing output, because LinuxVM streams from
/// a background tailer and Swift 6 does not allow a captured mutable local in an
/// @Sendable callback.
private final class GuestListingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ chunk: String) {
        lock.lock(); value += chunk; lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// A guest-side file browser, modelled after iSH's shell file browser. It lists
/// the actual Alpine filesystem rather than the app's host sandbox, so folders
/// such as `/root`, `/tmp`, `/host` and project files are visible where Linux
/// sees them. File actions are deliberately small and safe: copy the path or
/// share a host-visible file.
struct GuestFileBrowserView: View {
    @State private var path: String
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var vm: (any LinuxVM)?
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        var id: String { path }
    }

    init(path: String = "/") { _path = State(initialValue: path) }

    var body: some View {
        NavigationStack {
            List {
                if path != "/" {
                    Button { navigate(to: parent(path)) } label: {
                        Label("..", systemImage: "arrow.turn.up.left")
                    }
                }
                if loading { ProgressView("Reading \(path)…") }
                if let error {
                    ContentUnavailableViewCompat(title: "Could Not Read Folder",
                                                  systemImage: "exclamationmark.triangle",
                                                  message: error)
                }
                ForEach(entries) { entry in row(entry) }
            }
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        if entry.isDirectory {
            Button { navigate(to: entry.path) } label: {
                Label(entry.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Image(systemName: icon(entry.name)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(entry.name).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { UIPasteboard.general.string = entry.path } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy path")
            }
        }
    }

    private func navigate(to value: String) {
        path = value.hasPrefix("/") ? value : "/" + value
        Task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let guest = vm ?? XForgeEnvironment.makeVM()
            vm = guest
            try await guest.boot()
            let box = GuestListingBox()
            // BusyBox find (the root's /usr/bin/find applet) does not support
            // GNU `-printf`, so use the shell's glob expansion plus `stat` — no
            // dependency on a GNU find build that plain Alpine does not ship.
            let listing = """
            for item in \(GuestShell.quote(path))/* \(GuestShell.quote(path))/.[!.]*; do
                [ -e "$item" ] || [ -L "$item" ] || continue
                if [ -d "$item" ]; then kind=d; else kind=f; fi
                size=$(stat -c %s "$item" 2>/dev/null || echo 0)
                printf '%s\\t%s\\t%s\\n' "$kind" "$item" "$size"
            done | sort -k2
            """
            let status = try await guest.run(listing, environment: nil) { chunk in
                box.append(chunk)
            }
            guard status == 0 else { throw BrowserError.readFailed }
            entries = box.text.split(separator: "\\n").compactMap { line in
                let parts = line.split(separator: "\\t", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { return nil }
                let full = parts[1]
                return Entry(name: URL(fileURLWithPath: full).lastPathComponent,
                             path: full, isDirectory: parts[0] == "d", size: Int64(parts[2]) ?? 0)
            }
        } catch let caught {
            self.error = caught.localizedDescription
        }
        loading = false
    }

    private func parent(_ value: String) -> String {
        let p = (value as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    private func icon(_ name: String) -> String {
        if name.hasSuffix(".ipa") { return "app.badge" }
        if name.hasSuffix(".zip") || name.hasSuffix(".tar.gz") { return "archivebox" }
        if name.hasSuffix(".dylib") { return "shippingbox" }
        return "doc"
    }

    enum BrowserError: LocalizedError {
        case readFailed
        var errorDescription: String? { "The guest could not list this folder." }
    }
}
