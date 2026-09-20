import SwiftUI

/// Browse every readable file in the project's real guest filesystem.
struct FileBrowserView: View {
    let project: Project
    @State private var files: [GuestProjectFiles.File] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView("Loading files…")
            } else if let error {
                ContentUnavailableViewCompat(
                    title: "Could Not Load Files",
                    systemImage: "exclamationmark.triangle",
                    message: error
                )
            } else if files.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Empty Project",
                    systemImage: "folder",
                    message: "No readable files were found."
                )
            } else {
                Section("Package") {
                    ForEach(files) { file in
                        NavigationLink(value: file) {
                            Label(file.relativePath, systemImage: symbol(for: file))
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .navigationDestination(for: GuestProjectFiles.File.self) { file in
            SourceEditorView(file: file, project: project) { updated in
                if let index = files.firstIndex(where: { $0.id == file.id }) {
                    files[index].contents = updated
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await GuestProjectFiles.load(project: project, sourcesOnly: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func symbol(for file: GuestProjectFiles.File) -> String {
        file.name.hasSuffix(".swift") ? "swift" : "doc"
    }
}
