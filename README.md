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
| Provisioned Alpine aarch64 rootfs | `alpine-minirootfs-3.24.2-aarch64-provisioned.tar.gz` | **bundled in the app**, imported directly by the terminal on first boot |
| Swift aarch64 Linux toolchain | swift.org, via `swiftly` | installed in the bundled Alpine guest |
| `darwin` Swift SDK (arm64-apple-ios) | built from Xcode in CI, hosted as a release | optional, user-installed in Alpine |
| `xtool` aarch64 binary | prebuilt `xtool-aarch64.AppImage` | installed on demand in the bundled Alpine guest |

The IPA build provisions Alpine on a native arm64 Linux runner before packaging it.
That guest root includes the Alpine build dependencies, Swift, and `xtool`; the
embedded terminal imports it directly without downloading tools to the iOS host.
The Darwin SDK remains an explicit in-guest install.

## Repo layout

```
App/                    SwiftUI app — project editing, build pipeline, signing
App/EmbeddedVM/         iSH-AOK bridge: ISHAOKEmulator, C shim, rootfs import
App/Build/              BuildExecutor protocol + EmbeddedLinuxExecutor
Vendor/ish-AOK/         git submodule: the embedded Linux engine
EmbeddedLinux/          fetch-rootfs.sh, build-ish-aok-core.sh, install-toolchain.sh
Support/                Info.plist, entitlements, Resources/ (bundled rootfs)
project.yml             XcodeGen definition
.github/workflows/      unsigned-ipa.yml (builds and releases the IPA)
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
2. `EmbeddedLinux/fetch-rootfs.sh` — puts the provisioned Alpine aarch64 rootfs
   into `Support/Resources/` so it is bundled into `XForge.app`. The release
   workflow creates this payload first; use `XFORGE_ROOTFS=plain` only for a
   deliberately minimal development image.
3. `EmbeddedLinux/build-ish-aok-core.sh` — builds the engine's static libraries into
   `Vendor/ish-AOK-build/lib` for the linker.

The engine is device-only; simulator builds (and `make test`) compile a stub instead
and need none of the above beyond a plain `make gen`.

Or build the unsigned IPA for sideloading via GitHub Actions
(`.github/workflows/unsigned-ipa.yml`) and install it with SideStore/AltStore.

## On-device build pipeline

1. **Embedded Linux** — iSH-AOK boots the bundled provisioned Alpine aarch64 rootfs (imported
   into its `fakefs` format on first terminal use).
2. **Toolchain** — the payload build runs `EmbeddedLinux/install-toolchain.sh` inside
   Alpine before packaging, installing project dependencies and Swift in the guest;
   xtool and the darwin SDK remain explicit in-guest installs.
3. **Build** — `xtool dev build -s -i` runs in the guest; the `.ipa` is copied back out.
4. **Signing** — export the unsigned `.ipa` to SideStore/AltStore or another signing
   service. Direct free-Apple-ID signing through XKit remains planned.

## Roadmap

- [x] Embedded Linux engine: iSH-AOK built for iOS, running in-process
- [x] Alpine aarch64 rootfs bundled in the app and imported on first boot
- [x] Provisioned Alpine rootfs — bundled with project dependencies and Swift inside
      the guest; xtool and the optional Darwin SDK installer remain available in-guest
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
