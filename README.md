# XForge

**Build iOS apps on your iPhone — powered by [xtool](https://github.com/xtool-org/xtool).**

XForge embeds a real Linux userspace (running xtool + a Swift toolchain) inside an iOS
app. You author SwiftPM packages in the SwiftUI shell, and compile them into real,
signed iOS `.ipa` files entirely on-device.

The Linux engine is **[ish-arm64](https://github.com/OpenMinis/ish-arm64)** — a real Linux
kernel + aarch64 emulator running **in-process** on iOS. Its aarch64 backend dispatches
guest instructions to pre-compiled "gadget" functions instead of emitting machine code,
so it needs no JIT entitlement and works in a sideloaded app. The Alpine aarch64 root filesystem ships
**inside the app**, so there is nothing to download after install.

> **Status: active.** The SwiftUI shell, build pipeline, and CI are in place, and the
> embedded Linux is ish-arm64 with a bundled Alpine rootfs that already carries the
> build toolchain — xtool, the Swift toolchain and the `darwin` Swift SDK are in the
> root the app unpacks, so there is nothing to provision before the first build. The
> remaining work is wiring signing — see [Docs/DESIGN.md](Docs/DESIGN.md).

## Why this works

`xtool dev build` is SwiftPM cross-compilation to `arm64-apple-ios` using a Swift SDK
named `darwin`. All three heavyweight pieces are self-contained Linux artifacts:

| Piece | Source | Notes |
|---|---|---|
| Linux engine | ish-arm64 (`Vendor/ish-arm64` submodule), built for iOS | runs in-process, no JIT entitlement |
| Alpine aarch64 rootfs | `alpine-rootfs.zip` (Alpine 3.21, engine `fakefs`) | **bundled in the app**, unpacked on first boot; pinned by release tag |
| Swift aarch64 Linux toolchain | swift.org, via `swiftly` | **in the bundled root**, installed at build time by `install-toolchain.sh` |
| `xtool` aarch64 binary | prebuilt `xtool-aarch64.AppImage` | **in the bundled root** |
| `darwin` Swift SDK (arm64-apple-ios) | XForge's `darwin-sdk-<n>` release | **in the bundled root**; the Toolchain screen can also install one from your own `Xcode.xip` |

The bundled root is **provisioned**: it is built by running the guest's own
installer (`EmbeddedLinux/install-toolchain.sh`) in a chroot of the root being
built, so the app unpacks a guest that already has xtool, the Swift toolchain and
the Darwin SDK — the whole chain is exercised on a build machine with a real CPU
and a fast network, once, instead of on a phone under emulation. Everything is
installed *before* the fakefs conversion, because the conversion indexes the tree
and anything added afterwards is on disk and invisible to the guest. The archive
is then converted to the engine's `fakefs` format, so the app only unzips.

That makes the artifact ~1.6 GB, which is the price of arriving ready to build.
`EmbeddedLinux/build-rootfs.sh` takes `XFORGE_PROVISION=none` for a plain few-MB
Alpine root where the guest provisions itself on demand — the same script, the
same installer, run in the guest instead of at build time. The build also drops
what an iOS build never loads (the static Linux stdlib, lldb, the editor tooling,
and every download cache) and then *verifies the result compiles a Swift
program*, so a slimmed toolchain fails the build rather than a user's first build.

## Repo layout

```
App/                    SwiftUI app — project editing, build pipeline, signing
App/EmbeddedVM/         ish-arm64 bridge: ISHEmulator, C shim, rootfs unpack
App/Build/              BuildExecutor protocol + EmbeddedLinuxExecutor, IPABuilder
App/Models/             pipeline, history, project store, XcodeProject (reads .xcodeproj)
App/NativeToolchain/    in-process Clang/LLD bridge + host-side Darwin SDK store
App/Services/           auth/signing/device seams, downloads, toolchain components
App/Views/              screens: Projects, Build, Toolchain, Terminal, Settings
Vendor/ish-arm64/       git submodule: the embedded Linux engine
Vendor/NativeToolchain/ where an installed LLVM/Clang bundle goes (empty by default)
EmbeddedLinux/          build-rootfs.sh, build-ish-core.sh, install-toolchain.sh
NativeToolchain/        prepare-xcode.sh (wires a vendor bundle into the project)
Support/                entitlements, assets, Resources/ (bundled rootfs)
Tools/                  gen-appicon.py, the engine smoke harness, rootfs test
project.yml             XcodeGen definition
.github/workflows/      build-ipa.yml (the IPA), build-rootfs.yml (the pinned root),
                        native-toolchain.yml (the iOS LLVM cross-build)
Docs/DESIGN.md                  full architecture write-up
Docs/ISH-ARM64-INTEGRATION.md   the engine integration vs. its reference implementation
Docs/IPA-BUILD.md               the build pipeline and its stages
Docs/XCODE-ALTERNATIVE.md       what building existing Xcode projects on-device takes
Docs/NATIVE-TOOLCHAIN.md        the in-process LLVM/Clang/LLD path
CHANGELOG.md            what changed, release by release
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
ninja (for the ish-arm64 core).

```bash
brew install xcodegen meson ninja llvm lld libarchive

# One-time: engine sources, bundled rootfs, then the iOS engine libraries.
make bootstrap

make gen && open XForge.xcodeproj
```

`make bootstrap` runs three steps:

1. `git submodule update --init --depth 1 Vendor/ish-arm64` — the engine sources
   (plus its `deps/libarchive` submodule, which the fakefs tools link against).
2. `EmbeddedLinux/build-rootfs.sh` — builds the Alpine aarch64 rootfs into
   `Support/Resources/` so it is bundled into `XForge.app`. It shapes a plain
   Alpine minirootfs, installs the glibc layer and the build toolchain into a
   chroot of it (needs root: a chroot needs mounts), and converts the result to
   the engine's fakefs format *on this machine*, so the app only has to unzip it.
   `build-ipa.yml` downloads the published copy instead of rebuilding it — see
   `EmbeddedLinux/build-rootfs.sh` and `build-rootfs.yml`. A local build without
   root or without room for the toolchain can use `XFORGE_PROVISION=none`.
3. `EmbeddedLinux/build-ish-core.sh` — builds the engine's static libraries into
   `Vendor/ish-arm64-build/lib` for the linker. This step needs macOS: the
   aarch64 gadgets use `.req` register aliases that only clang's assembler
   accepts.

The engine is device-only; simulator builds (and `make test`) compile a stub instead
and need none of the above beyond a plain `make gen`.

Or build the unsigned IPA for sideloading via GitHub Actions
(`.github/workflows/build-ipa.yml`) and install it with SideStore/AltStore.

## On-device build pipeline

1. **Embedded Linux** — ish-arm64 boots the bundled Alpine aarch64 rootfs, which is
   already in the engine's `fakefs` format and is unpacked on first use.
2. **Toolchain** — nothing to do: the bundled root already carries the apk build
   dependencies, the glibc compatibility layer, xtool, the Swift toolchain and the
   Darwin SDK, all installed at build time. The Toolchain screen verifies them and
   can install any of them into a guest that lacks one
   (`sh /root/install-toolchain.sh all`, `sh /root/install-toolchain.sh sdk`), and
   can replace the Darwin SDK with one built from your own `Xcode.xip`.
3. **Build** — `xtool dev build -s -i` runs in the guest; the `.ipa` is copied back out.
4. **Signing** — export the unsigned `.ipa` to SideStore/AltStore or another signing
   service. Direct free-Apple-ID signing through XKit remains planned.

## Roadmap

- [x] Embedded Linux engine: ish-arm64 built for iOS, running in-process
- [x] Alpine aarch64 rootfs bundled in the app and imported on first boot
- [x] Provisioned Alpine rootfs — bundled with the build dependencies, the glibc
      layer, xtool, the Swift toolchain and the Darwin SDK, all installed at build
      time; the Toolchain screen can still install or replace any of them in-guest
- [ ] XKit signing (free Apple ID) wired into the export flow
- [ ] Hand-off of built `.ipa` to SideStore/AltStore for install
- [ ] `RemoteExecutor` (build server) for fast compilation of real apps

## Licence note

XForge links the engine's core. That core is GPLv2/GPLv3 depending on which guest
architectures and native programs are compiled in. XForge builds it with native
bash/zsh/dash/helix **disabled** and only the arm64 guest, which keeps the linked
subset to the engine's own GPLv2 kernel code. If you redistribute XForge you must comply
with those terms; see [the engine's README](https://github.com/OpenMinis/ish-arm64) for the
full breakdown.
