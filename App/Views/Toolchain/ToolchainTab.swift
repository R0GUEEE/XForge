import SwiftUI

/// Tab 4 — manage the embedded build infrastructure (Linux, Swift, xtool, SDK).
struct ToolchainTab: View {
    var body: some View {
        NavigationStack {
            ToolchainView()
                .navigationTitle("Toolchain")
        }
    }
}
