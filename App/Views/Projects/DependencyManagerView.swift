import SwiftUI

/// Dependency workspace for a project. It parses lockfiles and can fetch exact,
/// public GitHub source snapshots. It is deliberately explicit that download is
/// not the same thing as compiling/linking the dependency into an IPA.
struct DependencyManagerView: View {
    let project: Project
    @State private var report: DependencyWorkspaceReport?
    @State private var isLoading = true
    @State private var isInstalling = false
    @StateObject private var progressModel = DependencyProgressModel()
    @State private var error: String?
    @State private var resultMessage: String?

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dependency sources are not buildable yet")
                            .font(.headline)
                        Text("XForge does not execute Package.swift or package plugins. Pinned public GitHub sources can be downloaded for inspection, but the current compiler cannot build dependency modules or link package products.")
                            .font(.footnote)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            if isLoading {
                Section { ProgressView("Analyzing dependency lockfiles…") }
            } else if let report {
                Section("Inventory") {
                    LabeledContent("Lockfiles", value: "\(report.lockfilePaths.count)")
                    LabeledContent("Pinned packages", value: "\(report.packagePins.count)")
                    LabeledContent("Pinned GitHub sources", value: "\(report.packagePins.filter { $0.kind == .remoteSourceControl }.count)")
                    if report.lockfilePaths.isEmpty {
                        Text("Commit Package.resolved to pin exact versions. XForge will not run the manifest to solve versions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Pinned packages") {
                    if report.packagePins.isEmpty {
                        Text("No committed Package.resolved pins were found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.packagePins) { pin in
                            pinRow(pin, report: report)
                        }
                    }
                }

                Section {
                    if !progressModel.message.isEmpty {
                        HStack { ProgressView(); Text(progressModel.message).font(.footnote) }
                    }
                    if let resultMessage {
                        Label(resultMessage, systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(.green)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Button {
                        Task { await installPinnedSources() }
                    } label: {
                        Label(isInstalling ? "Fetching…" : "Fetch pinned source snapshots",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(isInstalling || report.fetchablePins.isEmpty)
                } footer: {
                    Text("Only immutable, public GitHub remoteSourceControl pins are fetched. Other source types or malformed lockfiles are reported unsupported, not guessed. Package manifests and plugins are never executed, and fetched source does not make the project buildable until dependency modules/products can be compiled and linked.")
                }

                Section("Build compatibility") {
                    ForEach(report.findings) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(finding.summary).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(finding.capability.rawValue.capitalized)
                                    .font(.caption2)
                                    .foregroundColor(finding.capability == .unsupported ? .orange : .secondary)
                            }
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Dependencies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { Task { await reload() } }.disabled(isLoading || isInstalling)
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func pinRow(_ pin: ResolvedPackagePin, report: DependencyWorkspaceReport) -> some View {
        let supported = pin.kind == .remoteSourceControl
            && (try? GitHubRepository.parse(pin.location, explicitRef: pin.revision)) != nil
        let installed = report.installedIdentities.contains(pin.identity)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(pin.identity).font(.subheadline.weight(.semibold))
                Spacer()
                Text(installed ? "Fetched" : (supported ? "Pinned" : "Unsupported"))
                    .font(.caption2)
                    .foregroundColor(installed ? .green : (supported ? .secondary : .orange))
            }
            Text(pin.location).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("revision \(pin.revision.prefix(12))")
                if let version = pin.version { Text("· \(version)") }
            }
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
            if installed {
                Text("Source snapshot is present in the project dependency cache.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        let project = self.project
        do {
            report = try await Task.detached(priority: .utility) {
                DependencyWorkspaceAnalyzer.analyze(project: project)
            }.value
            error = nil
        } catch {
            report = nil
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func installPinnedSources() async {
        guard let report, !isInstalling else { return }
        isInstalling = true
        resultMessage = nil
        error = nil
        progressModel.message = "Preparing pinned source downloads…"
        defer { isInstalling = false; progressModel.message = "" }
        let owner = WeakDependencyProgressModel(progressModel)
        do {
            let result = try await PinnedDependencySourceInstaller.installPinnedSources(
                for: project,
                pins: report.packagePins,
                progress: { update in
                    Task { @MainActor in owner.value?.message = update.message }
                })
            resultMessage = "Fetched \(result.installed.count), already present \(result.alreadyPresent.count), expanded \(ByteCountFormatter.string(fromByteCount: result.extractedBytes, countStyle: .file))."
            if !result.notes.isEmpty {
                resultMessage = (resultMessage ?? "") + " Skipped: " + result.notes.joined(separator: "; ")
            }
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private final class DependencyProgressModel: ObservableObject {
    @Published var message = ""
}

/// The progress callback is @Sendable and runs after network awaits. This weak
/// box avoids capturing the SwiftUI view across the callback's actor hop.
private final class WeakDependencyProgressModel: @unchecked Sendable {
    weak var value: DependencyProgressModel?
    init(_ value: DependencyProgressModel) { self.value = value }
}
