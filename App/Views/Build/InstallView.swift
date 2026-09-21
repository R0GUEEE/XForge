import SwiftUI

/// Direct device installation is unavailable; hand built IPAs to a signing app.
struct InstallView: View {
    @ObservedObject var device: XKitDeviceService

    var body: some View {
        List {
            Section {
                ContentUnavailableViewCompat(
                    title: "Direct Install Unavailable",
                    systemImage: "iphone.slash",
                    message: "A sideloaded app cannot access the entitlement-backed device services required for installation. Export an IPA and install it with SideStore, AltStore, Xcode, or Apple Configurator."
                )
            }

            Section {
                NavigationLink {
                    ArtifactsView()
                } label: {
                    Label("Export Built IPAs", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Export & Install")
    }
}
