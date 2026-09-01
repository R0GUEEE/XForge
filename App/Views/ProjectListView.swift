import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selection: Project?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.projects) { project in
                NavigationLink(value: project) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text("\(project.organizationIdentifier) · arm64-apple-ios")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { store.remove(store.projects[i]) }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("SwiftUI App") { createProject(template: .swiftUI) }
                    Button("Empty Package") { createProject(template: .empty) }
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView { project in
                store.add(project)
                selection = project
            }
        }
    }

    @State private var showingNewProject = false

    private func createProject(template: NewProjectView.Template) {
        showingNewProject = true
        _ = template
    }
}
