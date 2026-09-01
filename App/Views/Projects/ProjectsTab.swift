import SwiftUI

/// Tab 1 — author and manage SwiftPM projects.
struct ProjectsTab: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var selection: Project?
    @State private var showingNewProject = false
    @State private var importURL = ""

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(store.projects) { project in
                    NavigationLink(value: project) {
                        ProjectRow(project: project)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            store.remove(project)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.remove(store.projects[i]) }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showingNewProject = true } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    Menu {
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import from Git", systemImage: "arrow.down.circle")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project)
            }
            .sheet(isPresented: $showingNewProject) {
                NewProjectView { project in
                    store.add(project)
                    selection = project
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportProjectView { project in
                    store.add(project)
                    selection = project
                }
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No Projects",
                        systemImage: "folder.badge.plus",
                        message: "Create or import a SwiftPM package to get started."
                    )
                }
            }
        }
    }

    @State private var showingImport = false
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name).font(.headline)
            Text("\(project.organizationIdentifier) · arm64-apple-ios")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
