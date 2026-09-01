# XForge — build iOS apps on-device with xtool

Working title: **XForge**. An iOS app (sideload-only) that embeds a Linux userspace
running [xtool](https://github.com/xtool-org/xtool) + a Swift toolchain, so you can
author SwiftPM packages and compile them into real iOS apps entirely on your iPhone.

Status: Architecture A (fully on-device via embedded iSH-style Linux), built from
scratch, sideload-only.

---

## 1. How the build works (the mechanism)

`xtool dev build` is just an orchestration layer over **SwiftPM cross-compilation**:

1. SwiftPM (from the Linux Swift toolchain) compiles the SwiftPM package to
   `arm64-apple-ios` using a Swift SDK named **`darwin`** (installed via
   `swift sdk install`, SwiftPM's native mechanism).
2. xtool's `Packer` turns the `.app` bundle into a signed `.ipa` (zsign) with the
   right Info.plist, entitlements, and codesigning identity.
3. `XKit` (the library) talks to Apple Developer Services and devices natively on iOS.

So the iOS app needs three heavyweight pieces to *compile* (all Linux-side, all
self-contained, all fetchable):
- **Swift aarch64 Linux toolchain** (swift.org Ubuntu build) — compiler/clang/lld.
- **`darwin` Swift SDK bundle** for `arm64-apple-ios` — contains the iOS SDK (headers,
  .tbd stubs, module maps) + the iOS Swift stdlib. This is the big one (multi-GB).
- **`xtool` aarch64 binary** (the prebuilt `xtool-aarch64.AppImage`, 51 MB).

## 1b. The userspace is **Alpine aarch64**

The embedded Linux is **Alpine Linux arm64** (musl, ~8 MB base) — tiny enough to bundle
in the app, and the same distro family as iSH-AOK. Because Swift + xtool are glibc
binaries, the rootfs installs Alpine's `gcompat` + `libc6-compat` so they run on the
musl base.

- `EmbeddedLinux/build-rootfs.sh` assembles the rootfs (on a Linux host/CI): Alpine base
  + gcompat + Swift toolchain + xtool, ready to tar/xz and bundle.
- `EmbeddedLinux/install-toolchain.sh` runs *in the guest* for first-boot provisioning;
  it is idempotent and also fetches the darwin SDK if not already staged.
- The multi-GB `darwin` SDK is *not* baked into the rootfs — it's fetched on first use
  from the CI-hosted release and staged into `/opt/darwin.artifactbundle`.

## 2. Where the `darwin` SDK comes from

`xtool sdk build <Xcode.xip>` produces the `darwin` SDK from a real Xcode — impossible
on a phone. Plan: **build the `darwin.artifactbundle` once in CI on a macOS runner**
(using xtool's own `SDKBuilder` from an Xcode install), then host it as a downloadable
artifact. The app fetches it on first use (like Xcode is an optional install), stores it
in the app sandbox, and runs `swift sdk install` in the embedded Linux.

> Note: Apple also publishes official iOS Swift SDKs on swift.org, but they use the
> triple `aarch64-apple-ios` under a different bundle name. xtool hardcodes `darwin` +
> `arm64-apple-ios`, so we build our own `darwin` bundle to match xtool exactly.

## 3. App architecture

```
XForge.app
├─ Native iOS (SwiftUI, fast path)  ─────────────────────────────────────────
│   Project list / editor            — author SwiftPM packages
│   Package manifest editor          — Package.swift + Sources
│   Git integration                  — clone/push to GitHub
│   XKit signing                    — free Apple ID, Apple Developer Services
│   .ipa management                 — bundle, export, hand off to SideStore/AltStore
│   BuildExecutor protocol          — pluggable: Local (embedded iSH) | Remote (future)
│   Embedded Linux VM               — runs the compile sandbox
│
└─ Embedded Linux userspace (aarch64, inside the VM)  ────────────────────────
    Alpine/iSH-AOK-style rootfs
    ├─ Swift aarch64 Linux toolchain
    ├─ darwin Swift SDK (fetched on demand)
    └─ xtool (aarch64)  →  `xtool new` / `xtool dev build -s -i`
```

## 4. BuildExecutor abstraction

```swift
protocol BuildExecutor {
    func createProject(_ template: ProjectTemplate) async throws
    func build(_ project: Project, configuration: BuildConfiguration) async throws -> AsyncThrowingStream<BuildEvent, Error>
    func installSDK(_ source: SDKSource) async throws
    func fetchToolchain() async throws
}
```
- `EmbeddedLinuxExecutor`: drives the embedded VM via the `LinuxVM` bridge (below).
- `RemoteExecutor` (future): same interface over SSH/WebSocket to a build server.

## 4b. The `LinuxVM` bridge — in-process emulator (critical constraint)

**iOS cannot spawn subprocesses** (no `fork`/`exec`/`posix_spawn` in the app sandbox),
so the embedded Linux cannot run as a child process. It must run **in-process** as a
library — the same way tctiSH embeds `libqemu` and iSH runs its emulator as the app's
own code.

The bridge is split into two clean layers:

```
BuildExecutor (EmbeddedLinuxExecutor)
      │  drives
      ▼
LinuxVM  (EmbeddedLinuxVM)   ← command/file bridge, runs on MainActor
      │  talks to guest shell over a byte pipe
      ▼
LinuxEmulator  (protocol)    ← in-process execution engine
   ├─ EmbeddedQemuLinux     ← wraps libqemu (built by build-emulator.yml)
   └─ PendingLinuxEmulator  ← clear "not bundled yet" error
```

- `EmbeddedLinuxVM` sends commands + a `printf '…__XF_EXIT__%d' $?` sentinel to parse
  the guest exit code; `copyIn`/`copyOut` move files via base64 over the shell.
- `LinuxEmulator` is the seam any real emulator must satisfy (boot, byte-pipe I/O).
- The missing artifact is the emulator library itself, produced by
  `build-emulator.yml` (QEMU user-mode aarch64, tctiSH-style) and downloaded like the
  darwin SDK.

## 5. Delivery / sideload pipeline

- **CI (GitHub Actions, macOS runner)** builds the unsigned IPA (our proven pattern from
  SideStore / tctiSH), commits it to a release.
- **Device install**: user installs XForge via SideStore/AltStore (already built by user).
- **Built apps**: XForge produces `.ipa`s that are handed to SideStore to install on the
  same device.

## 6. Honest performance note

Swift compilation under JIT emulation is slow. Tiny SwiftUI apps (hello-world / toy
packages) build in minutes. Real-world apps are impractical on-device; that's why the
`RemoteExecutor` exists. XForge is a *demonstrator + authoring tool* for the on-device
path, with a fast remote path available later.

## 7. Repo layout

```
.github/workflows/unsigned-ipa.yml   # CI: build unsigned XForge.ipa
project.yml                          # XcodeGen definition
App/                                 # SwiftUI app sources (native shell)
Support/                             # Info.plist, entitlements
EmbeddedLinux/                       # rootfs/toolchain/SDK build scripts + bridge docs
Docs/                                # this design doc + tutorials
```
