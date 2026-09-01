import Foundation
import Combine
import XKit

/// Detects and drives physical devices, and installs/launches apps — backed by XKit
/// (SwiftyMobileDevice + usbmuxd). The GUI depends only on this protocol.
@MainActor
protocol DeviceService: ObservableObject {
    var devices: [ConnectedDevice] { get }
    /// Refresh the device list (via usbmuxd over the app's device access).
    func refreshDevices() async throws
    /// Install a signed .ipa onto a device.
    func install(ipaURL: URL, to device: ConnectedDevice, progress: @escaping (Double) -> Void) async throws
    /// Launch an installed app on a device.
    func launch(_ bundleID: String, on device: ConnectedDevice) async throws
    /// Uninstall an app from a device.
    func uninstall(_ bundleID: String, from device: ConnectedDevice) async throws
    /// List apps installed on a device.
    func installedApps(on device: ConnectedDevice) async throws -> [InstalledApp]
}

/// Default concrete implementation backed by XKit. Device enumeration/install map
/// to SwiftyMobileDevice (usbmuxd); on a sideloaded build these may be limited —
/// the GUI handles that gracefully via the `refreshDevices` error path.
@MainActor
final class XKitDeviceService: DeviceService {
    nonisolated init() {}

    @Published private(set) var devices: [ConnectedDevice] = []

    func refreshDevices() async throws {
        // TODO: XKit SwiftyMobileDevice device enumeration.
        devices = []
    }

    func install(ipaURL: URL, to device: ConnectedDevice, progress: @escaping (Double) -> Void) async throws {
        // TODO: XKit install .ipa to device.
        progress(1.0)
    }

    func launch(_ bundleID: String, on device: ConnectedDevice) async throws {
        // TODO: XKit launch.
    }

    func uninstall(_ bundleID: String, from device: ConnectedDevice) async throws {
        // TODO: XKit uninstall.
    }

    func installedApps(on device: ConnectedDevice) async throws -> [InstalledApp] {
        // TODO: XKit list installed apps.
        []
    }
}
