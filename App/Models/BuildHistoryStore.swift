import Foundation
import Combine

/// A persisted record of a past build attempt.
struct BuildRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectName: String
    var configuration: String
    var buildNumber: Int
    var result: String          // "success" | "failed"
    var artifactName: String?
    var error: String?
    var date: Date
}

/// Persists build attempts to a JSON file in the app sandbox.
@MainActor
final class BuildHistoryStore: ObservableObject {
    @Published private(set) var records: [BuildRecord] = []

    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("build-history.json")
    }()

    init() {
        load()
    }

    func record(
        projectName: String,
        configuration: String,
        buildNumber: Int,
        result: String,
        artifactName: String?,
        error: String?
    ) {
        records.insert(
            BuildRecord(
                projectName: projectName,
                configuration: configuration,
                buildNumber: buildNumber,
                result: result,
                artifactName: artifactName,
                error: error,
                date: Date()
            ),
            at: 0
        )
        if records.count > 200 { records = Array(records.prefix(200)) }
        save()
    }

    func remove(_ record: BuildRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([BuildRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
