import SwiftUI

/// Tab 2 — build a selected project with the on-device pipeline.
struct BuildTab: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var selection: Project?

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No Projects",
                        systemImage: "hammer",
                        message: "Create a project first, then build it here."
                    )
                } else {
                    BuildPipelineView(project: selection ?? store.projects[0])
                }
            }
            .navigationTitle("Build")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if store.projects.count > 1 {
                    Picker("Project", selection: $selection) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
            }
        }
    }
}
