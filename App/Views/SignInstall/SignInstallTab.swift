import SwiftUI

/// Tab 3 — sign the built app and install it to a connected device (or hand off
/// to SideStore for sideloading).
struct SignInstallTab: View {
    @ObservedObject var signing: XKitSigningService
    @ObservedObject var device: XKitDeviceService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SigningView(signing: signing) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Signing").font(.headline)
                                Text(signingStateSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill").foregroundStyle(.tint)
                        }
                    }
                    NavigationLink { InstallView(device: device) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Install").font(.headline)
                                Text(deviceSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "iphone.and.arrow.forward").foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Sign & Install")
        }
    }

    private var signingStateSummary: String {
        switch signing.state {
        case .notSignedIn: return "Not signed in"
        case .needsTeam(let email): return "\(email) · no certificate yet"
        case .ready(let id): return "\(id.name) · active"
        }
    }

    private var deviceSummary: String {
        device.devices.isEmpty ? "No device connected" : "\(device.devices.count) device(s)"
    }
}
