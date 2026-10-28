import SwiftUI

/// Tab 1 — author and manage SwiftPM projects.
///
/// Navigation is driven by an explicit `path` rather than `List(selection:)`:
/// binding a selection made row taps update the selection instead of pushing the
/// detail view, so a project could not be opened. The same path lets a freshly
/// created or imported project open by itself.
struct ProjectsTab: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var path: [Project] = []
    @State private var showingNewProject = false
    @State private var showingImport = false
    @State private var showingGitHubImport = false
    @State private var showingGitHubImport = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                    // A snapshot, not a clone: the sheet says so in its own words.
                    Button { showingGitHubImport = true } label: {
                        Label("Import GitHub snapshot", systemImage: "arrow.down.circle")
                    }
                    Menu {
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import from Files", systemImage: "folder")
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
                    path.append(project)
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportProjectView { project in
                    store.add(project)
                    path.append(project)
                }
            }
            .sheet(isPresented: $showingGitHubImport) {
                GitHubImportView(existingNames: store.projects.map(\.name)) { project in
                    // Same path as every other import: the record is persisted by the
                    // store, then the new project opens by itself.
                    store.add(project)
                    path.append(project)
                }
            }
            .sheet(isPresented: $showingGitHubImport) {
                GitHubImportView { project in
                    store.add(project)
                    path.append(project)
                }
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No Projects",
                        systemImage: "folder.badge.plus",
                        message: "Create a project, import a Swift package, or import a "
                            + "GitHub snapshot."
                    )
                }
            }
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(project.name).font(.headline)
                if project.isXcodeProject {
                    Text("read-only")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            Text(project.isXcodeProject
                 ? "Xcode project · inspect targets and files"
                 : "\(project.organizationIdentifier) · arm64-apple-ios")
                .font(.caption).foregroundStyle(.secondary)
            if let origin = project.origin?.shortDescription {
                Text(origin)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
