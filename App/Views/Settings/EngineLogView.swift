import SwiftUI
import UIKit

/// The engine log: the engine's own kernel messages plus XForge's install
/// breadcrumbs, in one file, oldest first.
///
/// This is the thing to share when the app dies without saying why. The engine's
/// `die()` prints its reason and then calls `abort()` — killing the whole app —
/// and that message is the last line of this file. The breadcrumbs above it say
/// how far the install got first.
@MainActor
struct EngineLogView: View {
    @State private var text = ""
    @State private var bytes: Int64 = 0
    @State private var copied = false

    private var url: URL { XForgeLog.url }

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Nothing logged yet",
                    systemImage: "doc.text",
                    message: "Boot the embedded Linux, or install a toolchain component, "
                        + "and the engine's messages land here."
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .navigationTitle("Engine log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(text.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc")
                }
                .disabled(text.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    XForgeLog.clear()
                    reload()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(text.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !text.isEmpty {
                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \(url.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .task { reload() }
    }

    private func reload() {
        text = XForgeLog.text()
        bytes = XForgeLog.byteCount()
    }
}
