import Foundation

/// The produced app's `Info.plist` settings, editable before packaging.
struct AppInfo: Codable, Equatable, Hashable {
    var bundleIdentifier: String
    var displayName: String
    var version: String
    var buildNumber: String
    var minimumOSVersion: String

    static func `default`(for project: Project) -> AppInfo {
        AppInfo(
            bundleIdentifier: "\(project.organizationIdentifier).\(project.name)",
            displayName: project.name,
            version: "1.0",
            buildNumber: "1",
            minimumOSVersion: "16.0"
        )
    }
}
