import SwiftUI

/// Full build pipeline for one project, driven by `BuildManager`. Shows the real
/// pipeline stages (provision → sdk → configure → resolve → compile → package →
/// artifact) with live state and a streaming console.
struct BuildPipelineView: View {
    let project: Project
    @StateObject private var manager: BuildManager

    init(project: Project) {
        self.project = project
        _manager = StateObject(wrappedValue: BuildManager(project: project))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stepsCard
                consoleCard
            }
            .padding()
        }
        .task { await manager.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.title2.bold())
            HStack(spacing: 16) {
                Label(project.organizationIdentifier, systemImage: "building.2")
                Label("arm64-apple-ios", systemImage: "cpu")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pipeline").font(.headline)
                Spacer()
                if manager.snapshot.isRunning { ProgressView().controlSize(.small) }
                if let stage = manager.snapshot.activeStage {
                    Text(stage.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)

            ForEach(BuildStage.allCases) { stage in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: stage))
                        .foregroundStyle(color(for: stage))
                        .frame(width: 20)
                    Text(stage.title).font(.subheadline)
                    if manager.snapshot[stage] == .running { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var consoleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Picker("Configuration", selection: $manager.configuration) {
                    ForEach(BuildConfiguration.allCases) { cfg in
                        Text(cfg.rawValue).tag(cfg)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Button {
                    Task { await manager.run() }
                } label: {
                    Label(manager.snapshot.isRunning ? "Building…" : "Build", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.snapshot.isRunning)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(manager.snapshot.consoleText.isEmpty ? "Ready.\n" : manager.snapshot.consoleText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .frame(maxHeight: 320)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: manager.snapshot.consoleText) { _ in
                    withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func symbol(for stage: BuildStage) -> String {
        switch manager.snapshot[stage] {
        case .pending: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for stage: BuildStage) -> Color {
        switch manager.snapshot[stage] {
        case .pending: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
