import SwiftUI

/// Browse and edit the project's Swift sources.
///
/// The files are ordinary files in the app container, read through
/// `ProjectFiles`: the guest filesystem they used to live in is gone.
struct SourceBrowserView: View {
    let project: Project
    @State private var files: [ProjectFiles.File] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView("Loading sources…")
            } else if let error {
                ContentUnavailableViewCompat(
                    title: "Could Not Load Sources",
                    systemImage: "exclamationmark.triangle",
                    message: error
                )
            } else if files.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Source Files",
                    systemImage: "doc",
                    message: "The project has no readable files under Sources."
                )
            } else {
                Section("Sources") {
                    ForEach(files) { file in
                        NavigationLink(value: file) {
                            Label(file.relativePath, systemImage: "swift")
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .navigationDestination(for: ProjectFiles.File.self) { file in
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
            files = try await ProjectFiles.load(project: project, sourcesOnly: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    let file: ProjectFiles.File
    let project: Project
    let onSave: (String) -> Void

    init(
        file: ProjectFiles.File,
        project: Project,
        onSave: @escaping (String) -> Void
    ) {
        self.file = file
        self.project = project
        self.onSave = onSave
        _text = State(initialValue: file.contents)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(8)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(saving)
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await ProjectFiles.save(text, file: file, project: project)
            onSave(text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
