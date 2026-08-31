import SwiftUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @StateObject private var model: ProjectBuildModel

    init(project: Project) {
        _model = StateObject(wrappedValue: ProjectBuildModel(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            console
            toolbar
        }
        .navigationTitle(model.project.name)
        .fileExporter(
            isPresented: $model.showingExporter,
            document: model.ipaDocument,
            contentType: .item,
            defaultFilename: "\(model.project.name).ipa"
        ) { _ in }
        .task { await model.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.project.name, systemImage: "app.fill").font(.title2.bold())
            Text("\(model.project.organizationIdentifier) · arm64-apple-ios · \(model.configuration.rawValue)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.consoleText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .background(Color.black.opacity(0.04))
            .onChange(of: model.consoleText) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal).padding(.bottom, 8)
    }

    private var toolbar: some View {
        HStack {
            Picker("Configuration", selection: $model.configuration) {
                ForEach(BuildConfiguration.allCases) { cfg in
                    Text(cfg.rawValue).tag(cfg)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

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

#Preview {
    ProjectDetailView(project: Project(name: "Demo", rootPath: "/root/projects/Demo"))
}
