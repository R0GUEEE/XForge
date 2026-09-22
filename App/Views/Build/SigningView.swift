import SwiftUI
import UniformTypeIdentifiers

/// Full IPA configure, sign and install surface.
///
/// Signing is intentionally performed by zsign inside the Alpine guest. zsign is
/// a cross-platform C++ signer, not an iOS framework; running it in the guest
/// keeps the private key on the device, gives the user live command output, and
/// avoids pretending XKit's currently-unwired Apple-ID service can sign an IPA.
struct SigningView: View {
    @ObservedObject var signing: XKitSigningService
    @ObservedObject var device: XKitDeviceService

    @StateObject private var job = IPAConfigureSignService()
    @State private var importer: ImportTarget?
    @State private var showPassword = false

    enum ImportTarget: String, Identifiable {
        case ipa, p12, mobileprovision, entitlements
        var id: String { rawValue }
        var types: [UTType] {
            switch self {
            case .ipa: return [UTType(filenameExtension: "ipa") ?? .data]
            case .p12: return [UTType(filenameExtension: "p12") ?? .data,
                               UTType(filenameExtension: "pfx") ?? .data]
            case .mobileprovision: return [UTType(filenameExtension: "mobileprovision") ?? .data]
            case .entitlements: return [.propertyList, .data]
            }
        }
    }

    var body: some View {
        Form {
            Section("Input IPA") {
                fileRow(title: "IPA to sign", url: job.inputIPA, icon: "app.badge") {
                    importer = .ipa
                }
                if job.inputIPA != nil {
                    Text("The original IPA is copied into the guest and never modified in place.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Signing files") {
                fileRow(title: "Provisioning profile", url: job.provisioningProfile,
                        icon: "checkmark.seal") { importer = .mobileprovision }
                fileRow(title: "Certificate / private key (.p12)", url: job.p12,
                        icon: "key.fill") { importer = .p12 }
                SecureField("PKCS#12 password", text: $job.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                fileRow(title: "Entitlements (optional)", url: job.entitlements,
                        icon: "list.bullet.rectangle") { importer = .entitlements }

                Text("Keep the .p12 password private. It is held in memory for this signing job and is never saved to the project or build history.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("App configuration") {
                TextField("Bundle identifier (optional)", text: $job.bundleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Display name (optional)", text: $job.displayName)
                TextField("Version (optional)", text: $job.version)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Leave a field blank to preserve the IPA's existing value. If you change the bundle identifier, the provisioning profile must authorize it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await job.sign() }
                } label: {
                    HStack {
                        if job.isWorking { ProgressView().controlSize(.small) }
                        Label(job.isWorking ? "Signing in Alpine…" : "Configure & Sign IPA",
                              systemImage: "signature")
                        Spacer()
                    }
                }
                .disabled(!job.canSign)

                if let signed = job.signedIPA {
                    ShareLink(item: signed) {
                        Label("Share signed IPA", systemImage: "square.and.arrow.up")
                    }
                    Text(signed.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Action")
            } footer: {
                Text("zsign is installed into the embedded Linux guest on first use. It supports .p12/.pfx keys, .mobileprovision profiles, entitlements, bundle ID/name/version changes, and IPA output.")
            }

            Section("Status") {
                Text(job.status).font(.system(.footnote, design: .monospaced))
                if let error = job.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Configure & Sign")
        .fileImporter(isPresented: Binding(
            get: { importer != nil },
            set: { if !$0 { importer = nil } }
        ), allowedContentTypes: importer?.types ?? [.data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let target = importer else { return }
            switch target {
            case .ipa: job.inputIPA = url
            case .p12: job.p12 = url
            case .mobileprovision: job.provisioningProfile = url
            case .entitlements: job.entitlements = url
            }
            importer = nil
        }
    }

    @ViewBuilder
    private func fileRow(title: String, url: URL?, icon: String,
                         choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(url?.lastPathComponent ?? "Choose from Files…")
                        .font(.caption).foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
    }
}
