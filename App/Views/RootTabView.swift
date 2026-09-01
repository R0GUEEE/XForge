import SwiftUI

struct RootTabView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var signing = XKitSigningService()
    @StateObject private var device = XKitDeviceService()
    @StateObject private var preferences = AppPreferences()
    @State private var selection: AppTab = .projects

    enum AppTab: Hashable {
        case projects
        case build
        case signInstall
        case toolchain
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            ProjectsTab()
                .environmentObject(store)
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(AppTab.projects)

            BuildTab()
                .environmentObject(store)
                .tabItem { Label("Build", systemImage: "hammer") }
                .tag(AppTab.build)

            SignInstallTab(signing: signing, device: device)
                .tabItem { Label("Sign & Install", systemImage: "key.fill") }
                .tag(AppTab.signInstall)

            ToolchainTab()
                .tabItem { Label("Toolchain", systemImage: "wrench.and.screwdriver") }
                .tag(AppTab.toolchain)

            SettingsTab(preferences: preferences)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
