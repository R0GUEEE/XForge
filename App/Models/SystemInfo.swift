import Foundation
import UIKit

/// Lightweight system/device diagnostics for the Settings screen.
@MainActor
enum SystemInfo {
    static var deviceModel: String { UIDevice.current.model }
    static var deviceName: String { UIDevice.current.name }
    static var systemVersion: String { UIDevice.current.systemVersion }
    static var systemName: String { UIDevice.current.systemName }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "?"
    }

    static var storage: (free: String, total: String) {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber else {
            return ("?", "?")
        }
        return (ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: total.int64Value, countStyle: .file))
    }

    static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var memory: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }
}
