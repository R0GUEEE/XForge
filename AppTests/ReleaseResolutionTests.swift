import XCTest
@testable import XForge

/// Guards the release-asset resolution that caused "server errors" in the app.
///
/// The darwin SDK is published under its own `darwin-sdk-*` series, so
/// `releases/latest/download/<asset>` 404s whenever the newest release is an
/// XForge IPA. These tests pin the behaviour that replaced it.
///
/// The tests that lived beside these — the guest rootfs naming, the in-guest
/// toolchain manager, the embedded Linux executor — went with the guest.
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
        XCTAssertNil(url, "the guest rootfs is gone; nothing should resolve it")
    }

    func testUnwrapsTheCorrectXForgeRepo() {
        XCTAssertEqual(XForgeReleases.repository, "R0GUEEE/XForge")
    }
}
