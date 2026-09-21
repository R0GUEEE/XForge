import SwiftUI

/// Signing is intentionally unavailable until authenticated XKit support is wired.
struct SigningView: View {
    @ObservedObject var signing: XKitSigningService

    var body: some View {
        List {
            Section {
                ContentUnavailableViewCompat(
                    title: "Signing Unavailable",
                    systemImage: "key.slash",
                    message: "This build does not include Apple ID authentication or certificate signing. Export the IPA and sign it with Xcode, SideStore, AltStore, or codesign on a Mac."
                )
            }
        }
        .navigationTitle("Signing")
    }
}
