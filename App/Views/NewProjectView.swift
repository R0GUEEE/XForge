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
    @State private var creating = false
    @State private var error: String?

    let onCreated: (Project) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Organization Identifier", text: $orgId)
                        .keyboardType(.alphabet)
                        .autocorrectionDisabled()
                    Picker("Template", selection: $template) {
                        ForEach(Template.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text(template.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if creating {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Creating the project in the embedded Linux…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
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
                    Button("Create") { create() }
                        .disabled(name.isEmpty || orgId.isEmpty || creating)
                }
            }
        }
    }

    /// Actually create the project inside the guest (`xtool new`), rather than
    /// recording a path that never exists — every later build depends on it.
    private func create() {
        creating = true
        error = nil
        let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = orgId.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { creating = false }
            do {
                let executor = XForgeEnvironment.makeExecutor()
                let project = try await executor.createProject(
                    named: projectName, organizationIdentifier: org)
                onCreated(project)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
