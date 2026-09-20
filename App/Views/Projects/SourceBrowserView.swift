import SwiftUI

@MainActor
enum GuestProjectFiles {
    struct File: Identifiable, Hashable {
        let id: String
        let name: String
        let relativePath: String
        var contents: String
    }

    static func load(project: Project, sourcesOnly: Bool) async throws -> [File] {
        guard project.hasSafeRootPath else { throw ProjectValidationError.unsafePath }

        let vm = XForgeEnvironment.makeVM()
        let root = sourcesOnly ? "\(project.rootPath)/Sources" : project.rootPath
        let output = GuestFileOutputCollector()
        let status = try await vm.run(
            "find \(GuestShell.quote(root)) -type f -print 2>/dev/null | sort",
            environment: nil
        ) { output.append($0) }
        guard status == 0 else { throw GuestProjectFileError.listFailed(status) }

        let paths = output.value
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(project.rootPath + "/") }

        var files: [File] = []
        for path in paths {
            let relativePath = String(path.dropFirst(project.rootPath.count + 1))
            guard !relativePath.contains("\n") else { continue }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("xforge-source-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try await vm.copyOut(guestPath: path, to: temporaryURL)
            guard let contents = try? String(contentsOf: temporaryURL, encoding: .utf8) else {
                continue
            }
            files.append(File(
                id: relativePath,
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                contents: contents
            ))
        }
        return files
    }

    static func load(relativePath: String, project: Project) async throws -> File {
        guard project.hasSafeRootPath else { throw ProjectValidationError.unsafePath }
        guard isSafe(relativePath: relativePath) else {
            throw GuestProjectFileError.unsafeRelativePath
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await XForgeEnvironment.makeVM().copyOut(
            guestPath: "\(project.rootPath)/\(relativePath)",
            to: temporaryURL
        )
        let contents = try String(contentsOf: temporaryURL, encoding: .utf8)
        return File(
            id: relativePath,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            contents: contents
        )
    }

    static func save(_ contents: String, file: File, project: Project) async throws {
        guard project.hasSafeRootPath else { throw ProjectValidationError.unsafePath }
        guard isSafe(relativePath: file.relativePath) else {
            throw GuestProjectFileError.unsafeRelativePath
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try contents.write(to: temporaryURL, atomically: true, encoding: .utf8)
        try await XForgeEnvironment.makeVM().copyIn(
            hostURL: temporaryURL,
            to: "\(project.rootPath)/\(file.relativePath)"
        )
    }

    private static func isSafe(relativePath: String) -> Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.split(separator: "/").contains("..")
            && !relativePath.contains("\n")
    }
}

private final class GuestFileOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum GuestProjectFileError: LocalizedError {
    case listFailed(Int32)
    case unsafeRelativePath

    var errorDescription: String? {
        switch self {
        case .listFailed(let status):
            return "Could not list project files (exit \(status))."
        case .unsafeRelativePath:
            return "The selected file is outside the project."
        }
    }
}

struct SourceBrowserView: View {
    let project: Project
    @State private var files: [GuestProjectFiles.File] = []
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
            files = try await GuestProjectFiles.load(project: project, sourcesOnly: true)
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

    let file: GuestProjectFiles.File
    let project: Project
    let onSave: (String) -> Void

    init(
        file: GuestProjectFiles.File,
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
            try await GuestProjectFiles.save(text, file: file, project: project)
            onSave(text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
