import SwiftUI

struct RootTabView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var signing = XKitSigningService()
    @StateObject private var device = XKitDeviceService()
    @StateObject private var preferences = AppPreferences()
    /// One terminal for the whole app: the Toolchain screen and the terminal
    /// itself hand commands to the same session, so what a component install is
    /// doing is visible where it runs.
    @StateObject private var terminal = TerminalSession()
    @State private var selection: AppTab = .projects

    enum AppTab: Hashable {
        case projects
        case build
        case terminal
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

            BuildTab(signing: signing, device: device)
                .environmentObject(store)
                .tabItem { Label("Build", systemImage: "hammer") }
                .tag(AppTab.build)

            TerminalTab()
                .environmentObject(terminal)
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
                .tag(AppTab.terminal)

            ToolchainTab()
                .environmentObject(terminal)
                .tabItem { Label("Toolchain", systemImage: "wrench.and.screwdriver") }
                .tag(AppTab.toolchain)

            SettingsTab(preferences: preferences)
                .environmentObject(terminal)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task {
            // Install the bundled rootfs early, but do not make app presentation
            // depend on booting the guest. The guest command bridge can take time
            // to initialize on a physical device; Terminal and Toolchain perform
            // the same idempotent boot and surface its result when actually used.
            let vm = XForgeEnvironment.makeVM()
            await vm.prepareRootfs()
        }
    }
}
