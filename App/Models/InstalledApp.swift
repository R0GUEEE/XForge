import Foundation

/// A physical device connected via usbmuxd (mirrored through XKit/SwiftyMobileDevice).
struct ConnectedDevice: Identifiable, Hashable {
    var id: String            // UDID
    var name: String
    var model: String
    var osVersion: String
    var isAvailable: Bool = true
}

/// An app installed on a device (for uninstall / relaunch / status).
struct InstalledApp: Identifiable, Hashable {
    var id: String            // bundle identifier
    var name: String
    var version: String
    var bundleIdentifier: String
    var deviceUDID: String
}
