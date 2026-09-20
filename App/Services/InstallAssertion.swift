import Foundation
import UIKit

/// Keeps the app running while a long install finishes.
///
/// Two separate guards, because they cover different things:
///
///  - the idle timer, so the screen does not lock and iOS does not suspend the
///    app mid-install (the toolchain provisioning downloads hundreds of
///    megabytes and unpacks 1.4 GB; that is minutes of work);
///  - a background task assertion, for the case where the user leaves the app
///    anyway — it buys the time to finish or, at worst, to stop somewhere
///    coherent rather than being frozen with fakefs mid-transaction.
///
/// `begin`/`end` are counted: nested installs (or a second component queued
/// behind the first) must not have the first one's `end` release the guard.
@MainActor
final class InstallAssertion {
    private static var depth = 0
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var released = false

    static func begin(reason: String) -> InstallAssertion {
        let assertion = InstallAssertion()
        depth += 1
        if depth == 1 {
            UIApplication.shared.isIdleTimerDisabled = true
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "xforge-\(reason)") {
                    // Called when iOS is about to suspend us; hop to the main
                    // actor rather than assuming which thread this lands on.
                    Task { @MainActor in
                        XForgeLog.note("install: background time expired")
                        endBackgroundTaskIfNeeded()
                    }
                }
            }
            XForgeLog.note("install: holding the app awake for \(reason)")
        }
        return assertion
    }

    func end() {
        guard !released else { return }
        released = true
        Self.depth = max(0, Self.depth - 1)
        if Self.depth == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
            Self.endBackgroundTaskIfNeeded()
        }
    }

    private static func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
