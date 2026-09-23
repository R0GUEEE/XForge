import Foundation

/// Getting a project out of the guest.
///
/// Projects live inside the guest filesystem's `fakefs`, and that filesystem is
/// deliberately kept *out* of iCloud backup: it is several gigabytes of toolchain
/// wrapped around a few kilobytes of source, and nothing in the app can mark one
/// without the other (see Docs/DESIGN.md, "What is backed up"). That makes an
/// export the way work leaves the device, so it is a first-class action rather
/// than something to be assembled from `tar` in the Terminal.
///
/// The archive is built *inside* the guest — that is where the files are — and
/// copied out into the app's own `Documents/exports`, where the Files app shows it
/// and the share sheet can hand it on.
enum ProjectExporter {
    /// Where exported archives land: `<Documents>/exports`, which is user data and
    /// is backed up (unlike the guest filesystem it came from). Defined by
    /// `XForgeEnvironment`, which owns the storage rules.
    static var exportsDirectory: URL { XForgeEnvironment.exportsDirectory }

    /// Archive `project` inside the guest and copy the archive out.
    ///
    /// Returns the host URL of the archive, ready to share.
    static func export(_ project: Project, via vm: LinuxVM) async throws -> URL {
        guard project.hasSafeRootPath else { throw ProjectValidationError.unsafePath }
        let name = try Project.validatedName(project.name)
        try await vm.boot()

        let guestArchive = "/tmp/\(name).tar.gz"
        let parent = (project.rootPath as NSString).deletingLastPathComponent
        // `-C parent name` keeps the archive to one top-level directory, so
        // unpacking it cannot scatter files over wherever it is opened.
        let status = try await vm.run(
            "rm -f \(GuestShell.quote(guestArchive)) && "
            + "tar -czf \(GuestShell.quote(guestArchive)) "
            + "-C \(GuestShell.quote(parent)) \(GuestShell.quote(name))",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw ExportError.archiveFailed }

        let directory = exportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(name).tar.gz")
        try await vm.copyOut(guestPath: guestArchive, to: destination)

        // The guest copy is a second copy of the project; the host has it now.
        _ = try? await vm.run("rm -f \(GuestShell.quote(guestArchive))", environment: nil) { _ in }
        XForgeLog.note("export: \(name) archived to \(destination.lastPathComponent)")
        return destination
    }

    enum ExportError: LocalizedError {
        case archiveFailed

        var errorDescription: String? {
            switch self {
            case .archiveFailed:
                return "The project could not be archived inside the embedded Linux. "
                    + "The Terminal tab has the guest's own output."
            }
        }
    }
}
