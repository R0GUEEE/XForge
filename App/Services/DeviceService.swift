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

/// Default concrete implementation backed by XKit.
///
/// Device access over usbmuxd requires entitlement-backed services that a
/// sideloaded app does not have, and the XKit bindings for install/launch are not
/// wired up here. Every entry point therefore reports that clearly instead of
/// returning an empty list, which previously looked like "no devices connected".
@MainActor
final class XKitDeviceService: DeviceService {
    nonisolated init() {}

    @Published private(set) var devices: [ConnectedDevice] = []

    func refreshDevices() async throws {
        devices = []
        throw DeviceError.notAvailable
    }

    func install(ipaURL: URL, to device: ConnectedDevice, progress: @escaping (Double) -> Void) async throws {
        throw DeviceError.notAvailable
    }

    func launch(_ bundleID: String, on device: ConnectedDevice) async throws {
        throw DeviceError.notAvailable
    }

    func uninstall(_ bundleID: String, from device: ConnectedDevice) async throws {
        throw DeviceError.notAvailable
    }

    func installedApps(on device: ConnectedDevice) async throws -> [InstalledApp] {
        throw DeviceError.notAvailable
    }
}

enum DeviceError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "On-device installation is not available in this build: talking to a "
                + "device over usbmuxd needs entitlement-backed access that a sideloaded "
                + "app does not have. Export the built .ipa and install it with "
                + "SideStore/AltStore instead."
        }
    }
}
