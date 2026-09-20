import SwiftUI

/// Add SwiftPM dependencies directly to the project's real Package.swift.
struct DependenciesView: View {
    let project: Project

    @State private var enabled: Set<String> = []
    @State private var customPackages: [CatalogPackage] = []
    @State private var customURL = ""
    @State private var customVersion = "1.0.0"
    @State private var applying = false
    @State private var message: String?

    struct CatalogPackage: Identifiable, Hashable {
        let id: String
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
                ForEach(Self.catalog + customPackages) { package in
                    Button {
                        toggle(package)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(package.name)
                                Text(package.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: enabled.contains(package.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(enabled.contains(package.id)
                                                 ? .green : .secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("Custom Package") {
                TextField("https://github.com/user/repo", text: $customURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Version (from)", text: $customVersion)
                    .keyboardType(.numbersAndPunctuation)
                Button("Add Custom") { addCustom() }
                    .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Button {
                    Task { await apply() }
                } label: {
                    Label(applying ? "Applying…" : "Apply to Package.swift",
                          systemImage: "shippingbox.and.arrow.backward")
                }
                .disabled(enabled.isEmpty || applying)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.hasPrefix("Added") ? .green : .red)
                }
            }
        }
        .navigationTitle("Dependencies")
    }

    private var selectedPackages: [CatalogPackage] {
        (Self.catalog + customPackages).filter { enabled.contains($0.id) }
    }

    private func toggle(_ package: CatalogPackage) {
        if enabled.contains(package.id) {
            enabled.remove(package.id)
        } else {
            enabled.insert(package.id)
        }
    }

    private func addCustom() {
        let url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = customVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: url)?.scheme == "https", !version.isEmpty else {
            message = "Enter an HTTPS repository URL and a version."
            return
        }

        let name = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "Package"
        let package = CatalogPackage(id: url, name: name, from: version)
        if !customPackages.contains(where: { $0.id == url }) {
            customPackages.append(package)
        }
        enabled.insert(url)
        customURL = ""
    }

    private func apply() async {
        guard project.hasSafeRootPath else {
            message = ProjectValidationError.unsafePath.localizedDescription
            return
        }

        applying = true
        message = nil
        defer { applying = false }

        do {
            let vm = XForgeEnvironment.makeVM()
            for package in selectedPackages {
                let command = "cd \(GuestShell.quote(project.rootPath)) && "
                    + "swift package add-dependency \(GuestShell.quote(package.id)) "
                    + "--from \(GuestShell.quote(package.from))"
                let status = try await vm.run(command, environment: nil) { _ in }
                guard status == 0 else {
                    throw DependencyError.addFailed(package.name, status)
                }
            }
            message = "Added \(selectedPackages.count) package(s) to Package.swift."
            enabled.removeAll()
        } catch {
            message = error.localizedDescription
        }
    }
}

enum DependencyError: LocalizedError {
    case addFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .addFailed(let name, let status):
            return "Could not add \(name) (exit \(status))."
        }
    }
}
