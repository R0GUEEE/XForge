import SwiftUI

/// The app's empty state. iOS 17 has a native `ContentUnavailableView`, so this
/// only exists to keep the call sites terse; it renders the system view, which
/// gets Dynamic Type, VoiceOver and the platform's own layout for free.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    var message: String = ""

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: message.isEmpty ? nil : Text(message)
        )
    }
}
