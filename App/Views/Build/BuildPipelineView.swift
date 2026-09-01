import SwiftUI

/// Full build pipeline for one project: toolchain checks, then build, then
/// packaging — presented as step-by-step progress plus a live console.
struct BuildPipelineView: View {
    let project: Project
    @StateObject private var model: ProjectBuildModel
    @State private var steps: [BuildStep] = [
        BuildStep(id: "toolchain", title: "Check toolchain"),
        BuildStep(id: "sdk", title: "Install Darwin SDK"),
        BuildStep(id: "build", title: "Compile (SwiftPM → arm64-apple-ios)"),
        BuildStep(id: "package", title: "Package & sign .ipa"),
        BuildStep(id: "done", title: "Done"),
    ]

    init(project: Project) {
        self.project = project
        _model = StateObject(wrappedValue: ProjectBuildModel(project: project))
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
        .task { await model.bootstrap() }
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
                if model.isBuilding { ProgressView().controlSize(.small) }
            }
            .padding(.bottom, 6)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 10) {
                    Image(systemName: step.state.symbol)
                        .foregroundStyle(color(for: step.state))
                        .frame(width: 20)
                    Text(step.title).font(.subheadline)
                    if step.state == .running { ProgressView().controlSize(.mini) }
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
                Button {
                    Task { await model.build() }
                } label: {
                    Label(model.isBuilding ? "Building…" : "Build", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.ready || model.isBuilding)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.consoleText.isEmpty ? "Ready.\n" : model.consoleText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.consoleText) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func color(for state: BuildStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
