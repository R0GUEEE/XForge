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

## 1b. The userspace is **Alpine aarch64 with the build toolchain in it**, bundled as a fakefs ZIP

The embedded Linux boots the official **Alpine Linux aarch64 minirootfs**:

```
https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz
```

- `EmbeddedLinux/build-rootfs.sh` downloads that archive, installs the guest's
  own packages into it with the guest's own `apk` (the shell session's: see
  *the console* below), **provisions the build toolchain into it by running the
  guest's own `install-toolchain.sh` in a chroot of the tree** (glibc layer, apk
  build dependencies, xtool, swiftly, the Swift toolchain, the Darwin SDK),
  configures the root (mount points, `/etc/passwd`, `/etc/profile`, `/etc/motd`,
  `/etc/apk/repositories`, a default `/etc/resolv.conf`), converts it to the
  engine's `fakefs` format with the engine's own `tools/fakefsify`, and packs it
  as `alpine-rootfs.zip`.
- **Provisioning is the same code path as the guest's, not a parallel one.** The
  script the build runs in the chroot is the script the app ships
  (`EmbeddedLinux/install-toolchain.sh`, staged at `/root/install-toolchain.sh`),
  invoked step by step: `deps`, `glibc`, `xtool`, `swiftly`, `swift`, `sdk`, then
  `verify`. A root provisioned on the build machine and one provisioned by hand
  in the Terminal therefore differ in nothing but where and when the work
  happened, and there is one implementation to keep correct.
- **The console is a root login session, and the root is what starts it.**
  `/etc/inittab` respawns `/sbin/xforge-login root` on `tty1`; that script (from
  `EmbeddedLinux/xforge-login`) reads root's shell out of `/etc/passwd` and execs
  it as a login shell, so the Terminal tab opens in the shell the root names —
  `/bin/bash` by default — and `apk add zsh` plus that field changes it. Busybox
  `login -f root` is deliberately not in this path: it authenticates, needs utmp
  and takes over the terminal, none of which this guest has, and none of which it
  can report failing.
- **The root therefore carries the session's dependencies**: `bash`,
  `coreutils`, `less` and `ncurses-terminfo` (`XFORGE_CONSOLE_PACKAGES`). The
  terminfo package is not optional detail — `/etc/profile` exports
  `TERM=xterm-256color`, and the *base* terminfo package does not contain the
  xterm entries, so without it every curses program in the guest runs against an
  unknown terminal.
- **`EmbeddedLinux/verify-rootfs.sh` runs the console program in a chroot of the
  root** and asserts which shell comes up, as a login shell, from the field in
  `/etc/passwd`. `build-rootfs.sh` runs it on the tree before conversion and
  `build-rootfs.yml` runs it on the published ZIP, so "the terminal works" is
  checked against the guest's own binaries rather than against the intent of the
  configuration that produced them.
- **The conversion happens at build time, not in the app.** `fakefsify` runs on
  the build machine, so the ZIP already *is* a fakefs — a `data/` tree plus
  `meta.db` — and first launch costs an unzip rather than an import of thousands
  of files into SQLite on a phone. This is the same layout OpenMinis ships, and
  it is why `App/EmbeddedVM/RootfsInstaller.swift` uses `unzip` and then
  `mount_root` instead of `fakefs_import`.
- **The root arrives ready to build.** Swift, xtool and the Darwin SDK *are* in
  it, installed before the conversion, which is what the artifact's size buys: the
  guest can run `xtool new` and build on first launch instead of provisioning
  itself under emulation first. `XFORGE_PROVISION=none` builds the plain
  few-MB root instead, where the guest installs the same things on demand with
  the same script. The **glibc compatibility layer** is included either way:
  every tool XForge builds with is a glibc binary (xtool is a Swift program built
  on Ubuntu, and so is the toolchain), Alpine is musl, and `gcompat` is not
  enough for them. Baking that layer in removes the most failure-prone step of an
  on-device provision (a package renamed between Ubuntu releases yields a layer
  that loads but cannot resolve a symbol, which surfaces much later inside a
  tool).
- **Everything — the layer, the toolchain, the SDK — is installed before the
  fakefs conversion, and that ordering is load-bearing.** `fakefsify` writes `meta.db` as an index of the tree as it
  stands, and the engine resolves files through the database rather than by
  scanning `data/`. Installing the layer *after* conversion therefore produces a
  root where the files are on disk and completely invisible in the guest — 568
  files present, zero rows in `meta.db`. `build-rootfs.sh` asserts the layer is
  indexed before it packs.
- **Slimming, then proof.** Before packing, the build drops what an iOS build
  never loads — the static *Linux* stdlib, lldb, the editor tooling (sourcekit-lsp,
  the index stores), and every download cache (the SDK archive, the Ubuntu `.deb`
  pile the glibc layer was built from, the apk index) — and then runs
  `install-toolchain.sh verify` with `XFORGE_VERIFY_COMPILE=1`, which *compiles
  and runs a Swift program* and whose verdict fails the build. Printing a version
  is not compiling; this is the check that makes slimming safe.
- **The root is a pinned release asset** (`rootfs-v5`) rather than rebuilt per IPA
  run. `build-ipa.yml` downloads it and verifies its sha256, and fails if the
  pinned root does not carry the toolchain its manifest claims; `build-rootfs.yml`
  rebuilds and republishes it when the Alpine base, the toolchain or the root's
  configuration changes. Committing it to git is not an option — GitHub rejects
  any file over 100 MB in a push, and this one is ~1.6 GB.
- **The Darwin SDK comes from XForge's own release** (`darwin-sdk-<n>`, built in CI
  with xtool from an Xcode.xip) for the bundled root, and it is recorded — the
  manifest names the tag and the sha256 of the bundle that went in, and the path
  SwiftPM installed it to. A user with their own Xcode.xip can still put a
  different one in: the Toolchain screen installs `xtool sdk install <xip>` and
  replaces whatever is there.

## 2. Where the `darwin` SDK comes from

`xtool sdk build <Xcode.xip>` produces the `darwin` SDK from a real Xcode — impossible
on a phone. Plan: **build the `darwin.artifactbundle` once in CI on a macOS runner**
(using xtool's own `SDKBuilder` from an Xcode install), then host it as a downloadable
artifact. That is what the bundled root contains: `EmbeddedLinux/build-rootfs.sh`
downloads the pinned `darwin-sdk-<n>` asset and installs it into the root being built.
For a guest that has none — a plain root, or a swap to a newer SDK — the Toolchain
screen resolves the newest `darwin-sdk-*` release, fetches it into the guest and runs
`swift sdk install` there.

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
    ├─ glibc compatibility layer (Ubuntu's, for the glibc tools below)
    ├─ Swift aarch64 Linux toolchain   ┐
    ├─ darwin Swift SDK                ├─ in the bundled root, installed at
    └─ xtool (aarch64)                 ┘  build time by install-toolchain.sh
                                          →  `xtool new` / `xtool dev build -s -i`
```

## 3b. What is backed up, and what is not

Everything XForge generates lives in `Documents` — which iOS backs up to iCloud and,
because the app declares `UIFileSharingEnabled`, shows in the Files app. Two kinds of
things live there and they want opposite treatment:

- **Regenerable**: the host-side downloads, staged build artifacts and the engine log.
  These are marked `isExcludedFromBackup` at launch (`XForgeEnvironment.prepareStorage`).
  Backing them up bloats every device backup with data the app can produce again — the
  storage guidelines forbid it, and a multi-gigabyte backup is what gets an app rejected.
- **Not regenerable**: the user's projects. They live *inside the guest filesystem's
  fakefs*, in the same opaque database as the rootfs — and with `XFORGE_PROVISION=all`
  that filesystem is now several gigabytes of toolchain. Nothing in the app can separate
  the two, so the guest filesystem is deliberately **not** excluded: the alternative is
  silently dropping user work from backups. The cost is a large backup; the mitigation
  is that `/host` (visible in the Files app) and the Terminal are how a project leaves
  the device. If projects ever need to be backed up cheaply, they have to live outside
  the fakefs — not inside it with a flag on the directory.

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
EmbeddedLinux/                       # build-rootfs.sh, build-ish-core.sh, install-toolchain.sh,
                                     # verify-rootfs.sh, xforge-login (installed into the guest)
Docs/                                # this design doc + tutorials
Docs/ISH-ARM64-INTEGRATION.md        # engine integration vs. OpenMinis's reference
```
