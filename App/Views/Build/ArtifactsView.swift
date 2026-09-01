import SwiftUI

/// Built `.ipa` artifacts: export or delete from the staging area.
struct ArtifactsView: View {
    @State private var artifacts: [BuildArtifact] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if artifacts.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Artifacts",
                    systemImage: "shippingbox",
                    message: "Built .ipa files appear here, ready to export or install."
                )
            }
            ForEach(artifacts) { artifact in
                HStack {
                    Image(systemName: "app.badge")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.name).font(.headline)
                        Text("\(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file)) · \(artifact.date.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: artifact.url) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        delete(artifact)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Artifacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { reload() }
    }

    private func reload() {
        artifacts = XForgeEnvironment.stagedArtifacts()
    }

    private func delete(_ artifact: BuildArtifact) {
        try? FileManager.default.removeItem(at: artifact.url)
        reload()
    }
}
