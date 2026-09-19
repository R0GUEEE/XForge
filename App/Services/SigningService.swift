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
        // XKit's DeveloperServices stack exists, but a real Apple ID session needs
        // GrandSlam/Anisette authentication plus 2FA handling, and it has to be
        // exercised on a device. Until that is wired, fail loudly: reporting a
        // signed-in account without authenticating would be a lie, and the user
        // would only discover it when signing failed much later.
        throw SigningError.notImplemented
    }

    func validateSession() async throws {
        guard account.isSignedIn else { throw SigningError.notSignedIn }
        throw SigningError.notImplemented
    }

    func signOut() {
        account = .empty
        identities = []
        state = .notSignedIn
    }

    func refreshIdentities() async throws {
        guard account.isSignedIn else {
            state = .notSignedIn
            throw SigningError.notSignedIn
        }
        // No certificate list without a real session; say so rather than showing
        // an empty list that looks like "you have no certificates".
        throw SigningError.notImplemented
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
        // Real ad-hoc signing of an .app needs a code-signing implementation
        // (XKit Zupersign's `Sign`). Not wired up, so fail loudly.
        throw SigningError.notImplemented
    }
}

enum SigningError: LocalizedError {
    case notImplemented
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Apple ID sign-in is not implemented in this build. XForge builds and "
                + "packages apps, but they must be signed by a real tool (Xcode, "
                + "SideStore/AltStore, or `codesign` on a Mac)."
        case .notSignedIn:
            return "No Apple ID session."
        }
    }
}
