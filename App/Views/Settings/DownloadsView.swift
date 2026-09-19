import SwiftUI

/// Download hub for the build artifacts that are *not* bundled with the app.
///
/// The Alpine rootfs ships inside the app, so it never appears here as a download.
/// The darwin Swift SDK is published under its own release series (`darwin-sdk-*`),
/// so its URL is resolved through the GitHub API rather than
/// `releases/latest/download/…` (which 404s — that was the old bug).
@MainActor
struct DownloadsView: View {
    @StateObject private var manager = DownloadManager()
    @State private var rootfsInstalled = false
    @State private var resolving = false
    @State private var error: String?

    var body: some View {
        List {
            bundledSection

            Section {
                Button { addSDK() } label: {
                    Label("Darwin Swift SDK", systemImage: "externaldrive")
                }
                .disabled(resolving)
                Button { addXtool() } label: {
                    Label("xtool binary", systemImage: "hammer")
                }
            } header: {
                Text("Build Artifacts")
            } footer: {
                Text("Downloaded into the app's Documents/downloads folder, which the "
                     + "embedded Linux sees at /host/downloads.")
            }

            if !manager.items.isEmpty {
                Section("Downloads") {
                    ForEach(manager.items) { item in
                        row(item)
                    }
                }
            }

            if resolving {
                Section { HStack { ProgressView().controlSize(.small); Text("Resolving the latest release…").font(.footnote) } }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
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
        .task { rootfsInstalled = RootfsInstaller.isInstalled(in: XForgeEnvironment.rootsDirectory) }
    }

    private var bundledSection: some View {
        Section {
            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(rootfsInstalled ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alpine aarch64 rootfs").font(.headline)
                    Text(rootfsInstalled
                         ? "Installed — imported from the copy bundled in the app"
                         : "Bundled in the app · installed on first boot, no download")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Bundled")
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
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                    if let dest = item.destination {
                        NavigationLink { SandboxBrowserView(root: dest.deletingLastPathComponent()) } label: {
                            Label("Reveal", systemImage: "folder")
                        }
                    }
                case .failed:
                    Button { Task { await manager.retry(item.id) } } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let error = item.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func addSDK() {
        resolving = true
        error = nil
        Task {
            defer { resolving = false }
            do {
                let url = try await XForgeReleases.darwinSDKURL()
                let id = manager.enqueue(name: XForgeReleases.darwinSDKAssetName, url: url)
                await manager.start(id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addXtool() {
        guard let url = URL(string: ToolchainManager.xtoolDownloadURL) else { return }
        let id = manager.enqueue(name: "xtool-aarch64.AppImage", url: url)
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
