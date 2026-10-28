import SwiftUI

/// A project imported from an Xcode project: a target list and a file browser,
/// both read-only.
///
/// There is no build button on this screen and no way to reach one. XForge has no
/// Xcode-project build driver, and a screen that offers a build it cannot perform
/// is worse than one that says so. This is the second `ProjectKind`; the Swift
/// package detail keeps the build pipeline.
struct XcodeProjectDetailView: View {
    let project: Project
    @State private var section: Section = .targets
    @State private var summary: XcodeProjectSummary?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var inventory: SnapshotInventory?
    @State private var isGenerating = false
    @State private var handoffArchive: URL?
    @State private var handoffError: String?
    @State private var showingDependencies = false

    enum Section: String, CaseIterable, Identifiable {
        case targets = "Targets"
        case files = "Files"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch section {
            case .targets: targets
            case .files: ProjectSnapshotBrowser(project: project)
            }
        }
        .navigationTitle(project.name)
        .task { await load() }
        .sheet(isPresented: $showingDependencies) {
            NavigationStack { DependencyManagerView(project: project) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Read-only snapshot", systemImage: "lock.doc")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(.orange)
                Spacer()
                Text(project.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let origin = project.origin, let description = origin.shortDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let subpath = project.snapshotSubpath {
                Text("Project folder: \(subpath)/")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("XForge cannot build an Xcode project yet, so this screen shows what the "
                 + "project contains. No build action is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Targets

    @ViewBuilder
    private var targets: some View {
        if isLoading {
            ProgressView("Reading project.pbxproj…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableViewCompat(
                title: "Could Not Read the Project",
                systemImage: "exclamationmark.triangle",
                message: loadError
            )
        } else if let summary {
            List {
                analysisSection
                if summary.targets.isEmpty {
                    SwiftUI.Section {
                        Text("This project file names no targets.").foregroundStyle(.secondary)
                    }
                } else {
                    SwiftUI.Section {
                        ForEach(summary.targets, id: \.id) { target in
                            targetRow(target)
                        }
                    } header: {
                        Text("Targets (\(summary.targets.count))")
                    } footer: {
                        Text("Targets, product types and settings are read from project.pbxproj "
                             + "as written; Xcode's variable expansion is not evaluated.")
                    }
                }
            }
        } else {
            ContentUnavailableViewCompat(
                title: "Project unavailable",
                systemImage: "folder",
                message: "The project summary is not available. Reload this project to analyze it."
            )
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        SwiftUI.Section {
            if let inventory {
                LabeledContent("Repository files", value: "\(inventory.fileCount)")
                LabeledContent("Extracted", value: ByteCountFormatter.string(fromByteCount: inventory.extractedBytes, countStyle: .file))
                LabeledContent("Xcode projects", value: "\(inventory.xcodeProjects.count)")
                LabeledContent("Workspaces", value: "\(inventory.workspaces.count)")
                if !inventory.xcodeProjects.isEmpty {
                    ForEach(inventory.xcodeProjects, id: \.self) { path in
                        Label(path, systemImage: "hammer")
                            .font(.caption)
                    }
                }
                if !inventory.workspaces.isEmpty {
                    ForEach(inventory.workspaces, id: \.self) { path in
                        Label(path, systemImage: "square.stack.3d.up")
                            .font(.caption)
                    }
                }
                if !inventory.packageManifests.isEmpty {
                    ForEach(inventory.packageManifests, id: \.self) { path in
                        Label("Package: \(path)", systemImage: "shippingbox")
                            .font(.caption)
                    }
                }
                if !inventory.lockfiles.isEmpty {
                    ForEach(inventory.lockfiles, id: \.self) { path in
                        Label("Lockfile: \(path)", systemImage: "lock")
                            .font(.caption)
                    }
                }
                Button {
                    showingDependencies = true
                } label: {
                    Label("Manage dependencies", systemImage: "shippingbox")
                }
                if !inventory.dependencyIndicators.isEmpty {
                    ForEach(inventory.dependencyIndicators, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
                if !inventory.lfsPointerFiles.isEmpty {
                    Label("\(inventory.lfsPointerFiles.count) Git LFS pointer files are not materialized.", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                if !inventory.caseCollisionPaths.isEmpty {
                    Label("Case-only filename collisions may not survive on this device.", systemImage: "case.lowercase")
                        .font(.caption)
                }
                if !inventory.scriptPhaseProjects.isEmpty {
                    Label("Shell build phases detected; XForge cannot execute them.", systemImage: "terminal")
                        .font(.caption)
                }
                if let handoffError {
                    Label(handoffError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let handoffArchive {
                    ShareLink(item: handoffArchive) {
                        Label("Share Xcode handoff + repository", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        generateHandoff()
                    } label: {
                        Label(isGenerating ? "Generating…" : "Generate Xcode handoff", systemImage: "hammer")
                    }
                    .disabled(isGenerating || summary == nil)
                }
            } else {
                ProgressView("Analyzing repository…")
            }
        } header: {
            Text("Repository analysis")
        } footer: {
            Text("The handoff creates a minimal .xcodeproj and .xcconfig for review in Xcode. It does not reproduce every original setting or dependency, and XForge does not build it.")
        }
    }

    private func generateHandoff() {
        guard let summary, let inventory, !isGenerating else { return }
        isGenerating = true
        handoffError = nil
        let project = self.project
        Task {
            defer { isGenerating = false }
            do {
                let output = try await Task.detached(priority: .utility) {
                    try XcodeProjectHandoff.export(project: project, summary: summary, inventory: inventory)
                }.value
                handoffArchive = output.archiveURL
            } catch {
                handoffError = error.localizedDescription
            }
        }
    }

    private func targetRow(_ target: XcodeTargetSummary) -> some View {
        DisclosureGroup {
            if target.sourceFiles.isEmpty {
                Text("No source files are listed for this target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(target.sourceFiles, id: \.self) { path in
                    Label(path, systemImage: path.hasSuffix(".swift") ? "swift" : "doc")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            if let bundleIdentifier = target.bundleIdentifier {
                detailLine("Bundle identifier", bundleIdentifier)
            }
            if let deploymentTarget = target.deploymentTarget {
                detailLine("Deployment target", "iOS \(deploymentTarget)")
            }
            if !target.configurationNames.isEmpty {
                detailLine("Configurations", target.configurationNames.joined(separator: ", "))
            }
            if !target.xcconfigPaths.isEmpty {
                detailLine("xcconfig", target.xcconfigPaths.joined(separator: ", "))
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(target.name).font(.headline)
                    Spacer(minLength: 8)
                    Text(target.productTypeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(sourceSummary(for: target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func sourceSummary(for target: XcodeTargetSummary) -> String {
        let count = target.sourceFiles.count
        let files = count == 1 ? "1 source file" : "\(count) source files"
        return target.containsSwift ? "\(files) · contains Swift" : files
    }

    private func load() async {
        isLoading = true
        let project = self.project
        do {
            let result = try await Task.detached(priority: .utility) {
                let summary = try XcodeProjectReader.read(at: project.rootURL)
                let inventory = SnapshotInventory.scan(root: project.snapshotRootURL)
                return (summary, inventory)
            }.value
            summary = result.0
            inventory = result.1
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Files

/// Browse the snapshot's files without an editor.
///
/// `FileBrowserView` is the package editor (it opens `SourceEditorView` and saves).
/// An imported Xcode project is read-only, so this walks the snapshot itself and
/// shows file contents as text. `.xcodeproj` is *not* skipped as a package: its
/// `project.pbxproj` is the most useful file in the snapshot.
struct ProjectSnapshotBrowser: View {
    let project: Project
    @State private var files: [SnapshotFileEntry] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView("Listing files…")
            } else if let error {
                ContentUnavailableViewCompat(
                    title: "Could Not List Files",
                    systemImage: "exclamationmark.triangle",
                    message: error
                )
            } else if files.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No Files",
                    systemImage: "folder",
                    message: "The imported snapshot has no readable files."
                )
            } else {
                SwiftUI.Section {
                    ForEach(files) { file in
                        NavigationLink {
                            SnapshotFileView(file: file, root: project.rootURL)
                        } label: {
                            HStack(spacing: 8) {
                                Label(file.name, systemImage: file.isSwift ? "swift" : "doc")
                                Spacer()
                                Text(file.sizeLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Files (\(files.count))")
                } footer: {
                    Text("Read-only. Files live in the app's projects folder; importing "
                         + "another revision creates a separate project.")
                }
            }
        }
        .task { load() }
    }

    private func load() {
        guard loading else { return }
        defer { loading = false }
        files = SnapshotFileLister.list(root: project.rootURL)
    }
}

struct SnapshotFileView: View {
    let file: SnapshotFileEntry
    let root: URL
    @State private var contents: String?

    var body: some View {
        ScrollView {
            if let contents {
                Text(contents)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            } else {
                ContentUnavailableViewCompat(
                    title: "Not Shown",
                    systemImage: "doc.questionmark",
                    message: "This file is binary or larger than 512 KB, so XForge does not "
                        + "render it."
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { contents = file.text(in: root) }
    }
}

// MARK: - File listing

struct SnapshotFileEntry: Identifiable, Hashable, Sendable {
    let relativePath: String
    let size: Int64

    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }
    var isSwift: Bool { relativePath.hasSuffix(".swift") }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The file's text, or `nil` for binaries and files too large to render.
    func text(in root: URL, limit: Int64 = 512 * 1024) -> String? {
        guard size <= limit else { return nil }
        return try? String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

/// A bounded, read-only file walk of an imported snapshot.
enum SnapshotFileLister {
    static let defaultLimit = 5_000
    private static let excludedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", "node_modules", "Pods",
    ]

    static func list(root: URL, limit: Int = defaultLimit) -> [SnapshotFileEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [SnapshotFileEntry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let relative = GitHubSnapshotDetector.relativePath(of: url, in: root) else { continue }
            files.append(SnapshotFileEntry(
                relativePath: relative,
                size: Int64(values?.fileSize ?? 0)
            ))
            if files.count >= limit { break }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
