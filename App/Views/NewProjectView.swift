import SwiftUI

struct NewProjectView: View {
    enum Template: String, CaseIterable, Identifiable {
        case swiftUI = "SwiftUI App"
        case empty = "Empty Package"
        var id: String { rawValue }
    }

    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var name = "HelloWorld"
    @State private var orgId = ""
    @State private var template: Template = .swiftUI

    let onCreated: (Project) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Organization Identifier", text: $orgId)
                        .keyboardType(.alphabet)
                        .autocorrectionDisabled()
                    Picker("Template", selection: $template) {
                        ForEach(Template.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .navigationTitle("New Project")
            .onAppear {
                if orgId.isEmpty { orgId = preferences.defaultOrgId }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let project = Project(
                            name: name,
                            organizationIdentifier: orgId,
                            rootPath: "/root/projects/\(name)"
                        )
                        onCreated(project)
                        dismiss()
                    }
                    .disabled(name.isEmpty || orgId.isEmpty)
                }
            }
        }
    }
}
