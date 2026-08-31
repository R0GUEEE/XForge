import Foundation
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    private static let storageURL = URL
        .fileURL(withPath: "~/Documents/xforge-projects.json".nsExpandingTildeInPath)

    init() {
        load()
    }

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else {
            return
        }
        projects = decoded
    }
}

private extension String {
    var nsExpandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
