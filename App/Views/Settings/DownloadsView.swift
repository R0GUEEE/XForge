import SwiftUI

/// Download hub: fetch the build artifacts (darwin SDK, embedded Linux rootfs, xtool),
/// watch progress, reveal the file in the sandbox, and stage it where the shell can use it.
struct DownloadsView: View {
    @StateObject private var manager = DownloadManager()

    var body: some View {
        List {
            if manager.items.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Downloads",
                    systemImage: "arrow.down.circle",
                    message: "Add the build artifacts below and they'll download here with progress."
                )
            }
            ForEach(manager.items) { item in
                row(item)
            }
            quickAddSection
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SandboxBrowserView(root: manager.folder)
                } label: {
                    Label("Folder", systemImage: "folder")
                }
            }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stateIcon(item)
                Text(item.name).font(.headline)
                Spacer()
                switch item.state {
                case .idle:
                    Button { Task { await manager.start(item.id) } } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                case .downloading:
                    ProgressView().controlSize(.small)
                case .done:
                    if let dest = item.destination {
                        Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        NavigationLink { SandboxBrowserView(root: dest.deletingLastPathComponent()) } label: {
                            Label("Reveal in Files", systemImage: "folder")
                        }
                        Button("Stage to shell") {
                            Task { _ = try? manager.stageToGuest(item) }
                        }
                        .buttonStyle(.bordered)
                    }
                case .failed:
                    Button { Task { await manager.retry(item.id) } } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let error = item.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var quickAddSection: some View {
        Section("Build Artifacts") {
            Button { addSDK() } label: { Label("Darwin Swift SDK (214 MB)", systemImage: "externaldrive") }
            Button { addLinux() } label: { Label("Embedded Linux rootfs", systemImage: "apple.terminal") }
            Button { addXtool() } label: { Label("xtool binary", systemImage: "hammer") }
        }
    }

    private func addSDK() {
        let id = manager.enqueue(
            name: "darwin.artifactbundle.zip",
            url: URL(string: "https://github.com/R0GUEEE/XForge/releases/latest/download/darwin.artifactbundle.zip")!
        )
        Task { await manager.start(id) }
    }
    private func addLinux() {
        // The rootfs is assembled in CI; this mirrors its published location when available.
        let id = manager.enqueue(
            name: "alpine-rootfs.tar.xz",
            url: URL(string: "https://github.com/R0GUEEE/XForge/releases/latest/download/alpine-rootfs.tar.xz")!
        )
        Task { await manager.start(id) }
    }
    private func addXtool() {
        let id = manager.enqueue(
            name: "xtool-aarch64.AppImage",
            url: URL(string: "https://github.com/xtool-org/xtool/releases/download/1.17.0/xtool-aarch64.AppImage")!
        )
        Task { await manager.start(id) }
    }

    private func stateIcon(_ item: DownloadItem) -> Image {
        switch item.state {
        case .idle: return Image(systemName: "circle.dashed")
        case .downloading: return Image(systemName: "arrow.down.circle")
        case .done: return Image(systemName: "checkmark.circle.fill")
        case .failed: return Image(systemName: "xmark.circle.fill")
        }
    }
}
