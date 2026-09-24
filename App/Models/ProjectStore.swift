import Foundation
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    /// The project list lives in the app's own Documents directory, resolved the
    /// way every other path in the app is (`XForgeEnvironment.documentDirectory`)
    /// rather than through a `~` expansion, which is a second source of truth for
    /// the same place and silently writes nowhere useful if the container moves.
    private static var storageURL: URL {
        XForgeEnvironment.documentDirectory
            .appendingPathComponent("xforge-projects.json", isDirectory: false)
    }

    init() {
        load()
    }

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
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
