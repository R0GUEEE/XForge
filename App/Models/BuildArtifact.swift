import Foundation

/// A built `.ipa` staged for export / install.
struct BuildArtifact: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    var name: String
    var size: Int64
    var date: Date
}
