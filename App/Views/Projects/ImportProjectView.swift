import SwiftUI
import UniformTypeIdentifiers

/// Import an existing package from the Files app.
///
/// This used to `git clone` into the embedded Linux. There is no `git` in an iOS
/// process and no process to run it in, so the import is now what an app can
/// actually do: copy a folder the user picked into the projects directory. A
/// repository can still be fetched with an app that does have git — Working Copy,
/// or Files' own "Download" on a zip — and imported from there.
struct ImportProjectView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var picked: URL?
    @State private var name = ""
    @State private var orgId = ""
    @State private var isImporting = false
    @State private var error: String?

    let onImported: (Project) -> Void

    private var derivedName: String {
        if !name.isEmpty { return name }
        guard let picked else { return "" }
        return picked.lastPathComponent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder") {
                    Button {
                        showingPicker = true
                    } label: {
                        Label(picked?.lastPathComponent ?? "Choose a project folder…",
                              systemImage: "folder")
                    }
                    if let picked {
                        Text(picked.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Organization Identifier", text: $orgId)
                        .keyboardType(.alphabet).autocorrectionDisabled()
                }

                Section {
                    if isImporting {
                        HStack { ProgressView(); Text("Copying into XForge…") }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("The folder must contain a Package.swift with a Sources/ directory. "
                         + "It is copied, not moved: the original stays where it is.")
                }
            }
            .navigationTitle("Import a project")
            .onAppear {
                if orgId.isEmpty { orgId = preferences.defaultOrgId }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { startImport() }
                        .disabled(picked == nil || isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            picked = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }

    @State private var showingPicker = false

    private func startImport() {
        guard let source = picked else { return }
        isImporting = true
        error = nil
        let projectName = derivedName
        let org = orgId

        Task {
            defer { isImporting = false }
            do {
                let validated = try Project.validatedName(projectName)
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }

                let manifest = source.appendingPathComponent("Package.swift")
                guard FileManager.default.fileExists(atPath: manifest.path) else {
                    throw ImportError.notAPackage(source.lastPathComponent)
                }

                let project = Project(
                    name: validated,
                    organizationIdentifier: org,
                    rootPath: Project.path(forValidatedName: validated)
                )
                let destination = project.rootURL
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw ImportError.alreadyExists(validated)
                }
                try FileManager.default.copyItem(at: source, to: destination)

                onImported(project)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum ImportError: LocalizedError {
    case notAPackage(String)
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .notAPackage(let name):
            return "\(name) has no Package.swift, so it is not a Swift package."
        case .alreadyExists(let name):
            return "A project named \(name) already exists. Rename it, or remove the existing one first."
        }
    }
}
