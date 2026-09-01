import Foundation
import Combine

/// User-facing preferences, persisted to UserDefaults.
@MainActor
final class AppPreferences: ObservableObject {
    @Published var defaultOrgId: String {
        didSet { defaults.set(defaultOrgId, forKey: Keys.orgId) }
    }
    @Published var defaultMinIOS: String {
        didSet { defaults.set(defaultMinIOS, forKey: Keys.minIOS) }
    }
    @Published var defaultConfiguration: BuildConfiguration {
        didSet { defaults.set(defaultConfiguration.rawValue, forKey: Keys.configuration) }
    }
    @Published var showIPhoneOnlyLayout: Bool {
        didSet { defaults.set(showIPhoneOnlyLayout, forKey: Keys.iphoneOnly) }
    }

    private let defaults: UserDefaults

    enum Keys {
        static let orgId = "defaultOrgId"
        static let minIOS = "defaultMinIOS"
        static let configuration = "defaultConfiguration"
        static let iphoneOnly = "showIPhoneOnlyLayout"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _defaultOrgId = Published(initialValue: defaults.string(forKey: Keys.orgId) ?? "com.example")
        _defaultMinIOS = Published(initialValue: defaults.string(forKey: Keys.minIOS) ?? "16.0")
        _defaultConfiguration = Published(initialValue: BuildConfiguration(
            rawValue: defaults.string(forKey: Keys.configuration) ?? "debug") ?? .debug)
        _showIPhoneOnlyLayout = Published(initialValue: defaults.bool(forKey: Keys.iphoneOnly))
    }
}
