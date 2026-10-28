# The Darwin SDK bundled inside the IPA

A released XForge IPA carries the Darwin SDK it compiles against. Without it, a
fresh install cannot build anything until it downloads ~456 MB, which makes
"install XForge, open a project, press Build" false on first use. With it, the
first launch unpacks the SDK once and the app is usable offline.

This document records what is bundled, how it is verified, what the app does with
it, and the licensing question that is **not** answered here.

## What ships

| | |
| --- | --- |
| Release | `darwin-sdk-7` in `R0GUEEE/XForge` |
| Asset | `darwin.artifactbundle.zip` |
| Archive size | **456,769,875 bytes** (435.6 MiB) |
| SHA-256 | `b44165c16a5cebf13ae85af4d630f49b863e342b84f864b4dc1bbba5789d4d9b` |
| Unpacked size | **1,454,092,849 bytes** (1.35 GiB) — sum of every ZIP entry |
| Layout | `darwin.artifactbundle/` at the archive root, plus a `__MACOSX/` metadata folder |
| Contents | `swift-sdk.json` declaring only `arm64-apple-ios`; `Developer/Platforms/iPhoneOS.platform` (SDK `iPhoneOS18.5.sdk`, headers, tbd stubs, `usr/lib`), `Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/{swift,swift_static,clang}` |
| SDK marker | `darwin.artifactbundle/darwin-sdk-version.txt` contains `develop` |

It is the same artifact the Toolchain screen's **Download the Darwin SDK** button
fetches from the `darwin-sdk-*` release series (`NativeSDK.install(fromRemote:)`),
produced by xtool's SDK builder from Xcode. XForge does not build it and does not
own it.

In the built app it lives at `BundledSDK/` (or, if Xcode emits the group layout,
`Resources/BundledSDK/`), next to `bundled-sdk.json`:

```json
{
  "schemaVersion": 1,
  "releaseTag": "darwin-sdk-7",
  "assetName": "darwin.artifactbundle.zip",
  "sourceURL": "https://github.com/R0GUEEE/XForge/releases/download/darwin-sdk-7/darwin.artifactbundle.zip",
  "sha256": "b44165c16a5cebf13ae85af4d630f49b863e342b84f864b4dc1bbba5789d4d9b",
  "byteCount": 456769875,
  "installedByteCount": 1454092849,
  "sdkVersion": "develop",
  "license": "Apple SDK content from Xcode; redistribution is governed by Apple's license terms and has NOT been verified — see Docs/BUNDLED-SDK.md",
  "generatedAt": "2026-10-28T06:08:37Z"
}
```

`installedByteCount` is measured from the archive's central directory, so the
space preflight on the device does not have to trust a hand-written estimate.

## How it gets there

- **CI (release path):** `.github/workflows/build-ipa.yml` runs
  `Tools/fetch-bundled-sdk.sh` before `xcodegen generate`. The step runs for
  `push` and for a `workflow_dispatch` with `bundle_darwin_sdk` (default **true**);
  `pull_request` builds skip it on purpose, because they are not delivered.
  `toolchain_tag`, `darwin_sdk_tag` and `darwin_sdk_sha256` inputs exist for a
  deliberate override; a tag that is not the pinned one **requires** a SHA-256.
- **Locally:** `make sdk-bundle` (or `Tools/fetch-bundled-sdk.sh`), then
  `xcodegen generate` and a normal build.
- **Offline:** `Tools/fetch-bundled-sdk.sh darwin-sdk-7 --file /path/to/darwin.artifactbundle.zip`
  still enforces size and digest.
- `BundledSDK/` is gitignored. `project.yml` declares it as a **folder reference**
  resource with `optional: true`, so a clone without it still generates and
  builds — the app then simply reports no bundled SDK.

The toolchain bundle (the compiler, linked into the binary) is still a separate
artifact: a build that is meant to compile needs **both**, which is why the IPA
workflow installs the toolchain for `push` as well, and a step fails the job if
`Support/NativeToolchain.generated.xcconfig` does not end up with
`XFORGE_HAS_LLVM=1`.

## What the app does

`App/NativeToolchain/BundledDarwinSDK.swift`:

1. **Discover** `BundledSDK/` under both `Bundle.main.resourceURL` and
   `Bundle.main.bundleURL` (and their `Resources/` subdirectory).
2. **Decide.** `decision(isInstalled:discovery:state:)` is a pure table:

   | installed | bundle | remembered | result |
   | --- | --- | --- | --- |
   | yes | any | any | `alreadyInstalled` — never touched |
   | no | none | any | `notBundled` |
   | no | archive without manifest | any | `unverified` — a button, not an automatic install |
   | no | verified | removed before | `declined` |
   | no | verified | attempted before | `previouslyAttempted` |
   | no | verified | fresh | `install` |

   State lives in `<Documents>/native-sdk/bundled-sdk-state.json`, outside the SDK,
   so removing the SDK does not erase the memory of *why*.
3. **Verify** byte count and SHA-256 of the archive against the manifest (streamed,
   4 MiB at a time) before anything is unpacked.
4. **Preflight** free space from the archive's own metadata
   (`uncompressedBytes(of:)`), plus 5 % (minimum 250 MB) headroom.
5. **Unpack** into `<Documents>/native-sdk/bundled-<uuid>/`, accepting the bundle
   at the root, the bundle's contents at the root, or one wrapper directory.
6. **Commit** with `NativeSDK.commit(preparedBundle:to:replacing:false)`:
   the staged bundle is moved into place only if the destination is still empty.
   If an SDK appeared meanwhile — a user import, or a build stage that won the
   race — the commit throws `destinationOccupied` and the existing SDK is
   untouched. The replacement path (`replacing: true`) is reserved for the
   confirmed "Reinstall" dialog, and swaps rather than deleting first.
7. **Validate** the installed tree with `NativeSDK.layout(at:)`, then record the
   attempt.

First-run installation is started from `RootTabView.task` through
`BundledSDKMonitor`, detached, with `InstallAssertion` holding the app awake. The
Toolchain screen observes the same monitor, shows progress, and re-reads the SDK
when it finishes.

## Safety properties (and their limits)

- An automatic install is only ever attempted when **nothing** is installed; it can
  never delete an SDK the user imported, downloaded or built from a `.xip`.
- The bundled archive inside the app bundle is read-only and is never deleted;
  the staging directory is removed on both paths.
- The Build pipeline (`BuildManager.ensureSDK`) prefers the bundled SDK and has
  **no silent network fallback**: if a bundle is present but uninstallable, the
  stage fails with that error rather than fetching a different artifact. Only a
  build that carries no bundle at all uses `XForgeReleases.darwinSDKURL()`.
- An attempt is recorded *before* extraction, so a failure does not become a
  multi-gigabyte retry on every launch. The cost: after a genuine failure (e.g. out
  of space) the automatic path stays quiet until the user taps "Install the bundled
  SDK" on the Toolchain screen.
- Removing the SDK records the tag as declined, so a relaunch does not put it back.
  A newer bundled release (different tag) still installs.

**Not fully solved:** an install that is interrupted by app suspension can leave a
`bundled-<uuid>/` staging directory behind; it is never mixed into the installed
SDK, but it is not reclaimed automatically. A partial *move* is not atomic across
a crash either — the destination can be missing after a crash between the two
moves of a replacement. Both are inherent to doing this on a phone without a
transactional filesystem.

## Licensing and redistribution — not settled here

`darwin.artifactbundle.zip` contains Apple SDK material: iPhoneOS headers, tbd
stubs, and Swift runtime/toolchain libraries taken from Xcode. Those come under
Apple's Xcode and Apple SDK license agreements, which restrict redistribution.
The archive is **already published** as a release asset in this repository; this
change additionally embeds it in the IPA.

What this repository asserts, and what it does not:

- It records provenance (release tag, source URL, size, SHA-256) so the artifact is
  identifiable and verifiable.
- It does **not** claim that bundling or redistributing this content is permitted,
  and it does not claim Apple has authorised it. That determination needs whoever
  owns the rights (and legal advice), not a README.
- Publishing is therefore off by default: the workflow's `release` input defaults
  to `false`, and the publish step also requires the `XFORGE_PUBLISH_RELEASES`
  repository variable to be `true`. Builds still upload the IPA as a workflow
  artifact, which stays within the repository's access controls but is still
  distribution to those who can download it.
- If the answer turns out to be "not permitted", the fallback is the pre-existing
  behaviour: ship without `BundledSDK/` and let the user fetch the SDK on the
  Toolchain screen (or import their own Xcode). `bundle_darwin_sdk: false` on a
  dispatch produces exactly that build. `Tools/fetch-bundled-sdk.sh` and
  `BundledDarwinSDK` can be removed without touching the compiler path.

## Tests

`AppTests/BundledDarwinSDKTests.swift` covers manifest decoding and schema
rejection, discovery (present/absent/unverified, both folder layouts), the full
decision table, state persistence, the SHA-256 vector, integrity failure, the
three archive layouts, and the commit safety properties (`destinationOccupied`
preserves the existing tree; `replacing: true` swaps).

What it does **not** cover, and why:

- A real 456 MB install and a device-side unpack: the simulator has no Darwin SDK
  and the test bundle cannot carry 1.35 GiB of fixtures.
- The Xcode build phase that copies `BundledSDK/` into the `.app`: that needs
  Xcode, so it is asserted in CI instead (`Verify the bundled SDK in the app`,
  then again in the final IPA).
- A first-run install on a real device, including the `InstallAssertion`
  behaviour when the screen locks.
