import SwiftUI

/// Sign & install, moved into the Build tab: the steps that come after a build.
struct SignInstallCard: View {
    @ObservedObject var signing: XKitSigningService
    @ObservedObject var device: XKitDeviceService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign & Install").font(.headline)
                .padding(.bottom, 8)

            NavigationLink { SigningView(signing: signing) } label: {
                row(title: "Signing",
                    detail: "Sign the built app with a certificate",
                    icon: "key.fill")
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 8)

            NavigationLink { InstallView(device: device) } label: {
                row(title: "Export & Install",
                    detail: "Export for SideStore, AltStore, or Xcode",
                    icon: "iphone.and.arrow.forward")
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
