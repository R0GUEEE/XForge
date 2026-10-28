import SwiftUI
import UniformTypeIdentifiers

/// Import an existing package from the Files app — or inspect an existing Xcode
/// project without importing it.
///
/// This used to `git clone` into the embedded Linux. There is no `git` in an iOS
/// process and no process to run it in, so the import is now what an app can
/// actually do: copy a folder the user picked into the projects directory. A
/// repository can still be fetched with an app that does have git — Working Copy,
/// or Files' own "Download" on a zip — and imported from there.
///
/// An `.xcodeproj` has no build path in XForge yet, so it is never added to the
/// project list. Picking one shows its real targets, read on-device by
/// `XcodeProjectReader`, and says plainly that inspection does not build it.
struct ImportProjectView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var picked: URL?
    @State private var inspection: ProjectImportInspection?
    @State private var showingPicker = false
    @State private var name = ""
    @State private var orgId = ""
    @State private var isImporting = false
    @State private var error: String?

    let onImported: (Project) -> Void

    private var derivedName: String {
        if !name.isEmpty { return name }
        guard let picked else { return "" }
        return suggestedName(for: picked)
    }

    private var canImport: Bool { inspection?.isImportable == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingPicker = true
                    } label: {
                        Label(picked?.lastPathComponent ?? "Choose a folder or .xcodeproj…",
                              systemImage: "folder")
                    }
                    if let picked {
                        Text(picked.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Pick a Swift package folder to import, or an Xcode project — the "
                         + ".xcodeproj itself or the folder holding it — to inspect it without "
                         + "building it.")
                }

                if let inspection {
                    inspectionSections(for: inspection)
                }

                if isImporting || error != nil {
                    Section {
                        if isImporting {
                            HStack { ProgressView(); Text("Copying into XForge…") }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Import a project")
            .onAppear {
                if orgId.isEmpty { orgId = preferences.defaultOrgId }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(canImport ? "Cancel" : "Close") { dismiss() }
                }
                if canImport {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { startImport() }
                            .disabled(picked == nil || isImporting)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            pick(url)
        }
    }

    /// `.folder` for a package directory, and a dynamic type for the `.xcodeproj`
    /// package so the picker lets one be selected. `UTType(filenameExtension:)` can
    /// be nil on a device without Xcode, hence the tagged fallback.
    private var allowedContentTypes: [UTType] {
        let xcodeProject = UTType(tag: "xcodeproj", tagClass: .filenameExtension, conformingTo: .package)
            ?? .folder
        return [.folder, xcodeProject]
    }

    @ViewBuilder
    private func inspectionSections(for inspection: ProjectImportInspection) -> some View {
        switch inspection {
        case .swiftPackage:
            Section {
                TextField("Name", text: $name)
                TextField("Organization Identifier", text: $orgId)
                    .keyboardType(.alphabet).autocorrectionDisabled()
            } header: {
                Text("Project")
            } footer: {
                Text("The folder is copied, not moved. XForge imports Swift packages and "
                     + "supports a limited subset of package builds, so importing does not "
                     + "guarantee a successful build.")
            }

        case .xcodeProject(let summary):
            XcodeProjectReadOnlySection(summary: summary)

        case .unreadableXcodeProject(let reason):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This Xcode project could not be read").font(.headline)
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Xcode project")
            }
            XcodeProjectUnsupportedNotice()

        case .notAProject(let reason):
            Section {
                Label(reason, systemImage: "questionmark.folder")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Not importable")
            } footer: {
                Text("To import, pick a folder containing Package.swift. An .xcodeproj can "
                     + "be looked at here, but not built.")
            }
        }
    }

    // MARK: - Picking and importing

    /// Read the picked URL while the security scope is held: `XcodeProjectReader`
    /// opens `project.pbxproj` (and any xcconfigs) during this call, and the URL is
    /// unreadable once the scope ends.
    private func pick(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let previousSuggestion = picked.map { suggestedName(for: $0) }
        if name.isEmpty || name == previousSuggestion {
            name = suggestedName(for: url)
        }
        picked = url
        inspection = ProjectImportInspector.inspect(url)
        error = nil
    }

    private func suggestedName(for url: URL) -> String {
        url.pathExtension == "xcodeproj"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
    }

    private func startImport() {
        guard let source = picked, let inspection, case .swiftPackage = inspection else { return }
        isImporting = true
        error = nil
        let projectName = derivedName
        let org = orgId

        Task {
            defer { isImporting = false }
            do {
                let validated = try Project.validatedName(projectName)
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }

                let manifest = source.appendingPathComponent("Package.swift")
                guard FileManager.default.fileExists(atPath: manifest.path) else {
                    throw ImportError.notAPackage(source.lastPathComponent)
                }

                let project = Project(
                    name: validated,
                    organizationIdentifier: org,
                    rootPath: Project.path(forValidatedName: validated)
                )
                let destination = project.rootURL
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw ImportError.alreadyExists(validated)
                }
                try FileManager.default.copyItem(at: source, to: destination)

                onImported(project)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Read-only Xcode project inspection

/// The target list of an existing `.xcodeproj`, plus the notice that inspection
/// does not build it. This view never offers a build, import, or "convert" action:
/// the reader is the whole feature.
private struct XcodeProjectReadOnlySection: View {
    let summary: XcodeProjectSummary

    var body: some View {
        Group {
            Section {
                LabeledContent("Project", value: summary.name)
                if summary.targets.isEmpty {
                    Text("This project file names no targets.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Xcode project · read only")
            } footer: {
                Text("Targets, product types and settings are read from project.pbxproj. "
                     + "Settings are shown as written; Xcode's variable expansion is not "
                     + "evaluated.")
            }

            if !summary.targets.isEmpty {
                Section {
                    ForEach(summary.targets) { target in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(target.name).font(.headline)
                                Spacer(minLength: 8)
                                Text(target.productTypeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(details(for: target))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Targets (\(summary.targets.count))")
                }
            }

            XcodeProjectUnsupportedNotice()
        }
    }

    /// Everything shown comes from the project file itself — no inference from the
    /// folder contents, which could disagree with what Xcode would build.
    private func details(for target: XcodeTargetSummary) -> String {
        var parts: [String] = []
        if let bundleIdentifier = target.bundleIdentifier { parts.append(bundleIdentifier) }
        if let deploymentTarget = target.deploymentTarget {
            parts.append("iOS \(deploymentTarget)")
        }
        let count = target.sourceFiles.count
        parts.append(count == 1 ? "1 source file" : "\(count) source files")
        if target.containsSwift { parts.append("contains Swift") }
        return parts.joined(separator: " · ")
    }
}

/// The one sentence this milestone exists to say, in the same words everywhere an
/// Xcode project is shown.
private struct XcodeProjectUnsupportedNotice: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-only inspection").font(.headline)
                    Text("XForge does not yet have an Xcode-project build driver; "
                         + "inspection cannot build this project or produce an IPA. "
                         + "Build it elsewhere for now.")
                        .font(.footnote)
                }
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Build support")
        }
    }
}

enum ImportError: LocalizedError {
    case notAPackage(String)
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .notAPackage(let name):
            return "\(name) has no Package.swift, so it is not a Swift package."
        case .alreadyExists(let name):
            return "A project named \(name) already exists. Rename it, or remove the existing one first."
        }
    }
}
