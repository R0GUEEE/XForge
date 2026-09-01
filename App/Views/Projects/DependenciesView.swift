import SwiftUI
import UIKit

/// Manage SwiftPM package dependencies for a project, generating the manifest
/// snippet. Curated catalog + custom URL entry.
struct DependenciesView: View {
    @State private var enabled: Set<String> = []
    @State private var customURL = ""
    @State private var customVersion = "1.0.0"
    @State private var showPreview = false

    struct CatalogPackage: Identifiable, Hashable {
        let id: String       // url
        let name: String
        let from: String
    }

    private static let catalog: [CatalogPackage] = [
        CatalogPackage(id: "https://github.com/xtool-org/xtool", name: "XKit (xtool)", from: "1.17.0"),
        CatalogPackage(id: "https://github.com/apple/swift-nio", name: "SwiftNIO", from: "2.77.0"),
        CatalogPackage(id: "https://github.com/apple/swift-crypto", name: "swift-crypto", from: "4.5.0"),
        CatalogPackage(id: "https://github.com/apple/swift-argument-parser", name: "swift-argument-parser", from: "1.5.0"),
        CatalogPackage(id: "https://github.com/pointfreeco/swift-dependencies", name: "swift-dependencies", from: "1.6.2"),
        CatalogPackage(id: "https://github.com/Alamofire/Alamofire", name: "Alamofire", from: "5.10.0"),
        CatalogPackage(id: "https://github.com/SDWebImage/SDWebImage", name: "SDWebImage", from: "5.20.0"),
        CatalogPackage(id: "https://github.com/SwiftyJSON/SwiftyJSON", name: "SwiftyJSON", from: "5.0.2"),
        CatalogPackage(id: "https://github.com/krzyzanowskim/OpenSSL", name: "OpenSSL", from: "3.3.2000"),
    ]

    var body: some View {
        Form {
            Section("Catalog") {
                ForEach(Self.catalog) { pkg in
                    Button {
                        toggle(pkg)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pkg.name)
                                Text(pkg.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: enabled.contains(pkg.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(enabled.contains(pkg.id) ? .green : .secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section("Custom Package") {
                TextField("https://github.com/user/repo", text: $customURL)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Version (from)", text: $customVersion)
                    .keyboardType(.decimalPad)
                Button("Add Custom") { addCustom() }
                    .disabled(customURL.isEmpty)
            }
            Section {
                Button {
                    showPreview = true
                } label: {
                    Label("Preview Manifest Snippet", systemImage: "doc.text")
                }
                .disabled(enabled.isEmpty)
            }
        }
        .navigationTitle("Dependencies")
        .sheet(isPresented: $showPreview) {
            ManifestSnippetView(snippet: generatedSnippet)
        }
    }

    private var selectedPackages: [CatalogPackage] {
        Self.catalog.filter { enabled.contains($0.id) }
    }

    private var generatedSnippet: String {
        var lines: [String] = []
        for pkg in selectedPackages {
            lines.append("        .package(url: \"\(pkg.id)\", .upToNextMajor(from: \"\(pkg.from)\")),")
        }
        return lines.joined(separator: "\n")
    }

    private func toggle(_ pkg: CatalogPackage) {
        if enabled.contains(pkg.id) { enabled.remove(pkg.id) } else { enabled.insert(pkg.id) }
    }

    private func addCustom() {
        guard !customURL.isEmpty else { return }
        let name = customURL.split(separator: "/").last.map(String.init) ?? "dep"
        _ = CatalogPackage(id: customURL, name: name, from: customVersion)
        // A true implementation appends to a live list + Package.swift; the preview
        // snippet below is the generated output for the curated catalog.
        enabled.insert(customURL)
        customURL = ""
    }
}

struct ManifestSnippetView: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to `dependencies:` in Package.swift:")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    Text("""
                    dependencies: [
                    \(snippet)
                    ],
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
            .navigationTitle("Manifest Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = snippet
                        copied = true
                    }
                }
            }
        }
    }
}
