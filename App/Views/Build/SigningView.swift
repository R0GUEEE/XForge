import SwiftUI
import UniformTypeIdentifiers

/// Sign a built IPA with an Apple Developer identity.
///
/// The signing itself is XKit — xtool's own signer — running in this process, so
/// the private key is read through the Security framework, used, and never written
/// anywhere. That used to be a `zsign` binary inside the embedded Linux with a
/// password file on disk; both are gone.
///
/// The Apple ID half of xtool (obtaining a certificate, 2FA, provisioning) is a
/// separate piece of work and is not faked here: this signs with an identity the
/// user already has.
struct SigningView: View {
    @ObservedObject var signing: XKitSigningService
    @ObservedObject var device: XKitDeviceService

    @StateObject private var job = IPASigningJob()
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
                if let ipa = job.inputIPA {
                    Text("The original is never modified: the signed IPA is written next to it in Documents.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ipa.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Signing files") {
                fileRow(title: "Certificate / private key (.p12)", url: job.p12,
                        icon: "key.fill") { importer = .p12 }
                SecureField("PKCS#12 password", text: $job.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                fileRow(title: "Provisioning profile (optional)", url: job.provisioningProfile,
                        icon: "checkmark.seal") { importer = .mobileprovision }
                fileRow(title: "Entitlements (optional)", url: job.entitlements,
                        icon: "list.bullet.rectangle") { importer = .entitlements }

                Text("The password and key stay in memory for this signing job and are never written to disk.")
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
                Text("Leave a field blank to keep the IPA's existing value. If you change the bundle identifier, the provisioning profile must authorize it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await job.sign() }
                } label: {
                    HStack {
                        if job.isWorking { ProgressView().controlSize(.small) }
                        Label(job.isWorking ? "Signing…" : "Sign IPA", systemImage: "signature")
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
                Text(job.status)
            }

            if let error = job.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                NavigationLink {
                    InstallView(device: device)
                } label: {
                    Label("Install on this device", systemImage: "iphone.and.arrow.forward")
                }
            } footer: {
                Text("Installing a signed build needs a device link that an app cannot open by itself; "
                     + "the Install screen explains the ways that do work on device.")
            }
        }
        .navigationTitle("Signing")
        .fileImporter(
            isPresented: Binding(
                get: { importer != nil },
                set: { if !$0 { importer = nil } }
            ),
            allowedContentTypes: importer?.types ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importer {
            case .ipa: job.inputIPA = url
            case .p12: job.p12 = url
            case .mobileprovision: job.provisioningProfile = url
            case .entitlements: job.entitlements = url
            case nil: break
            }
            importer = nil
        }
    }

    @ViewBuilder
    private func fileRow(
        title: String,
        url: URL?,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(url?.lastPathComponent ?? "Choose…")
                    .font(.caption)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
    }
}
