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

## 1b. The userspace is **Alpine aarch64**, bundled in the app

The embedded Linux starts from the official **Alpine Linux arm64 minirootfs**:

```
https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz
```

- The release workflow runs `EmbeddedLinux/build-rootfs-payload.sh` on native
  arm64 Linux. It downloads that exact archive, installs the project build
  dependencies, Swift, and xtool, then bundles the provisioned archive into
  `XForge.app`.
- On first boot the archive is imported into iSH-AOK's `fakefs` format (a `data/` tree
  plus a `meta.db` SQLite database) inside the app container; every later launch reuses
  it. See `App/EmbeddedVM/RootfsInstaller.swift`.
- Because Swift and xtool are glibc binaries, payload provisioning installs the
  required glibc runtime under `/opt/glibc` in the otherwise-musl Alpine guest.
- `EmbeddedLinux/install-toolchain.sh` is idempotent and runs inside the guest
  during payload creation. The same component actions can repair or update an
  installed guest later.
- The multi-GB `darwin` SDK is *not* baked into the rootfs. The app resolves the
  newest `darwin-sdk-*` release asset and installs it on demand with SwiftPM.

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

## 4b. The Linux engine is **iSH-AOK** (in-process, no subprocesses)

**iOS cannot spawn subprocesses** (no `fork`/`exec`/`posix_spawn` in the app sandbox),
so the embedded Linux cannot run as a child process. It runs **in-process** as a
library. XForge uses [iSH-AOK](https://github.com/emkey1/ish-AOK) for this:
it is a real Linux kernel + aarch64 emulator whose "gadget JIT" needs **no JIT
entitlement**, so it works in a sideloaded app. iSH-AOK is vendored as the
`Vendor/ish-AOK` git submodule and built for iOS by
`EmbeddedLinux/build-ish-aok-core.sh`.

```
BuildExecutor (EmbeddedLinuxExecutor)
      │  drives
      ▼
LinuxVM  (EmbeddedLinuxVM)      ← command/file bridge, runs on MainActor
      │  run / copyIn / copyOut
      ▼
LinuxEmulator (protocol)        ← in-process execution engine
   └─ ISHAOKEmulator            ← drives the embedded iSH-AOK core
      │  one dedicated serial queue (iSH-AOK's `current` is thread-local)
      ▼
ISHAOKBridge.c                  ← plain-C shim (bridging header → Swift)
      │
      ▼
libish + libish_emu + libfakefs + fakefs_import   (built from Vendor/ish-AOK)
```

- iSH-AOK's primitive is one-shot command capture
  (`run_guest_command_capture_shell`), so `LinuxVM.run` executes a command and
  forwards its merged stdout+stderr; `copyIn`/`copyOut` still move files via
  base64 over the guest shell.
- **Boot** (`ISHAOKBridge.c`) mirrors iSH-AOK's own app: mount the imported
  rootfs with `mount_root`, create init with `become_first_process`, then mount
  `/proc`, `/sys`, `/dev/pts`. It does *not* run `/sbin/init` — XForge runs build
  commands as fresh children of init, which is all the headless runner needs.
- The engine is built for the iOS **device** (arm64) only. Simulator builds (used
  by unit tests) compile a stub in `ISHAOKBridge.c` instead, so `make test` needs
  neither the submodule nor the core libraries.

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
.github/workflows/unsigned-ipa.yml   # CI: build the iSH-AOK core + unsigned XForge.ipa
project.yml                          # XcodeGen definition
App/                                 # SwiftUI app sources (native shell)
App/EmbeddedVM/                      # LinuxVM bridge, ISHAOKEmulator, C bridge, rootfs import
Support/                             # Info.plist, entitlements, Resources/ (bundled rootfs)
Vendor/ish-AOK/                      # git submodule: the embedded Linux engine
Vendor/ish-AOK-build/                # core static libs (built, gitignored)
EmbeddedLinux/                       # fetch-rootfs.sh, build-ish-aok-core.sh, install-toolchain.sh
Docs/                                # this design doc + tutorials
```
