# XForge

**Build iOS apps on your iPhone — powered by [xtool](https://github.com/xtool-org/xtool).**

XForge embeds a real Linux userspace (running xtool + a Swift toolchain) inside an iOS
app. You author SwiftPM packages in the SwiftUI shell, and compile them into real,
signed iOS `.ipa` files entirely on-device.

The Linux engine is **[iSH-AOK](https://github.com/emkey1/ish-AOK)** — a real Linux
kernel + aarch64 emulator running **in-process** on iOS. Its "gadget JIT" needs no JIT
entitlement, so it works in a sideloaded app. The Alpine aarch64 root filesystem ships
**inside the app**, so there is nothing to download after install.

> **Status: active.** The SwiftUI shell, build pipeline, and CI are in place, and the
> embedded Linux is now iSH-AOK with a bundled Alpine rootfs. The remaining work is
> in-guest toolchain provisioning (Swift + xtool + the `darwin` Swift SDK) and wiring
> signing — see [Docs/DESIGN.md](Docs/DESIGN.md).

## Why this works

`xtool dev build` is SwiftPM cross-compilation to `arm64-apple-ios` using a Swift SDK
named `darwin`. All three heavyweight pieces are self-contained Linux artifacts:

| Piece | Source | Notes |
|---|---|---|
| Linux engine | iSH-AOK (`Vendor/ish-AOK` submodule), built for iOS | runs in-process, no JIT entitlement |
| Alpine aarch64 rootfs | `alpine-minirootfs-3.23.3-aarch64-provisioned.tar.gz` | **bundled in the app**, imported on first boot |
| Swift aarch64 Linux toolchain | swift.org, via `swiftly` | **already installed in the bundled rootfs** |
| `darwin` Swift SDK (arm64-apple-ios) | built from Xcode in CI, hosted as a release | fetched by the app on first use — **not bundled** (`include_darwin_sdk=1` bakes it in) |
| `xtool` aarch64 binary | prebuilt `xtool-aarch64.AppImage` | **already installed in the bundled rootfs** |

The provisioning happens at **build** time, not on the device (the darwin SDK
excepted — the app fetches that on first use unless `include_darwin_sdk=1`):
`EmbeddedLinux/build-rootfs-payload.sh` unpacks the plain Alpine minirootfs on an
arm64 Linux host, runs the app's own `EmbeddedLinux/install-toolchain.sh` inside a
`chroot` of it, and packs the result as the `-provisioned` archive above. There is
no second implementation that could drift from what a device installs, and an app
built this way has nothing left to download — it even builds offline.

## Repo layout

```
App/                    SwiftUI app — project editing, build pipeline, signing
App/EmbeddedVM/         iSH-AOK bridge: ISHAOKEmulator, C shim, rootfs import
App/Build/              BuildExecutor protocol + EmbeddedLinuxExecutor
Vendor/ish-AOK/         git submodule: the embedded Linux engine
EmbeddedLinux/          fetch-rootfs.sh, build-ish-aok-core.sh, install-toolchain.sh
Support/                Info.plist, entitlements, Resources/ (bundled rootfs)
project.yml             XcodeGen definition
.github/workflows/      unsigned-ipa.yml + build-darwin-sdk.yml
Docs/DESIGN.md          full architecture write-up
```

## App information

Everything about the app's identity lives in the project-level `settings` block of
`project.yml`:

| Field | Value |
|---|---|
| Bundle identifier | `com.r0gueee.xforge` |
| Display name | `XForge` |
| Apple team | set in `XFORGE_DEVELOPMENT_TEAM` (a wildcard `TEAMID.*` profile, so any bundle ID works) |
| Marketing version | `XFORGE_MARKETING_VERSION` |
| Build number | `XFORGE_BUILD_NUMBER` |
| App icon | `Support/Assets.xcassets/AppIcon.appiconset` |
| Accent colour | `Support/Assets.xcassets/AccentColor.colorset` |

The `XFORGE_*` settings feed `Info.plist` (`CFBundleDisplayName`, the version keys)
and the signing configuration (`DEVELOPMENT_TEAM`), so changing the app's identity
is a one-line edit. CI asserts bundle ID, display name, version and a wired-up icon
on every build, so a regression fails the build rather than shipping.

`Support/Info.plist` is **generated** by XcodeGen from the target's
`info.properties` and is gitignored — edit `project.yml`, not the plist. (XcodeGen
would otherwise write its own hardcoded `1.0`/`1` version, which is why the version
is set explicitly in `info.properties`.)

Signing: `CODE_SIGN_STYLE` is `Automatic` with the team above, so opening the
project in Xcode and building to a device signs normally. The CI workflow passes
`CODE_SIGNING_ALLOWED=NO` to produce an unsigned IPA for sideloading.

The app icon is generated from `Tools/gen-appicon.py` (a terminal-prompt motif in
the forge palette) and written into the asset catalog:

```bash
make icon        # rewrites Support/Assets.xcassets
```

## Build the app

Requires macOS + Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen), meson and
ninja (for the iSH-AOK core).

```bash
brew install xcodegen meson ninja llvm lld libarchive

# One-time: engine sources, bundled rootfs, then the iOS engine libraries.
make bootstrap

make gen && open XForge.xcodeproj
```

`make bootstrap` runs three steps:

1. `git submodule update --init --depth 1 Vendor/ish-AOK` — the engine sources.
2. `EmbeddedLinux/fetch-rootfs.sh` — puts the Alpine aarch64 rootfs into
   `Support/Resources/` so it is bundled into `XForge.app`. With
   `XFORGE_ROOTFS=auto` (the default) it prefers the **provisioned** payload
   published by the `Build rootfs payload` workflow, which already contains the
   toolchain; `XFORGE_ROOTFS=plain` takes the small minirootfs instead and leaves
   the toolchain to be installed on the device.
3. `EmbeddedLinux/build-ish-aok-core.sh` — builds the engine's static libraries into
   `Vendor/ish-AOK-build/lib` for the linker.

To build the payload yourself (arm64 Linux, as root — it chroots into the rootfs
and runs the guest's arm64 binaries there):

```bash
sudo make payload                 # → dist/alpine-minirootfs-3.23.3-aarch64-provisioned.tar.gz
#   sudo XFORGE_INCLUDE_SDK=1 make payload       # ... with the darwin SDK in it
XFORGE_ROOTFS=payload XFORGE_ROOTFS_ARCHIVE=dist/*-provisioned.tar.gz \
  bash EmbeddedLinux/fetch-rootfs.sh
```

The engine is device-only; simulator builds (and `make test`) compile a stub instead
and need none of the above beyond a plain `make gen`.

Or build the unsigned IPA for sideloading via GitHub Actions
(`.github/workflows/unsigned-ipa.yml`) and install it with SideStore/AltStore.

## On-device build pipeline

1. **Embedded Linux** — iSH-AOK boots the bundled Alpine aarch64 rootfs (imported into
   its `fakefs` format on first launch).
2. **Toolchain** — `EmbeddedLinux/install-toolchain.sh` provisions Swift + xtool in the
   guest; the `darwin` SDK is fetched on first use and `swift sdk install`ed in-guest.
3. **Build** — `xtool dev build -s -i` runs in the guest; the `.ipa` is copied back out.
4. **Signing** — free Apple ID via XKit; hand the `.ipa` to SideStore for install.

## Roadmap

- [x] Embedded Linux engine: iSH-AOK built for iOS, running in-process
- [x] Alpine aarch64 rootfs bundled in the app and imported on first boot
- [x] Toolchain provisioning — at build time, into the bundled rootfs
      (`EmbeddedLinux/build-rootfs-payload.sh`); in-guest install remains as the
      fallback for a plain rootfs
- [ ] XKit signing (free Apple ID) wired into the export flow
- [ ] Hand-off of built `.ipa` to SideStore/AltStore for install
- [ ] `RemoteExecutor` (build server) for fast compilation of real apps

## Licence note

XForge links iSH-AOK's core. That core is GPLv2/GPLv3 depending on which guest
architectures and native programs are compiled in. XForge builds it with native
bash/zsh/dash/helix **disabled** and only the arm64 guest, which keeps the linked
subset to iSH-AOK's own GPLv2 kernel code. If you redistribute XForge you must comply
with those terms; see [iSH-AOK's README](https://github.com/emkey1/ish-AOK) for the
full breakdown.
