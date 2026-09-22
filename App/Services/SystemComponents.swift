import Foundation

/// The commands that install the embedded system's components, as commands.
///
/// Everything in the guest is managed *from the terminal*. That is deliberate:
/// the guest is a real Alpine system, and the tools that provision it are
/// ordinary Linux programs. XForge's job is to know the right commands, get the
/// user's files into the guest's own storage, and run them where the output can
/// be watched — not to reimplement them behind a button.
///
/// These strings are shared by the Terminal screen (its Components menu) and the
/// Toolchain screen, so both offer exactly the same thing.
@MainActor
enum SystemComponents {
    /// Where the guest's own copy of the provisioning script lives.
    static let guestInstallerScript = "/root/install-toolchain.sh"

    /// Where a user-supplied Xcode.xip is stored inside the guest filesystem.
    static let guestXIPDirectory = "/root/xforge/xip"

    /// xtool's Darwin-SDK cache inside the guest.
    static let guestSDKCache = "/root/.cache/xforge-sdk"

    enum Component: String, CaseIterable, Identifiable {
        case glibc
        case xtool
        case swift
        case darwinSDK

        var id: String { rawValue }

        var title: String {
            switch self {
            case .glibc: return "glibc compatibility layer"
            case .xtool: return "xtool"
            case .swift: return "Swift toolchain"
            case .darwinSDK: return "Darwin SDK"
            }
        }

        var detail: String {
            switch self {
            case .glibc:
                return "The glibc runtime xtool and the Swift toolchain link against (Alpine is musl)."
            case .xtool:
                return "xtool builds iOS apps from Swift packages on Linux."
            case .swift:
                return "Swift 6 for Linux, installed with swiftly from swift.org."
            case .darwinSDK:
                return "The arm64-apple-ios Swift SDK, built from your own Xcode.xip with xtool."
            }
        }
    }

    /// The one-line install for a component that is just a step of the bundled
    /// provisioning script.
    static func scriptCommand(_ component: Component) -> String {
        "sh \(guestInstallerScript) \(component.rawValue)"
    }

    /// The Swift toolchain, installed exactly the way swift.org documents it —
    /// the command the user would type into a Linux box.
    ///
    /// Two XForge-specific adjustments, both needed to run it in the guest:
    ///  - `swiftly init -y`, because there is no tty to answer its prompt (the
    ///    bridge runs one command, not an interactive session);
    ///  - the glibc layer first, because the toolchain swiftly installs is a
    ///    glibc build and this guest is musl.
    static var swiftInstallCommand: String {
        """
        sh \(guestInstallerScript) glibc && \
        cd /root && \
        curl -fLO https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && \
        tar zxf swiftly-$(uname -m).tar.gz && \
        ./swiftly init --quiet-shell-followup -y && \
        . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && \
        hash -r && \
        swift --version
        """
    }

    /// xtool installs with its own step (it needs the glibc layer, which the same
    /// script installs), then verifies itself.
    static var xtoolInstallCommand: String {
        """
        sh \(guestInstallerScript) glibc && \
        sh \(guestInstallerScript) xtool && \
        sh \(guestInstallerScript) verify
        """
    }

    /// The command that turns an Xcode.xip the user picked into an installed
    /// Darwin Swift SDK.
    ///
    /// The `.xip` is copied into the guest's *own* storage first (`/root/xforge`),
    /// and xtool is pointed at that path: xtool does the extraction and the SDK
    /// post-processing itself, so nothing has to be unpacked on the host.
    static func darwinSDKInstallCommand(guestXIPPath: String) -> String {
        "xtool sdk install \(GuestShell.quote(guestXIPPath)) && swift sdk list"
    }

    /// The prebuilt-bundle alternative, for when the user has no Xcode.xip to
    /// hand (it downloads XForge's own darwin.artifactbundle inside the guest).
    static func darwinSDKDownloadCommand(from url: URL) -> String {
        let archive = guestSDKCache + "/darwin-sdk.zip"
        let bundle = guestSDKCache + "/darwin.artifactbundle"
        return """
        set -eu
        mkdir -p \(GuestShell.quote(guestSDKCache))
        curl -fL --retry 3 \(GuestShell.quote(url.absoluteString)) -o \(GuestShell.quote(archive))
        rm -rf \(GuestShell.quote(bundle))
        unzip -q \(GuestShell.quote(archive)) -d \(GuestShell.quote(guestSDKCache))
        test -f \(GuestShell.quote(bundle))/info.json
        swift sdk install \(GuestShell.quote(bundle))
        rm -f \(GuestShell.quote(archive))
        swift sdk list
        """
    }

    // MARK: - Host → guest files

    /// Copy the bundled provisioning script into the guest, where the terminal's
    /// commands expect it.
    static func ensureInstallerScript(in vm: LinuxVM) async throws {
        guard let script = Bundle.main.url(forResource: "install-toolchain",
                                           withExtension: "sh") else {
            throw SystemComponentsError.installerScriptMissing
        }
        try await vm.copyIn(hostURL: script, to: guestInstallerScript)
    }

    /// Copy the bundled zsign installer into the guest.
    static func ensureZsignInstaller(in vm: LinuxVM) async throws {
        guard let script = Bundle.main.url(forResource: "install-zsign",
                                           withExtension: "sh") else {
            throw SystemComponentsError.zsignInstallerMissing
        }
        try await vm.run("mkdir -p /root/xforge", environment: nil) { _ in }
        try await vm.copyIn(hostURL: script, to: "/root/xforge/install-zsign.sh")
        guard let patch = Bundle.main.url(forResource: "patch-zsign-password-file",
                                          withExtension: "py") else {
            throw SystemComponentsError.zsignInstallerMissing
        }
        try await vm.copyIn(hostURL: patch, to: "/root/xforge/patch-zsign-password-file.py")
        let status = try await vm.run(
            "chmod 700 /root/xforge/install-zsign.sh && chmod 600 /root/xforge/patch-zsign-password-file.py",
            environment: nil
        ) { _ in }
        guard status == 0 else { throw SystemComponentsError.zsignInstallerMissing }
    }

    /// Copy the chosen `.xip` into the guest's own filesystem and return the path the guest should install from.
    static func stageXIP(_ source: URL, in vm: LinuxVM, report: @escaping (String) -> Void) async throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64 ?? 0
        if size > 0 {
            // The xip is copied *and* xtool expands it inside the guest, so the
            // guest needs room for both plus the installed SDK.
            let needed = size * 2 + 1_000_000_000
            let free = XForgeEnvironment.availableBytes
            if free > 0, free < needed {
                throw SystemComponentsError.notEnoughSpace(needed: needed, free: free)
            }
        }

        let guestPath = "\(guestXIPDirectory)/\(safeName(source.lastPathComponent))"
        report("creating \(guestXIPDirectory) in the guest filesystem")
        _ = try await vm.run("mkdir -p \(GuestShell.quote(guestXIPDirectory))", environment: nil) { _ in }

        report("copying \(source.lastPathComponent) into the guest (\(byteString(size)))")
        XForgeLog.note("components: copying \(source.lastPathComponent) to \(guestPath)")
        try await vm.copyIn(hostURL: source, to: guestPath)

        let guestSize = try await vm.run(
            "wc -c < \(GuestShell.quote(guestPath))",
            environment: nil
        ) { _ in }
        guard guestSize == 0 else {
            throw SystemComponentsError.copyFailed(guestPath)
        }
        return guestPath
    }

    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned)
        return result.isEmpty ? "Xcode.xip" : result
    }

    private static func byteString(_ size: Int64) -> String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "unknown size"
    }
}

enum SystemComponentsError: LocalizedError {
    case installerScriptMissing
    case zsignInstallerMissing
    case notEnoughSpace(needed: Int64, free: Int64)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .installerScriptMissing:
            return "install-toolchain.sh is not bundled in the app."
        case .zsignInstallerMissing:
            return "The guest zsign installer is not bundled in the app."
        case .notEnoughSpace(let needed, let free):
            let formatter = ByteCountFormatter()
            return "Not enough free space: this needs about "
                + "\(formatter.string(fromByteCount: needed)) and "
                + "\(formatter.string(fromByteCount: free)) is free."
        case .copyFailed(let path):
            return "The file did not arrive in the guest at \(path)."
        }
    }
}
