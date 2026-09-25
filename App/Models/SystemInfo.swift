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

    /// Free and total space.
    ///
    /// Free is the *important usage* figure — the same one an import decides with
    /// (`DarwinSDKBuilder.availableBytes`, which guards the `Xcode.xip` build) — so
    /// this screen cannot report space that an import then refuses. The two come
    /// from different APIs and disagree: `systemFreeSize` does not count the space
    /// iOS would free up for you.
    static var storage: (free: String, total: String) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let important = (try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path),
              let total = attrs[.systemSize] as? NSNumber else {
            return ("?", "?")
        }
        let free: Int64
        if let important, important > 0 {
            free = important
        } else {
            free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        return (ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: total.int64Value, countStyle: .file))
    }

    static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var processorCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var memory: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }
}
