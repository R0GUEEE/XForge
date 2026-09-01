import SwiftUI

/// Browse the SwiftPM package's `Sources/` tree and view/edit source files.
struct SourceBrowserView: View {
    let project: Project
    @State private var files: [SourceFile] = []

    struct SourceFile: Identifiable, Hashable {
        let id: String        // relative path
        let name: String
        var contents: String
    }

    var body: some View {
        List {
            Section("Sources") {
                ForEach(files) { file in
                    NavigationLink(value: file) {
                        Label(file.name, systemImage: "swift")
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .navigationDestination(for: SourceFile.self) { file in
            SourceEditorView(file: file) { updated in
                if let idx = files.firstIndex(where: { $0.id == file.id }) {
                    files[idx].contents = updated
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        // Seed with a default target file; real listing comes from the VM file access.
        if files.isEmpty {
            files = [SourceFile(
                id: "Sources/\(project.name)/\(project.name).swift",
                name: "\(project.name).swift",
                contents: SourceEditorView.template(name: project.name)
            )]
        }
    }
}

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let file: SourceBrowserView.SourceFile
    let onSave: (String) -> Void

    init(file: SourceBrowserView.SourceFile, onSave: @escaping (String) -> Void) {
        self.file = file
        self.onSave = onSave
        _text = State(initialValue: file.contents)
    }

    static func template(name: String) -> String {
        """
        import SwiftUI

        public struct \(name)App: App {
            public var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                Text("Hello, world!")
            }
        }
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(8)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(text); dismiss() }
            }
        }
    }
}
