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
    @StateObject private var manager: BuildManager
    @EnvironmentObject private var store: ProjectStore
    let project: Project
    @State private var showingFiles = false
    @State private var showingInfo = false
    @State private var showingDeps = false
    @State private var appInfo: AppInfo

    init(project: Project) {
        self.project = project
        let info = project.appInfo ?? .default(for: project)
        _appInfo = State(initialValue: info)
        _manager = StateObject(wrappedValue: BuildManager(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoCard
            toolsRow
            Divider()
            stageRow
            console
            toolbar
        }
        .task { await manager.bootstrap() }
        .sheet(isPresented: $showingFiles) {
            NavigationStack { FileBrowserView(project: project) }
        }
        .sheet(isPresented: $showingInfo) {
            InfoEditorView(initial: appInfo) { updated in
                appInfo = updated
                manager.appInfo = updated
                var p = project
                p.appInfo = updated
                store.update(p)
            }
        }
        .sheet(isPresented: $showingDeps) {
            NavigationStack { DependenciesView() }
        }
    }

    private var toolsRow: some View {
        HStack(spacing: 12) {
            toolButton("Files", icon: "folder", action: { showingFiles = true })
            toolButton("App Info", icon: "doc.badge.gearshape", action: { showingInfo = true })
            toolButton("Dependencies", icon: "shippingbox", action: { showingDeps = true })
            Spacer()
        }
        .padding(.horizontal).padding(.bottom, 10)
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(minWidth: 64)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(project.name, systemImage: "app.fill").font(.title2.bold())
            HStack(spacing: 16) {
                Label(appInfo.bundleIdentifier, systemImage: "building.2")
                Label("arm64-apple-ios", systemImage: "cpu")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stageRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(BuildStage.allCases) { stage in
                    VStack(spacing: 4) {
                        Image(systemName: symbol(for: stage))
                            .foregroundStyle(color(for: stage))
                        Text(stage.rawValue.capitalized)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal).padding(.bottom, 10)
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(manager.snapshot.consoleText.isEmpty ? "Ready.\n" : manager.snapshot.consoleText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal).padding(.bottom, 8)
            .onChange(of: manager.snapshot.consoleText) { _ in
                withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack {
            Picker("Configuration", selection: $manager.configuration) {
                ForEach(BuildConfiguration.allCases) { cfg in
                    Text(cfg.rawValue).tag(cfg)
                }
            }
            .pickerStyle(.segmented).frame(maxWidth: 200)

            Spacer()

            Button {
                Task { await manager.run() }
            } label: {
                Label(manager.snapshot.isRunning ? "Building…" : "Build", systemImage: "hammer")
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.snapshot.isRunning)

            if let ipa = manager.snapshot.lastIpa {
                ShareLink(item: ipa) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal).padding(.bottom)
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
