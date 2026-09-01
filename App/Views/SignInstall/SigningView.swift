import SwiftUI

/// Sign in with a free Apple ID and manage signing certificates (via XKit).
struct SigningView: View {
    @ObservedObject var signing: XKitSigningService
    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            switch signing.state {
            case .notSignedIn:
                signInSection
            case .needsTeam, .ready:
                accountSection
                certificatesSection
                signOutButton
            }
        }
        .navigationTitle("Signing")
        .task { await load() }
    }

    private var signInSection: some View {
        Section("Apple ID") {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("App-Specific Password", text: $password)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.footnote)
            }
            Button(isWorking ? "Signing in…" : "Sign In") {
                Task { await signIn() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || isWorking)
            Text("Use an app-specific password for your Apple ID. Credentials are never stored.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Email", value: signing.account.email)
            if let team = signing.account.teamName {
                LabeledContent("Team", value: team)
            }
        }
    }

    private var certificatesSection: some View {
        Section("Certificates") {
            if signing.identities.isEmpty {
                Text("No development certificates found. Build with ad-hoc signing, or refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(signing.identities) { identity in
                HStack {
                    VStack(alignment: .leading) {
                        Text(identity.name)
                        Text(identity.teamID)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if identity.isActive {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Use") {
                            Task { try? await signing.activate(identity) }
                        }
                    }
                }
            }
            Button {
                Task { _ = try? await signing.refreshIdentities() }
            } label: {
                Label("Refresh Certificates", systemImage: "arrow.clockwise")
            }
        }
    }

    private var signOutButton: some View {
        Button("Sign Out", role: .destructive) { signing.signOut() }
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await signing.signIn(email: email, password: password)
            password = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func load() async {
        if signing.account.email.isEmpty && signing.identities.isEmpty {
            // nothing persisted; stay on sign-in
        }
    }
}
