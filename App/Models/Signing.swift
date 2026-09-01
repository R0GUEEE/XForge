import Foundation

/// A signed-in Apple ID account used for free provision signing.
struct AppleIDAccount: Identifiable, Codable, Hashable {
    var id: String { email }
    var email: String
    var teamID: String?
    var teamName: String?
    var isSignedIn: Bool

    static let empty = AppleIDAccount(email: "", isSignedIn: false)
}

/// A signing identity (certificate) available for codesigning.
struct SigningIdentity: Identifiable, Codable, Hashable {
    var id: String            // SHA1 serial / identifier
    var name: String
    var teamID: String
    var expiresAt: Date?
    var isActive: Bool = false
}

enum SigningState: Equatable {
    case notSignedIn
    case needsTeam(String)
    case ready(SigningIdentity)
}
