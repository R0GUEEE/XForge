import SwiftUI

/// Sheet for importing an existing SwiftPM package from a git URL.
struct ImportProjectView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var gitURL = ""
    @State private var name = ""
    @State private var orgId = ""
    @State private var isImporting = false

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
        let project = Project(name: derivedName, organizationIdentifier: orgId, rootPath: "/root/projects/\(derivedName)")
        // The git clone runs in the embedded Linux via the build executor.
        onImported(project)
        isImporting = false
        dismiss()
    }
}
