import SwiftUI

/// Sheet for importing an existing SwiftPM package from a git URL.
struct ImportProjectView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var gitURL = ""
    @State private var name = ""
    @State private var orgId = ""
    @State private var isImporting = false
    @State private var error: String?

    let onImported: (Project) -> Void

    private var derivedName: String {
        name.isEmpty ? (gitURL.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? "Imported") : name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    TextField("https://github.com/you/repo.git", text: $gitURL)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Organization Identifier", text: $orgId)
                        .keyboardType(.alphabet).autocorrectionDisabled()
                }
                Section {
                    if isImporting {
                        HStack { ProgressView(); Text("Cloning into embedded Linux…") }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import from Git")
            .onAppear {
                if orgId.isEmpty { orgId = preferences.defaultOrgId }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { startImport() }
                        .disabled(gitURL.isEmpty || isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func startImport() {
        isImporting = true
        error = nil
        let url = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = orgId
        Task {
            defer { isImporting = false }
            do {
                let projectName = try Project.validatedName(derivedName)
                // Clone into the guest; without this the project path does not
                // exist and every later build step fails.
                let vm = XForgeEnvironment.makeVM()
                if !vm.isBooted { try await vm.boot() }
                let path = Project.path(forValidatedName: projectName)
                let status = try await vm.run(
                    "mkdir -p \(GuestShell.quote(Project.projectsRoot)) && "
                    + "rm -rf \(GuestShell.quote(path)) && "
                    + "git clone --depth 1 -- \(GuestShell.quote(url)) \(GuestShell.quote(path))",
                    environment: nil
                ) { _ in }
                guard status == 0 else {
                    throw ImportError.cloneFailed(status, url)
                }
                onImported(Project(name: projectName,
                                   organizationIdentifier: org,
                                   rootPath: path))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum ImportError: LocalizedError {
    case cloneFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let status, let url):
            return "git clone failed (exit \(status)) for \(url). Check the URL, and that the "
                + "embedded Linux has network access."
        }
    }
}
