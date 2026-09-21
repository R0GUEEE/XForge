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

## 1b. The userspace is **plain Alpine aarch64**, bundled as a fakefs ZIP

The embedded Linux boots the official **Alpine Linux aarch64 minirootfs**:

```
https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz
```

- `EmbeddedLinux/build-rootfs.sh` downloads that archive, converts it to the
  engine's `fakefs` format with the engine's own `tools/fakefsify`, configures the
  root (mount points, `/etc/passwd`, `/etc/profile`, `/etc/motd`,
  `/etc/apk/repositories`, a default `/etc/resolv.conf`), and packs it as
  `alpine-rootfs.zip`.
- **The conversion happens at build time, not in the app.** `fakefsify` runs on
  the build machine, so the ZIP already *is* a fakefs — a `data/` tree plus
  `meta.db` — and first launch costs an unzip rather than an import of thousands
  of files into SQLite on a phone. This is the same layout OpenMinis ships, and
  it is why `App/EmbeddedVM/RootfsInstaller.swift` uses `unzip` and then
  `mount_root` instead of `fakefs_import`.
- **The root is small and pre-provisioned only where it matters.** Swift and
  xtool are *not* in it — the guest installs them on demand with
  `install-toolchain.sh` — which is what keeps the artifact ~95 MB instead of
  ~1.4 GB. The **glibc compatibility layer is** included: every tool XForge
  builds with is a glibc binary (xtool is a Swift program built on Ubuntu, and so
  is the toolchain), Alpine is musl, and `gcompat` is not enough for them. Baking
  that layer in removes the most failure-prone step of an on-device provision
  (a package renamed between Ubuntu releases yields a layer that loads but cannot
  resolve a symbol, which surfaces much later inside a tool).
- **The layer is installed before the fakefs conversion, and that ordering is
  load-bearing.** `fakefsify` writes `meta.db` as an index of the tree as it
  stands, and the engine resolves files through the database rather than by
  scanning `data/`. Installing the layer *after* conversion therefore produces a
  root where the files are on disk and completely invisible in the guest — 568
  files present, zero rows in `meta.db`. `build-rootfs.sh` asserts the layer is
  indexed before it packs.
- The trade is that a fresh install must still provision once, in the guest,
  before it can build anything.
- Because the root is small, it is stored as a **pinned release asset**
  (`rootfs-v1`) rather than rebuilt per IPA run. `build-ipa.yml` downloads it and
  verifies its sha256; `build-rootfs.yml` rebuilds and republishes it when the
  Alpine base or the root's configuration changes. Committing it to git is not an
  option — GitHub rejects any file over 100 MB in a push, though at a few MB this
  root would fit if that were ever preferable.
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
    Alpine/ish-arm64-style rootfs
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

## 4b. The Linux engine is **ish-arm64** (in-process, no subprocesses)

**iOS cannot spawn subprocesses** (no `fork`/`exec`/`posix_spawn` in the app sandbox),
so the embedded Linux cannot run as a child process. It runs **in-process** as a
library. XForge uses [ish-arm64](https://github.com/OpenMinis/ish-arm64) for this:
it is a real Linux kernel + aarch64 emulator whose threaded-code interpreter
dispatches each guest instruction to a pre-compiled "gadget" function. It emits
**no machine code** and needs no executable memory, so it requires **no JIT
entitlement** and works in a sideloaded app. ish-arm64 is vendored as the
`Vendor/ish-arm64` git submodule and built for iOS by
`EmbeddedLinux/build-ish-core.sh`.

That build requires **clang**: the aarch64 gadget sources alias registers with
`.req` (`_cpu .req x1`, `_pc .req x28`, …) and then use those names as operands,
which only clang's integrated assembler accepts — GNU `as` rejects every such
instruction. This is why the engine is built on a macOS runner rather than on
Linux, and why `build-ish-core.sh` probes for that capability up front instead
of failing with a wall of assembler errors.

```
BuildExecutor (EmbeddedLinuxExecutor)
      │  drives
      ▼
LinuxVM  (EmbeddedLinuxVM)      ← command/file bridge, runs on MainActor
      │  run / copyIn / copyOut
      ▼
LinuxEmulator (protocol)        ← in-process execution engine
   └─ ISHEmulator            ← drives the embedded ish-arm64 core
      │  one dedicated serial queue (the engine's `current` is thread-local)
      ▼
ISHBridge.c                  ← plain-C shim (bridging header → Swift)
      │
      ▼
libish + libish_emu + libfakefs + fakefs_import   (built from Vendor/ish-arm64)
```

- the engine's primitive is one-shot command capture
  (`run_guest_command_capture_shell`), so `LinuxVM.run` executes a command and
  forwards its merged stdout+stderr; `copyIn`/`copyOut` still move files via
  base64 over the guest shell.
- **Boot** (`ISHBridge.c`) mirrors ish-arm64's own app: mount the imported
  rootfs with `mount_root`, create init with `become_first_process`, then mount
  `/proc`, `/sys`, `/dev/pts`. It does *not* run `/sbin/init` — XForge runs build
  commands as fresh children of init, which is all the headless runner needs.
- The engine is built for the iOS **device** (arm64) only. Simulator builds (used
  by unit tests) compile a stub in `ISHBridge.c` instead, so `make test` needs
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
.github/workflows/build-ipa.yml      # CI: build the ish-arm64 core + unsigned XForge.ipa
.github/workflows/build-rootfs.yml    # CI: build and publish the pinned Alpine rootfs
project.yml                          # XcodeGen definition
App/                                 # SwiftUI app sources (native shell)
App/EmbeddedVM/                      # LinuxVM bridge, ISHEmulator, C bridge, rootfs unpack
Support/                             # Info.plist, entitlements, Resources/ (bundled rootfs)
Vendor/ish-arm64/                      # git submodule: the embedded Linux engine
Vendor/ish-arm64-build/                # core static libs (built, gitignored)
EmbeddedLinux/                       # build-rootfs.sh, build-ish-core.sh, install-toolchain.sh
Docs/                                # this design doc + tutorials
```
