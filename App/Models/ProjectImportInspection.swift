import Foundation

/// What a folder picked in the Files app turned out to be.
///
/// Import has one job — copy a SwiftPM package — and an `.xcodeproj` is not one.
/// Rather than rejecting it with "not a Swift package", the picker offers a
/// read-only look at the project's actual targets (`XcodeProjectReader`). That is
/// inspection, not a build path: XForge does not yet have an Xcode-project build
/// driver, so an existing project cannot be built from this screen.
enum ProjectImportInspection: Sendable {
    /// A folder with a `Package.swift`: the only thing import accepts.
    case swiftPackage
    /// An Xcode project that was read successfully: targets are shown, nothing builds.
    case xcodeProject(XcodeProjectSummary)
    /// An `.xcodeproj` that exists but cannot be read, with the reader's reason.
    /// Kept apart from `.xcodeProject` so the UI can say *why* there is no target
    /// list instead of showing an empty one.
    case unreadableXcodeProject(String)
    /// No `Package.swift` and no `.xcodeproj` were found.
    case notAProject(String)

    /// Only a Swift package can be imported. The others are inspection only, and
    /// the UI must not offer to add them to the project list.
    var isImportable: Bool {
        if case .swiftPackage = self { return true }
        return false
    }
}

enum ProjectImportInspector {
    /// Decide what `url` is without copying it. `url` may be a folder or an
    /// `.xcodeproj` bundle itself.
    ///
    /// The caller must already hold security-scoped access to `url`: on iOS the
    /// picked URL stops being readable the moment the scope ends, and this function
    /// reads `project.pbxproj` and any xcconfigs through `XcodeProjectReader`.
    static func inspect(_ url: URL) -> ProjectImportInspection {
        let isProjectBundle = url.pathExtension == "xcodeproj"
        let hasManifest = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Package.swift").path
        )

        // A folder that has both is a package first: SwiftPM is what import copies,
        // and its build uses Package.swift, not the Xcode project beside it.
        if !isProjectBundle, hasManifest { return .swiftPackage }

        guard isProjectBundle || containsXcodeProject(url) else {
            return .notAProject(
                "\(url.lastPathComponent) contains no Package.swift and no .xcodeproj."
            )
        }

        do {
            return .xcodeProject(try XcodeProjectReader.read(at: url))
        } catch {
            return .unreadableXcodeProject(error.localizedDescription)
        }
    }

    /// Only the picked folder itself is searched. Looking deeper would mean guessing
    /// which of several nested projects was meant; `XcodeProjectReader` already
    /// refuses to guess when one folder holds more than one `*.xcodeproj`.
    private static func containsXcodeProject(_ url: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.contains { $0.pathExtension == "xcodeproj" }
    }
}

extension XcodeTargetSummary {
    /// `com.apple.product-type.application` → `application`, for the target list.
    /// Reported as written when it is not the usual prefix, rather than guessed.
    var productTypeLabel: String {
        let prefix = "com.apple.product-type."
        guard !productType.isEmpty else { return "no product type" }
        guard productType.hasPrefix(prefix) else { return productType }
        return String(productType.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: " ")
    }
}
