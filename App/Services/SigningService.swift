import Foundation
import Combine
import XKit

/// Manages Apple Developer Services authentication, certificates and codesigning,
/// backed by XKit (DeveloperAPI + Zupersign). The GUI uses only this protocol; the
/// concrete XKit binding is in `XKitSigningService`.
@MainActor
protocol SigningService: ObservableObject {
    var account: AppleIDAccount { get }
    var identities: [SigningIdentity] { get }
    var state: SigningState { get }

    /// Begin (or resume) a free Apple ID session.
    func signIn(email: String, password: String) async throws
    /// Verify the stored session / refresh the account.
    func validateSession() async throws
    func signOut()

    /// Load signing certificates for the account's team.
    func refreshIdentities() async throws
    func activate(_ identity: SigningIdentity) async throws
    /// Ad-hoc (fake) sign an .app — used before export when no identity is configured.
    func adhocSign(appURL: URL, entitlements: [String: Any]) async throws
}

/// Default concrete implementation, backed by XKit. The Apple Developer Services
/// calls map to XKit's DeveloperAPI/Sign in `App/Dev` — this binding is completed
/// once the exact XKit surface is pinned; the UI depends only on `SigningService`.
@MainActor
final class XKitSigningService: SigningService {
    nonisolated init() {}

    @Published private(set) var account: AppleIDAccount = .empty
    @Published private(set) var identities: [SigningIdentity] = []
    @Published private(set) var state: SigningState = .notSignedIn

    func signIn(email: String, password: String) async throws {
        // TODO: XKit sign-in. Store only after success; never persist the password.
        account = AppleIDAccount(email: email, isSignedIn: true)
        state = .needsTeam(email)
        try await refreshIdentities()
    }

    func validateSession() async throws {
        // TODO: XKit session validation / refresh.
    }

    func signOut() {
        account = .empty
        identities = []
        state = .notSignedIn
    }

    func refreshIdentities() async throws {
        guard account.isSignedIn else {
            state = .notSignedIn
            return
        }
        // TODO: XKit DeveloperAPI certificate list for the team.
        identities = []
        state = .needsTeam(account.email)
    }

    func activate(_ identity: SigningIdentity) async throws {
        identities = identities.map { SigningIdentity(
            id: $0.id, name: $0.name, teamID: $0.teamID,
            expiresAt: $0.expiresAt, isActive: $0.id == identity.id) }
        if let active = identities.first(where: { $0.isActive }) {
            state = .ready(active)
        }
    }

    func adhocSign(appURL: URL, entitlements: [String: Any]) async throws {
        // TODO: XKit Zupersign ad-hoc sign.
    }
}
