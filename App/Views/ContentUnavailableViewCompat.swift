import SwiftUI

/// iOS-16-compatible empty-state view (replaces iOS 17+ `ContentUnavailableView`).
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}
