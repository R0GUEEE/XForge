import SwiftUI

/// Tab 2 — build a selected project with the on-device pipeline.
struct BuildTab: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var selection: Project?

    private var selectedProject: Project? {
        guard let selection else { return nil }
        return store.projects.first { $0.id == selection.id }
    }

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
                    let project = selectedProject ?? store.projects[0]
                    BuildPipelineView(project: project)
                        .id(project.id)
                }
            }
            .navigationTitle("Build")
            .onChange(of: store.projects) { projects in
                if let selection,
                   !projects.contains(where: { $0.id == selection.id }) {
                    self.selection = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ArtifactsView()
                    } label: {
                        Label("Artifacts", systemImage: "shippingbox")
                    }
                }
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
}
