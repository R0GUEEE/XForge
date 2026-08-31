import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// View model that drives the build pipeline for one project.
@MainActor
final class ProjectBuildModel: ObservableObject {
    let project: Project

    @Published var configuration: BuildConfiguration = .debug
    @Published private(set) var isBuilding = false
    @Published private(set) var ready = false
    @Published private(set) var consoleText = ""
    @Published private(set) var lastIpa: URL?
    @Published var showingExporter = false
    @Published var ipaDocument: IPAFileDocument = IPAFileDocument(url: nil)

    private var executor: BuildExecutor?

    init(project: Project) {
        self.project = project
    }

    func bootstrap() async {
        let executor = XForgeEnvironment.makeExecutor(for: project)
        self.executor = executor
        do {
            let stream = try await executor.bootstrap()
            for try await event in stream {
                handle(event)
            }
            ready = true
        } catch {
            append("[error] \(error.localizedDescription)")
        }
    }

    func build() async {
        guard let executor else { return }
        isBuilding = true
        defer { isBuilding = false }
        do {
            let stream = try await executor.build(project, configuration: configuration)
            for try await event in stream {
                handle(event)
            }
        } catch {
            append("[error] \(error.localizedDescription)")
        }
    }

    func cancel() {
        // Stub: future iteration will send SIGINT into the VM.
    }

    func export() {
        guard let lastIpa else { return }
        ipaDocument = IPAFileDocument(url: lastIpa)
        showingExporter = true
    }

    private func handle(_ event: BuildEvent) {
        switch event {
        case .plan(let s): append("▶ \(s)")
        case .output(let s): append(s)
        case .artifact(let url): lastIpa = url; append("✓ artifact: \(url.lastPathComponent)")
        case .finished: append("✓ done")
        case .failed(let s): append("[failed] \(s)")
        }
    }

    private func append(_ line: String) {
        consoleText += (line + "\n")
        if consoleText.count > 100_000 {
            consoleText = String(consoleText.suffix(100_000))
        }
    }
}

/// Minimal file wrapper for the share/export sheet.
struct IPAFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.item] }
    var url: URL?

    init(url: URL?) { self.url = url }

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else { throw CocoaError(.fileWriteUnknown) }
        return try FileWrapper(url: url)
    }
}
