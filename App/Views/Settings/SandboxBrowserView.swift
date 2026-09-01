import SwiftUI
import UniformTypeIdentifiers

/// A real file browser over the app's sandbox. Drill into folders via NavigationLink;
/// files get a Share/Delete context menu. This gives actual folder access to everything
/// the app downloads or stages (embedded-linux, staging, downloads…).
struct SandboxBrowserView: View {
    let root: URL
    @State private var entries: [Entry] = []
    @State private var isLoading = false

    struct Entry: Identifiable, Hashable {
        let id: String
        let url: URL
        let name: String
        let isDir: Bool
        let size: Int64
    }

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("Loading…") }
            } else if entries.isEmpty {
                ContentUnavailableViewCompat(title: "Empty Folder", systemImage: "folder", message: "Nothing here.")
            } else {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
        }
        .navigationTitle(root.lastPathComponent)
        .navigationDestination(for: URL.self) { url in
            SandboxBrowserView(root: url)
        }
        .task { load() }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        if entry.isDir {
            NavigationLink(value: entry.url) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        if let count = subitemCount(entry.url) {
                            Text("\(count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            HStack {
                Image(systemName: icon(for: entry.name)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(entry.name)
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: entry.url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .swipeActions {
                Button(role: .destructive) {
                    delete(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }
        entries = urls.compactMap { url -> Entry? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let size = values?.fileSize.map(Int64.init) ?? 0
            return Entry(id: url.path, url: url, name: url.lastPathComponent, isDir: isDir, size: size)
        }.sorted { $0.isDir && !$1.isDir ? true : ($0.name < $1.name) }
    }

    private func subitemCount(_ dir: URL) -> Int? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count
    }

    private func icon(for name: String) -> String {
        if name.hasSuffix(".zip") || name.hasSuffix(".tar.xz") { return "archivebox" }
        if name.hasSuffix(".ipa") { return "app.badge" }
        if name.hasSuffix(".dylib") || name.hasSuffix(".AppImage") { return "shippingbox" }
        return "doc"
    }

    private func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        load()
    }
}
