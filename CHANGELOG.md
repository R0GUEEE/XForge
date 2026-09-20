# Changelog

All notable changes to **XForge** are documented here.

## [0.5.0] — 2026-09-20 — Toolchain preinstalled

### Changed
- **The app now ships a *provisioned* Alpine rootfs, so there is nothing to
  install on the device.** The IPA bundles
  `alpine-minirootfs-3.23.3-aarch64-provisioned.tar.gz`: the Alpine aarch64
  release with the whole guest toolchain already in it — apk build dependencies
  (clang, lld, cmake, ninja, git, …), the glibc compatibility layer under
  `/opt/glibc`, the swift/swiftc/xtool wrappers, xtool unpacked in `/opt/xtool`,
  swiftly and the Swift toolchain, and the `darwin` Swift SDK when a
  `darwin-sdk-*` release has one. Importing it during the first launch is the
  only setup left, and the app can then build a project without a network.
- **Provisioning happens at build time**, in
  `EmbeddedLinux/build-rootfs-payload.sh`, on an arm64 Linux host: it chroots
  into the unpacked minirootfs and runs the app's *own*
  `EmbeddedLinux/install-toolchain.sh all` there, so there is no second
  implementation to drift from what a device installs. Every tool is then
  executed inside the finished rootfs and the result is written to
  `/usr/local/share/xforge/payload-manifest.txt` **inside** the archive, which is
  what the IPA build verifies before shipping it.
- `.github/workflows/unsigned-ipa.yml` builds that payload first (cached by a
  content key, so only a change to the provisioning pays for it) and then bundles
  it; `.github/workflows/build-rootfs-payload.yml` can also build and publish it
  on its own. `EmbeddedLinux/fetch-rootfs.sh` learned `XFORGE_ROOTFS=auto|payload|plain`.
- **Bundle identifier is now `com.r0gueee.xforge`** (was `org.xforge.XForge`), and
  the app version is 0.5.0 (8).

### Fixed
- **No guest command's output is sent to `/dev/null` any more.** iSH-AOK's arm64
  engine SIGKILLs a forked guest program whose stdout/stderr points at `/dev/null`,
  which made `apk info -e …`, `swift --version` and `xtool --version` die — that is
  what left a fully provisioned rootfs looking "not provisioned", and what a fresh
  install ran into at its very first step. Pipes and real files are safe, so
  silence now goes to a file (`/tmp/xforge-probe.log`, `$SILENT` in the guest
  script); the one remaining `/dev/null` is a shell `source`, which does not fork.

## [0.4.0] — 2026-09-20 — Toolchain installs, with progress

### Added
- **A determinate progress bar under the component being installed**, on both the
  Toolchain screen and Settings → Storage, with the step it is on ("Installing the
  glibc compatibility layer", "Downloading darwin.artifactbundle.zip (about
  456 MB)", …). The engine returns a guest command's output only when it finishes,
  so the install was split into steps — that is what makes a bar possible.
- **`install-toolchain.sh` now follows the tools' own instructions, as steps** the
  app drives one at a time (and that the Terminal can run by hand:
  `sh /root/install-toolchain.sh deps|glibc|xtool|swiftly|swift|verify|all`):
  base packages → glibc compatibility layer → **xtool** (the release asset
  `xtool-<arch>.AppImage`, unpacked once into `/opt/xtool`) → **swiftly** (the
  official installer) → **Swift toolchain** → verify.
- **A glibc compatibility layer is now a dependency.** Every one of these tools is
  a glibc binary and the guest is musl; `gcompat` alone is not enough (xtool dies
  on `strptime_l`, `fts_*`, `fcntl64`). The script extracts Ubuntu's own libc6 and
  its dependencies into `/opt/glibc` and runs the tools through that loader.
- **Darwin SDK from your own Xcode.xip**: pick the file in the app, it is staged
  into the shared folder and built in the guest with `xtool sdk build`, alongside
  the existing prebuilt download.
- **The verification step's verdict is shown per tool** — `xtool: ok 1.19.2`,
  `swift: not installed`, or *installed but does not run in this guest*, so
  "installed" and "works" are never confused.
- Downloads report byte progress and retry three times; the previous version could
  lose a 456 MB connection and give up.

### Changed
- **The Terminal keeps the shell's state**: the working directory survives `cd`
  between commands, history is recalled with ↑/↓ and persists across launches, and
  the scrollback is only cleared by Clear.

### Verified end to end, in a guest, before shipping
The host harness runs the same steps the app runs, in a booted guest on CI, and
then tries to *run* what they installed:

```
XFORGE-VERIFY  xtool    ok   xtool 1.19.2
XFORGE-VERIFY  swift    ok   Swift version 6.4 (swift-6.4-RELEASE)
                             Target: aarch64-unknown-linux-gnu
XFORGE-VERIFY  swiftly  ok   1.1.4
```

`xtool --version` and `swift --version` both exit 0 in the guest. Getting there
took three fixes the harness caught in a row: swiftly refuses to install without
gpg; it leaves the toolchain unlinked; and — the big one — running a tool *through*
the glibc loader only covers the first process, because a child (swift-frontend,
swift-build) starts from its own ELF interpreter. The glibc layer is now wired in
as the system's glibc (`/lib/ld-linux-<arch>.so.1`, the loader's multiarch
directories, and the `/lib/lib*.so.*` names), which Alpine's own musl programs do
not use.

Timing, from the CI runs: the whole provisioning is about 20 minutes on a fast
host, most of it Swift 6.4.0 (1058 MiB) downloading and unpacking inside the guest.

### Known gap
`swift --version` still prints `warning: libc not found for
'aarch64-unknown-linux-gnu'; C stdlib may be unavailable` — Swift looks for the
glibc *development* files (headers and crt objects), which the layer does not carry
yet. Harmless for running the tools; it may matter for a build that compiles C, and
that is the next thing to check with a real `xtool dev build`.

## [0.3.4] — 2026-09-20 — Network access for the guest

Three fixes, all from the engine log of a real device install attempt.

### Fixed
- **The guest could not resolve anything even with a correct `/etc/resolv.conf`.**
  The device's resolver is normally the router (`192.168.x.1`), which is a *local*
  address: iOS refuses connections to those unless the app declares
  `NSLocalNetworkUsageDescription` and the user allows it. The app now declares it
  (so the prompt appears), puts the public resolvers first — they need no
  permission — and keeps the device's servers as the fallback for networks where
  public DNS is blocked. The provisioning failure message now points at
  Settings → Privacy & Security → Local Network.
- **Four bogus `WARNING filesystem 'x' is not registered` lines on every boot.**
  The check added with the boot fix used the `fs_ops` variable names; the names
  filesystems are registered under are `fake`, `real`, `proc`, `sysfs`, `devpts`.
- **The 456 MB darwin SDK download dropped its connection 22 seconds in** ("The
  network connection was lost"). Downloads now retry up to three times with
  backoff; a server-side error (404/403) still fails immediately.

### Added
- The boot sequence performs a real resolution lookup and logs the answer, so a
  guest that cannot resolve says so in the engine log instead of only inside
  `apk`'s output.

## [0.3.3] — 2026-09-20 — The guest gets DNS

### Added
- **The guest now gets the device's DNS servers.** Name resolution happens inside
  the guest, and the bundled Alpine minirootfs ships no `/etc/resolv.conf` at all,
  so nothing could resolve: `apk add` — the very first thing provisioning runs —
  answered "DNS: transient error" for every repository. The boot sequence now
  writes the file from the device's servers (iSH-AOK's own app does the same, for
  the same reason), with public resolvers as the fallback. Guests that never
  resolve are a guest that cannot install anything.
  Verified on the host harness: before, `wget` answered
  `bad address 'dl-cdn.alpinelinux.org'`; after, the same guest answers `net-ok`
  and `apk update` reports 27,453 packages available.

### Changed
- **Long installs keep the app awake** — the screen no longer locks mid-install
  (which suspends the app and leaves provisioning half-done), guarded by an idle
  timer and a background task assertion.
- The engine smoke test now probes the guest's network and `apk`, and configures
  the guest resolver the way the app does, so the *provisioning* path has a
  reproduction too.

## [0.3.2] — 2026-09-19 — The guest boots

### Fixed
- **Booting the embedded Linux no longer kills the app.** This is the crash behind
  "it keeps crashing when I try to install the SDKs / Linux": every one of those
  actions boots the guest, and boot aborted the process. `fs/mount.c` already ships
  a static table of the engine's filesystems and allows only three more (the
  headroom exists for the iSH-AOK app's own two); the bridge registered eight of
  them a second time, so the eighth registration hit `fs_register()`'s
  `assert(!"reached filesystem limit")` — `abort()`, with the message going to
  stderr, i.e. nowhere in an iOS app. The bridge no longer registers anything (the
  engine's table already has everything it mounts) and checks instead.
  Reproduced and verified off-device with `Tools/engine-smoke`, a macOS harness that
  drives the same bridge calls as the app.

### Added
- **Engine log capture.** The engine's `printk` writes to file descriptor 555, which
  nothing in XForge opened, so *every* kernel message was discarded — including the
  one `die()` prints immediately before it calls `abort()`. The bridge now points
  555 at `<Documents>/logs/engine.log` and adds its own breadcrumbs (import, mount,
  device setup, `/host` share, each command and its exit status, and the guest's
  output when a command fails). Settings → Diagnostics → **Engine log** shows,
  copies and shares it.
- **Engine smoke test** (`Tools/engine-smoke`, `.github/workflows/engine-smoke.yml`)
  — boots the bundled Alpine rootfs on a macOS host through the app's own bridge and
  runs commands in it, so bridge and boot regressions fail CI instead of a device.

### Changed
- Installing the Alpine rootfs now goes through `vm.boot()`, i.e. the emulator's own
  serial thread: the fakefs import used to run inline on the main actor, freezing
  the UI and running the engine's one-time global init on a different thread from
  the guest it belongs to.
- The Darwin SDK install unpacks off the main thread (456 MB expands to ~1.4 GB),
  checks free space before starting, deletes the archive afterwards, and streams
  `swift sdk install`'s output into the engine log.

## [0.3.1] — 2026-09-19 — App information

### Added
- **App icon** — a generated asset catalog (`Support/Assets.xcassets`) with a full
  AppIcon set (iPhone, iPad and the 1024px marketing icon) plus an accent colour.
  Regenerate with `make icon` (`Tools/gen-appicon.py`).
- **Signing configuration** — `DEVELOPMENT_TEAM` and automatic signing are wired up,
  and `CODE_SIGNING_ALLOWED=NO` moved out of the project so local/Xcode builds sign
  normally (CI still passes it explicitly for the unsigned IPA).
- **Display name** and the full `Info.plist` surface (`CFBundleDisplayName`,
  required device capability, orientation sets, Files-app visibility via
  `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`) — all declared in
  `project.yml` as the single source of truth.
- CI now verifies bundle ID, display name, version and that the app icon is wired up,
  so app-information regressions fail the build.

### Changed
- App identity is centralised in `XFORGE_*` settings in `project.yml`; the bundle ID,
  display name, team, version and build number each come from one place.
- `Support/Info.plist` is now generated by XcodeGen and gitignored. This also fixes
  the reported version: XcodeGen writes a hardcoded `1.0`/`1` when `info.properties`
  omits the version keys, so the app previously reported `1.0` regardless of
  `MARKETING_VERSION`.

### Removed
- The hand-maintained `Support/Info.plist` (superseded by `project.yml`).

## [0.3.0] — 2026-09-19 — Native Linux via iSH-AOK

### Added
- **iSH-AOK is now the embedded Linux engine.** XForge vendors iSH-AOK
  (`Vendor/ish-AOK`) and links its core static libraries (`libish`, `libish_emu`,
  `libfakefs`) built for iOS. iSH-AOK runs a real aarch64 Linux guest in-process and
  its "gadget JIT" needs no JIT entitlement, so it works in a sideloaded app.
- **The Alpine aarch64 rootfs is bundled in the app.** `EmbeddedLinux/fetch-rootfs.sh`
  downloads `alpine-minirootfs-3.23.3-aarch64.tar.xz` from iSH-AOK; it ships as an app
  resource and is imported into iSH-AOK's `fakefs` format on first boot — nothing is
  downloaded after install.
- `App/EmbeddedVM/ISHAOKBridge.{h,c}` — plain-C shim over the engine (boot + headless
  command execution), `ISHAOKEmulator.swift`, and `RootfsInstaller.swift`.
- `EmbeddedLinux/build-ish-aok-core.sh` — builds the iOS engine libraries.
- CI now checks out the engine submodule, fetches the rootfs, and verifies it is present
  in the built `.app`.

### Changed
- `LinuxEmulator` is now a command-execution engine (`runCommand`) instead of a byte
  pipe, matching iSH-AOK's `run_guest_command_capture_shell` primitive.
- `XForgeEnvironment.makeEmulator()` returns `ISHAOKEmulator`; `embeddedRoot` gained a
  `roots/` directory for installed `fakefs` filesystems.
- Project version 0.3.0; kernel memory entitlements added to match iSH-AOK's own build.

### Removed
- The experimental QEMU emulator scaffolding (`build-emulator.yml`,
  `validate-emulator.yml`) and the apk-based `build-rootfs.sh`, all superseded by
  iSH-AOK.

## [0.2.0] — 2026-09-01 — Feature Release

### Added
- **Build History** — every build attempt is persisted (project, configuration, build
  number, result, artifact). A new History screen lists past builds with export and
  delete, and a "Clear all" action.
- **Project template gallery** — create a project from several templates: SwiftUI App,
  UIKit App, Swift Package Library, and App Clip.
- **Import from Git** — import a SwiftPM package from a git URL; the clone is handed to
  the embedded Linux and completed on first build.
- **Real downloads + folder access** — Downloads hub with progress / reveal / stage-to-
  shell, and a sandbox file browser (Settings → Files).
- **On-device toolchain install** — Darwin SDK downloads and unzips on-device.

### Changed
- Build defaults (org ID, min iOS, configuration) are now applied app-wide from Settings.
- Projects carry their own App Info (bundle ID, display name, version), persisted and
  used by the build.

## [0.1.0] — 2026-09-01 — Initial
- 5-tab GUI (Projects / Build / Sign & Install / Toolchain / Settings).
- IPA build engine: BuildManager state machine + IPABuilder host packaging (unit-tested).
- Lean iPhoneOS-only darwin Swift SDK build pipeline (CI).
- Alpine aarch64 embedded-Linux rootfs assembly.
- In-process LinuxVM bridge architecture (iOS can't spawn subprocesses).
