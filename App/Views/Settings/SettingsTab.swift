import SwiftUI

/// Tab 5 — settings, storage, diagnostics, about.
struct SettingsTab: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        NavigationStack {
            SettingsView(preferences: preferences)
                .navigationTitle("Settings")
        }
    }
}
