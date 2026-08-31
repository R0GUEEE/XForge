import SwiftUI

struct ContentView: View {
    @State private var selection: Project?

    var body: some View {
        NavigationSplitView {
            ProjectListView(selection: $selection)
                .navigationTitle("XForge")
        } detail: {
            if let selection {
                ProjectDetailView(project: selection)
            } else {
                ContentUnavailableView(
                    "Select a project",
                    systemImage: "hammer",
                    description: Text("Pick a package to build, or create a new one.")
                )
            }
        }
    }
}

#Preview {
    ContentView()
}
