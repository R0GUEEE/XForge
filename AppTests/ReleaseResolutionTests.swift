import XCTest
@testable import XForge

/// Guards the release-asset resolution that caused "server errors" in the app.
///
/// The darwin SDK is published under its own `darwin-sdk-*` series, so
/// `releases/latest/download/<asset>` 404s whenever the newest release is an
/// XForge IPA. These tests pin the behaviour that replaced it.
@MainActor
final class ReleaseResolutionTests: XCTestCase {

    private func asset(_ name: String, _ url: String) -> XForgeReleases.Asset {
        XForgeReleases.Asset(name: name, browserDownloadURL: URL(string: url)!)
    }

    private func release(_ tag: String, _ assets: [XForgeReleases.Asset]) -> XForgeReleases.Release {
        XForgeReleases.Release(tagName: tag, assets: assets)
    }

    /// Newest-first, like the GitHub API.
    private var fixtures: [XForgeReleases.Release] {
        [
            release("xforge-35", [asset("XForge-0.3.1-unsigned.ipa",
                                         "https://example.com/xforge-35/ipa")]),
            release("xforge-34", [asset("XForge-0.3.0-unsigned.ipa",
                                         "https://example.com/xforge-34/ipa")]),
            release("darwin-sdk-7", [
                asset("darwin.artifactbundle.tar.xz", "https://example.com/darwin-sdk-7/tar"),
                asset("darwin.artifactbundle.zip", "https://example.com/darwin-sdk-7/zip"),
            ]),
        ]
    }

    /// The bug: an IPA release is newest, so `latest/download` never finds the SDK.
    func testFindsSDKInOlderDarwinRelease() {
        let url = XForgeReleases.findAsset(
            in: fixtures,
            tagPrefix: XForgeReleases.darwinSDKTagPrefix,
            assetName: XForgeReleases.darwinSDKAssetName)
        XCTAssertEqual(url?.absoluteString, "https://example.com/darwin-sdk-7/zip")
    }

    func testPicksNewestMatchingRelease() {
        let releases = [
            release("darwin-sdk-9", [asset(XForgeReleases.darwinSDKAssetName, "https://example.com/9")]),
            release("darwin-sdk-7", [asset(XForgeReleases.darwinSDKAssetName, "https://example.com/7")]),
        ]
        let url = XForgeReleases.findAsset(
            in: releases,
            tagPrefix: XForgeReleases.darwinSDKTagPrefix,
            assetName: XForgeReleases.darwinSDKAssetName)
        XCTAssertEqual(url?.absoluteString, "https://example.com/9")
    }

    func testReturnsNilWhenAssetMissing() {
        let url = XForgeReleases.findAsset(
            in: [release("darwin-sdk-7", [asset("something-else.zip", "https://example.com/x")])],
            tagPrefix: XForgeReleases.darwinSDKTagPrefix,
            assetName: XForgeReleases.darwinSDKAssetName)
        XCTAssertNil(url)
    }

    func testNoMatchingSeriesReturnsNil() {
        let url = XForgeReleases.findAsset(
            in: fixtures,
            tagPrefix: "alpine-rootfs-",
            assetName: "alpine-rootfs.tar.xz")
        XCTAssertNil(url, "the rootfs is bundled in the app, not published as an asset")
    }

    func testUnwrapsTheCorrectXForgeRepo() {
        XCTAssertEqual(XForgeReleases.repository, "R0GUEEE/XForge")
    }
}

/// A `LinuxVM` that answers from a script, so the toolchain probes can be tested
/// without booting the real guest.
@MainActor
final class StubLinuxVM: LinuxVM {
    var isBooted = true
    var bootCount = 0
    /// Commands that should report success (exit 0).
    var succeeding: [String] = []
    private(set) var ranCommands: [String] = []

    func boot() async throws { bootCount += 1; isBooted = true }

    func prepareRootfs() async {}

    func run(
        _ command: String,
        environment: [String: String]?,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        ranCommands.append(command)
        return succeeding.contains(where: { command.contains($0) }) ? 0 : 1
    }

    func copyOut(guestPath: String, to hostURL: URL) async throws {}
    func copyIn(hostURL: URL, to guestPath: String) async throws {}
}

@MainActor
final class ToolchainManagerTests: XCTestCase {

    func testProbeFindsInstalledComponentsInTheGuest() async {
        let vm = StubLinuxVM()
        vm.succeeding = ["command -v swift", "command -v xtool", "swift sdk list"]
        let manager = ToolchainManager(vm: vm)

        await manager.refresh(probeGuest: true)

        XCTAssertTrue(manager.guestChecked)
        XCTAssertTrue(manager.isInstalled(.swift))
        XCTAssertTrue(manager.isInstalled(.xtool))
        XCTAssertTrue(manager.isInstalled(.sdk))
        XCTAssertEqual(vm.bootCount, 1, "probing should boot the guest exactly once")
    }

    func testProbeReportsMissingComponents() async {
        let vm = StubLinuxVM()
        vm.succeeding = []
        let manager = ToolchainManager(vm: vm)

        await manager.refresh(probeGuest: true)

        XCTAssertTrue(manager.guestChecked)
        XCTAssertFalse(manager.isInstalled(.swift))
        XCTAssertFalse(manager.isInstalled(.xtool))
        XCTAssertFalse(manager.isInstalled(.sdk))
    }

    func testRefreshWithoutProbeDoesNotBootOrInventGuestState() async {
        let vm = StubLinuxVM()
        vm.isBooted = false
        let manager = ToolchainManager(vm: vm)

        await manager.refresh()

        XCTAssertEqual(vm.bootCount, 0, "a plain refresh must not boot the guest")
        XCTAssertFalse(manager.guestChecked)
        XCTAssertFalse(manager.isInstalled(.swift))
    }

    func testEveryComponentIsAccountedFor() {
        // A component that is neither bundled nor guest-side would silently never
        // be checked; make sure the enum and the split stay in step.
        for component in ToolchainManager.Component.allCases {
            XCTAssertFalse(component.rawValue.isEmpty)
            XCTAssertFalse(component.blurb.isEmpty)
            XCTAssertFalse(component.icon.isEmpty)
        }
        XCTAssertFalse(ToolchainManager.Component.rootfs.livesInGuest)
        XCTAssertTrue(ToolchainManager.Component.swift.livesInGuest)
        XCTAssertTrue(ToolchainManager.Component.sdk.livesInGuest)
    }

    func testDownloadErrorsDescribeTheFailure() {
        let http = DownloadError.http(status: 404, url: URL(string: "https://example.com/a.zip")!)
        XCTAssertTrue(http.localizedDescription.contains("404"))
        XCTAssertTrue(http.localizedDescription.contains("a.zip"))

        let missing = DownloadError.assetNotFound("darwin.artifactbundle.zip in any darwin-sdk-* release")
        XCTAssertTrue(missing.localizedDescription.contains("darwin.artifactbundle.zip"))
    }

    func testXcodeImportUsesCurrentXtoolInstallFlow() async throws {
        let xip = FileManager.default.temporaryDirectory
            .appendingPathComponent("xforge-sdk-test-\(UUID().uuidString).xip")
        try Data().write(to: xip)
        defer { try? FileManager.default.removeItem(at: xip) }

        let vm = StubLinuxVM()
        vm.succeeding = ["xtool sdk install", "swift sdk list"]
        let manager = ToolchainManager(vm: vm)

        await manager.installSDKFromXcode(xip: xip)

        XCTAssertTrue(vm.ranCommands.contains { $0.contains("xtool sdk install") })
        XCTAssertFalse(vm.ranCommands.contains { $0.contains("xtool sdk build") })
        XCTAssertTrue(vm.ranCommands.contains { $0.contains("swift sdk list") })
    }
}
