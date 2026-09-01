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
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Select a project").font(.headline)
            Text("Pick a package to build, or create a new one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
