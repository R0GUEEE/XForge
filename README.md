# XForge

**Build iOS apps on your iPhone — powered by [xtool](https://github.com/xtool-org/xtool).**

XForge embeds a Linux userspace (running xtool + a Swift toolchain) inside an iOS app.
You author SwiftPM packages in the SwiftUI shell, and compile them into real, signed
iOS `.ipa` files entirely on-device.

> **Status: scaffolding.** This is the architecture-A (fully on-device) build, from
> scratch, sideload-only. The native SwiftUI shell, build pipeline, and CI are in place.
> The long pole — the embedded Linux userspace with Swift + xtool + the `darwin` Swift
> SDK — is the active work (see [Docs/DESIGN.md](Docs/DESIGN.md)).

## Why this works

`xtool dev build` is SwiftPM cross-compilation to `arm64-apple-ios` using a Swift SDK
named `darwin`. All three heavyweight pieces are self-contained Linux artifacts:

| Piece | Source | Size |
|---|---|---|
| Swift aarch64 Linux toolchain | swift.org | ~700 MB |
| `darwin` Swift SDK (arm64-apple-ios) | built from Xcode in CI, hosted as a release | multi-GB |
| `xtool` aarch64 binary | prebuilt `xtool-aarch64.AppImage` | 51 MB |

## Repo layout

```
App/                    SwiftUI app — project editing, build pipeline, signing
App/EmbeddedVM/         LinuxVM bridge + host-side VM controller (skeleton)
App/Build/              BuildExecutor protocol + EmbeddedLinuxExecutor
EmbeddedLinux/          guest-side toolchain/SDK install script
Support/                Info.plist, entitlements
project.yml             XcodeGen definition
.github/workflows/      unsigned-ipa.yml + build-darwin-sdk.yml
Docs/DESIGN.md          full architecture write-up
```

## Build the app

Requires macOS + Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open XForge.xcodeproj
```

Or build the unsigned IPA for sideloading via GitHub Actions
(`.github/workflows/unsigned-ipa.yml`) and install it with SideStore/AltStore.

## On-device build pipeline (in progress)

1. **Embedded Linux userspace** — bundle a bootable aarch64 Linux with Swift + xtool.
2. **`darwin` SDK** — fetch the hosted SDK bundle on first use; `swift sdk install` in-guest.
3. **VM bridge** — boot the guest, stream commands, copy the `.ipa` back out.
4. **Signing** — free Apple ID via XKit; hand the `.ipa` to SideStore for install.

## Roadmap

- [ ] Embedded Linux userspace (Swift toolchain + xtool + SDK) assembled & bootable
- [ ] `LinuxVM.run/copyOut/copyIn` implemented over the guest bridge
- [ ] `darwin` SDK fetched on-demand from CI-hosted release
- [ ] XKit signing (free Apple ID) wired into the export flow
- [ ] Hand-off of built `.ipa` to SideStore/AltStore for install
- [ ] `RemoteExecutor` (build server) for fast compilation of real apps
