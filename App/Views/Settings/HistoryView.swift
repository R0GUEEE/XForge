import SwiftUI

/// Past build attempts, with export and delete.
struct HistoryView: View {
    @StateObject private var store = BuildHistoryStore()

    var body: some View {
        List {
            if store.records.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Builds Yet",
                    systemImage: "clock.arrow.circlepath",
                    message: "Run a build and it'll appear here."
                )
            }
            ForEach(store.records) { record in
                HStack {
                    Image(systemName: record.result == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(record.result == "success" ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.projectName).font(.headline)
                        Text("\(record.configuration) · build \(record.buildNumber) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = record.error {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let name = record.artifactName {
                        ShareLink(item: stagingURL(for: name)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.remove(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Build History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !store.records.isEmpty {
                    Button("Clear All", role: .destructive) { store.clear() }
                }
            }
        }
    }

    private func stagingURL(for name: String) -> URL {
        XForgeEnvironment.stagingDirectory.appendingPathComponent(name)
    }
}
