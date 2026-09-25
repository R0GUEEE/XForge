import SwiftUI

/// Edit the project's Package.swift.
struct ManifestEditorView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    let onSave: (String) -> Void

    init(project: Project, initial: String?, onSave: @escaping (String) -> Void) {
        self.project = project
        self.onSave = onSave
        _text = State(initialValue: initial ?? "")
    }

    static func template(name: String, org: String) -> String {
        """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.iOS(.v16)],
            products: [
                .library(name: "\(name)", targets: ["\(name)"])
            ],
            targets: [
                .target(
                    name: "\(name)",
                    path: "Sources/\(name)"
                )
            ]
        )
        """
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    ProgressView("Loading Package.swift…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
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
            }
            .navigationTitle("Package.swift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(loading || saving)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            text = try await ProjectFiles.load(
                relativePath: "Package.swift",
                project: project
            ).contents
        } catch {
            self.error = error.localizedDescription
            if text.isEmpty {
                text = Self.template(
                    name: project.name,
                    org: project.organizationIdentifier
                )
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let file = ProjectFiles.File(
                id: "Package.swift",
                name: "Package.swift",
                relativePath: "Package.swift",
                contents: text
            )
            try await ProjectFiles.save(text, file: file, project: project)
            onSave(text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
