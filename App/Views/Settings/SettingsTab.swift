import SwiftUI

/// Tab 3 — toolchain, app files, build defaults, diagnostics, about.
struct SettingsTab: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        NavigationStack {
            SettingsView(preferences: preferences)
                .navigationTitle("Settings")
        }
    }
}
