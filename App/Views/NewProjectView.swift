import SwiftUI

struct NewProjectView: View {
    enum Template: String, CaseIterable, Identifiable {
        case swiftUI = "SwiftUI App"
        case uikit = "UIKit App"
        case library = "Swift Package Library"
        case appClip = "App Clip"
        case empty = "Empty Package"
        var id: String { rawValue }
        var summary: String {
            switch self {
            case .swiftUI: return "SwiftUI lifecycle app with a ContentView."
            case .uikit: return "UIKit app with an AppDelegate + scene delegate."
            case .library: return "A reusable SwiftPM library target."
            case .appClip: return "A SwiftUI App Clip — small, focused experience."
            case .empty: return "Just a bare package manifest."
            }
        }
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
                    Text(template.summary)
                        .font(.caption).foregroundStyle(.secondary)
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
