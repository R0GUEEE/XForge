import SwiftUI

struct RootTabView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var signing = XKitSigningService()
    @StateObject private var device = XKitDeviceService()
    @StateObject private var preferences = AppPreferences()
    @State private var selection: AppTab = .projects

    /// Three tabs, not four.
    ///
    /// The Terminal tab existed to type into the embedded Linux. With the guest
    /// gone there is nothing behind it — the toolchain runs in this process and
    /// reports into the Build screen's console — so the tab is gone rather than
    /// left opening an empty screen.
    enum AppTab: Hashable {
        case projects
        case build
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            ProjectsTab()
                .environmentObject(store)
                .environmentObject(preferences)
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(AppTab.projects)

            BuildTab(signing: signing, device: device)
                .environmentObject(store)
                .tabItem { Label("Build", systemImage: "hammer") }
                .tag(AppTab.build)

            SettingsTab(preferences: preferences)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task {
            // Create the app's own directories and keep the regenerable ones out
            // of iCloud backup — before anything writes into them. Projects are
            // user data and are backed up.
            XForgeEnvironment.prepareStorage()
            XForgeLog.prepare()
        }
    }
}
