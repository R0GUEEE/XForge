import SwiftUI

/// Edit a project's `Package.swift` manifest.
struct ManifestEditorView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let onSave: (String) -> Void

    init(project: Project, initial: String?, onSave: @escaping (String) -> Void) {
        self.project = project
        self.onSave = onSave
        _text = State(initialValue: initial ?? Self.template(name: project.name, org: project.organizationIdentifier))
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
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .padding(8)
            }
            .navigationTitle("Package.swift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
    }
}
