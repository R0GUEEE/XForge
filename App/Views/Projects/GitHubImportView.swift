import SwiftUI

/// Import a public GitHub repository at one revision.
///
/// The form is deliberately small: repository, optional ref, name. Everything the
/// import will do is said on the screen — a ZIP of one revision, no history, no
/// submodules, public repositories only — because an archive is not a clone and the
/// difference matters the first time someone looks for `git log`.
struct GitHubImportView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GitHubImportModel()
    @State private var query = ""
    @State private var ref = ""
    @State private var name = ""
    @State private var orgId = ""

    /// Names already in `ProjectStore`: used both to keep a derived name unique and
    /// to refuse a typed duplicate instead of silently renaming it.
    let existingNames: [String]
    let onImported: (Project) -> Void

    private var repository: GitHubRepository? {
        try? GitHubRepository.parse(query, explicitRef: ref)
    }

    private var parseError: String? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, repository == nil else {
            return nil
        }
        do {
            _ = try GitHubRepository.parse(query, explicitRef: ref)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var suggestedName: String {
        guard let repository else { return "" }
        return GitHubSnapshotImporter.sanitizedProjectName(repository.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                repositorySection
                projectSection
                if model.isImporting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.progress.isEmpty ? "Importing…" : model.progress)
                                .font(.footnote)
                        }
                    }
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                readOnlyNotice
            }
            .navigationTitle("Import from GitHub")
            .onAppear {
                if orgId.isEmpty { orgId = preferences.defaultOrgId }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { startImport() }
                        .disabled(repository == nil || model.isImporting)
                }
            }
            .interactiveDismissDisabled(model.isImporting)
        }
    }

    // MARK: - Sections

    private var repositorySection: some View {
        Section {
            TextField("owner/repo or github.com URL", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Ref — branch, tag or commit (optional)", text: $ref)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if let repository {
                LabeledContent("Repository", value: repository.slug)
                LabeledContent("Revision", value: repository.ref ?? "default branch")
            } else if let parseError {
                Label(parseError, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Repository")
        } footer: {
            Text("XForge downloads GitHub's ZIP of a single revision — there is no git "
                 + "history and no submodules. Public repositories only, up to 256 MB.")
        }
    }

    private var projectSection: some View {
        Section {
            TextField(suggestedName.isEmpty ? "Name" : suggestedName, text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Organization Identifier", text: $orgId)
                .keyboardType(.alphabet)
                .autocorrectionDisabled()
        } header: {
            Text("Project")
        } footer: {
            Text("The name is used for the folder in XForge. Leave it empty to use the "
                 + "repository name. An Xcode project's organization identifier is taken "
                 + "from its main app target when one is found.")
        }
    }

    private var readOnlyNotice: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xcode projects are read-only")
                        .font(.headline)
                    Text("A repository with an .xcodeproj is added with its target list and "
                         + "files so it can be inspected. XForge has no Xcode-project build "
                         + "driver, so it cannot build that project or produce an IPA. A "
                         + "repository whose root has a Package.swift is imported as a "
                         + "Swift package instead.")
                        .font(.footnote)
                }
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 4)
        } header: {
            Text("What gets imported")
        }
    }

    // MARK: - Actions

    private func startImport() {
        guard let repository, !model.isImporting else { return }
        let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GitHubSnapshotImporter.Request(
            repository: repository,
            organizationIdentifier: orgId,
            preferredName: typedName.isEmpty ? nil : typedName,
            existingNames: Set(existingNames)
        )

        Task {
            if let project = await model.run(request) {
                onImported(project)
                dismiss()
            }
        }
    }
}

/// Runs one import and publishes its progress.
///
/// A small `@MainActor` model rather than view state: the importer's progress
/// callback is `@Sendable` and fires off the main actor, so it needs an object it
/// can hop back to. The class is actor-isolated, therefore `Sendable`, which is
/// what makes the capture legal under strict concurrency.
@MainActor
final class GitHubImportModel: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?

    /// Returns the imported project, or `nil` when the import failed (the reason is
    /// published in `error`) or was cancelled.
    func run(_ request: GitHubSnapshotImporter.Request) async -> Project? {
        guard !isImporting else { return nil }
        isImporting = true
        error = nil
        progress = GitHubSnapshotImporter.Phase.downloading.message
        defer {
            isImporting = false
            progress = ""
        }

        do {
            let result = try await GitHubSnapshotImporter.importSnapshot(request) { [weak self] phase in
                Task { @MainActor in
                    self?.progress = phase.message
                }
            }
            return result.project
        } catch is CancellationError {
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
