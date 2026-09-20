import SwiftUI

struct RootTabView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var signing = XKitSigningService()
    @StateObject private var device = XKitDeviceService()
    @StateObject private var preferences = AppPreferences()
    @State private var selection: AppTab = .projects
    @State private var startupAttempt = 0
    @State private var startupError: String?

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
                .environmentObject(preferences)
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
        .task(id: startupAttempt) {
            // Import and boot the shared Alpine guest as part of app startup.
            // Every feature then reuses this verified interactive terminal.
            startupError = nil
            let vm = XForgeEnvironment.makeVM()
            await vm.prepareRootfs()
            do {
                try await vm.boot()
            } catch {
                startupError = error.localizedDescription
                XForgeLog.note("startup: Alpine guest failed to boot: \(error.localizedDescription)")
            }
        }
        .alert(
            "Linux Failed to Start",
            isPresented: Binding(
                get: { startupError != nil },
                set: { if !$0 { startupError = nil } }
            )
        ) {
            Button("Retry") {
                startupError = nil
                startupAttempt += 1
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(startupError ?? "The embedded Alpine system could not be started.")
        }
    }
}
