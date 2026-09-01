import SwiftUI

/// Browse the whole SwiftPM package tree and open source files for editing.
struct FileBrowserView: View {
    let project: Project
    @State private var tree: [FSNode] = []
    @State private var selection: FSNode?

    struct FSNode: Identifiable, Hashable {
        let id: String
        let name: String
        let isDir: Bool
        let path: String
        var children: [FSNode] = []

        static func swiftFile(_ name: String, in root: String) -> FSNode {
            FSNode(id: "\(root)/\(name)", name: name, isDir: false, path: "\(root)/\(name)")
        }
    }

    var body: some View {
        List {
            Section("Package") {
                ForEach(tree) { node in
                    NodeRow(node: node)
                }
            }
        }
        .navigationTitle("Files")
        .navigationDestination(for: FSNode.self) { node in
            if !node.isDir {
                SourceEditorView(
                    file: SourceBrowserView.SourceFile(id: node.id, name: node.name, contents: "// \(node.path)\n")
                ) { _ in }
            }
        }
        .task { buildTree() }
    }

    private func buildTree() {
        let src = FSNode(id: "Sources", name: "Sources", isDir: true, path: "Sources", children: [
            FSNode(id: "Sources/\(project.name)", name: project.name, isDir: true, path: "Sources/\(project.name)", children: [
                .swiftFile("\(project.name).swift", in: "Sources/\(project.name)"),
                .swiftFile("ContentView.swift", in: "Sources/\(project.name)"),
            ])
        ])
        let tests = FSNode(id: "Tests", name: "Tests", isDir: true, path: "Tests", children: [
            FSNode(id: "Tests/\(project.name)Tests", name: "\(project.name)Tests", isDir: true, path: "Tests/\(project.name)Tests", children: [
                .swiftFile("\(project.name)Tests.swift", in: "Tests/\(project.name)Tests"),
            ])
        ])
        tree = [
            FSNode(id: "Package.swift", name: "Package.swift", isDir: false, path: "Package.swift"),
            src,
            tests,
        ]
    }
}

struct NodeRow: View {
    let node: FileBrowserView.FSNode
    var body: some View {
        if node.isDir {
            DisclosureGroup {
                ForEach(node.children) { child in
                    NodeRow(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
        } else {
            NavigationLink(value: node) {
                Label(node.name, systemImage: node.name.hasSuffix(".swift") ? "swift" : "doc")
            }
        }
    }
}
