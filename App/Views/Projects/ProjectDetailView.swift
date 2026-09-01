import SwiftUI
import UniformTypeIdentifiers

/// A single project's hub: overview + build console, source browser, and manifest editor.
struct ProjectDetailView: View {
    let project: Project
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case sources = "Sources"
        case manifest = "Package.swift"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.top, 8)

            switch section {
            case .overview: OverviewSection(project: project)
            case .sources: SourceBrowserView(project: project)
            case .manifest: ManifestSection(project: project)
            }
        }
        .navigationTitle(project.name)
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    @StateObject private var model: ProjectBuildModel
    let project: Project

    init(project: Project) {
        self.project = project
        _model = StateObject(wrappedValue: ProjectBuildModel(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoCard
            Divider()
            console
            toolbar
        }
        .task { if !model.didBootstrap { await model.bootstrap() } }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(project.name, systemImage: "app.fill").font(.title2.bold())
            HStack(spacing: 16) {
                Label(project.organizationIdentifier, systemImage: "building.2")
                Label("arm64-apple-ios", systemImage: "cpu")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.consoleText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal).padding(.bottom, 8)
            .onChange(of: model.consoleText) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack {
            Picker("Configuration", selection: $model.configuration) {
                ForEach(BuildConfiguration.allCases) { cfg in
                    Text(cfg.rawValue).tag(cfg)
                }
            }
            .pickerStyle(.segmented).frame(maxWidth: 220)

            Spacer()

            if model.isBuilding {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel() }
            } else {
                Button {
                    Task { await model.build() }
                } label: {
                    Label("Build", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.ready)
            }

            Button {
                model.export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.lastIpa == nil)
        }
        .padding(.horizontal).padding(.bottom)
    }
}

// MARK: - Manifest

private struct ManifestSection: View {
    let project: Project
    @State private var showingEditor = false
    @State private var manifest: String

    init(project: Project) {
        self.project = project
        _manifest = State(initialValue: ManifestEditorView.template(name: project.name, org: project.organizationIdentifier))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Package.swift").font(.headline)
                Spacer()
                Button("Edit") { showingEditor = true }
                    .buttonStyle(.bordered)
            }
            .padding()

            Text(manifest)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal).padding(.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingEditor) {
            ManifestEditorView(project: project, initial: manifest) { updated in
                manifest = updated
            }
        }
    }
}
