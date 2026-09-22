# Changelog

All notable changes to **XForge** are documented here.

## The engine is a prerequisite of the app, so the app builds it

### Changed
- **The XForge target now builds the embedded Linux engine itself.** A first build
  phase (`EmbeddedLinux/build-engine-for-xcode.sh`) fetches the engine's submodules
  if the checkout is empty, installs meson/ninja/llvm/lld/libarchive with Homebrew
  when they are missing, and runs `EmbeddedLinux/build-ish-core.sh` — which is a
  no-op unless the engine revision, that script or `project.yml` changed. Until
  now only the IPA workflow ran the engine build, so any other way of building the
  project failed part-way through compiling the bridge with
  `ISHBridge.c:123:10: error: 'kernel/init.h' file not found`, which reads like a
  missing header rather than a missing engine. Simulator builds skip the phase
  (they compile the stub branch of the bridge), as do `XFORGE_SKIP_ENGINE=1` and
  `XFORGE_REBUILD_ENGINE=1` forces a rebuild.
- **The app no longer links libarchive or the fakefs import tool.** The bundled
  root is already a fakefs ZIP, unpacked with ZIPFoundation, so `fakefs_import` was
  never called — the app's own headers said so. `-larchive`, `-lfakefsify`, the
  libarchive header path, the `deps/libarchive` submodule fetch and the libarchive
  iOS build are gone. That was worth more than the bytes: libarchive has no iOS build
  system here, so it was built by a *nested* `xcodebuild`, which inside an Xcode build
  phase crashed the build system (`unexpected service error: The Xcode build system
  has crashed`) after all 90 engine targets had built.
- **The engine build records what it built** (`.engine-stamp`: the submodule commit,
  a hash of `build-ish-core.sh` and of `project.yml`, the guest arch and the
  minimum iOS version) so the phase costs a couple of file reads on every
  subsequent build instead of minutes.
- **`Docs/ISH-ARM64-INTEGRATION.md`** (new): the reference integration
  (`OpenMinis/OpenMinis`'s `deps/ISH_INTEGRATION.md` and its two build scripts) item
  by item against what XForge does, including the two requirements XForge
  deliberately does not follow — `-ObjC -all_load`, which exists to preserve
  Objective-C categories and reachability in a C static library, and
  `-DISH_INTERNAL`, which the reference needs only because its kernel file includes
  `fs/fake.h` — and how the console differs from the reference's (the reference makes
  pid 1 *be* the shell; XForge boots an init that starts a login session, which is
  why pid 1's stdio had to stop claiming the console).

## The console starts root's login shell, in a root that has it

### Changed
- **The guest's console starts root's *login shell*, not a login program.**
  `/etc/inittab` now respawns `/sbin/xforge-login root` on tty1 instead of
  `/bin/login -f root`. The new script (`EmbeddedLinux/xforge-login`, installed
  into the root) reads root's shell out of `/etc/passwd` and execs it as a login
  shell — with the leading dash in `argv[0]` that makes a shell read
  `/etc/profile`, the user's home as the working directory, and the environment
  `login` would have set. So the shell the Terminal tab opens in is the shell the
  root is configured with, and `apk add zsh` plus that one field changes it.
- **`login` is out of the console path on purpose.** It authenticates, allocates a
  utmp slot and takes over a controlling terminal. This guest has one user, whose
  password is locked, and its tty is already init's — so all three are work it does
  not need, and each is a way for a working root to produce no console at all (a
  non-tty stdin makes `login` exit 1 with nothing on the screen). What it never did
  is start the shell the root asked for. If the shell that field names has been
  uninstalled, the script says so and falls back to `/bin/sh` rather than
  respawning into a blank screen forever.
- **The root now carries the console session's dependencies,** installed with the
  guest's own `apk` at build time (`XFORGE_CONSOLE_PACKAGES`, default
  `bash coreutils less ncurses-terminfo`). The console is the first thing a new
  install shows; a shell whose pager is missing, or whose `TERM` is unknown to
  curses, is a guest that looks broken.
  - `ncurses-terminfo`, specifically, is the difference between a working `less`
    and one that warns that the terminal is not fully functional: `/etc/profile`
    exports `TERM=xterm-256color` and the *base* terminfo package does not carry
    the xterm entries.
  - Root's shell is written into `/etc/passwd` from `XFORGE_DEFAULT_SHELL`
    (`/bin/bash`), and the build fails loudly into `/bin/sh` with a warning if that
    shell is not among the packages.
- **The rootfs is checked by running it.** `EmbeddedLinux/verify-rootfs.sh`
  unpacks the root, checks the files init needs, then runs `/sbin/xforge-login`
  inside a chroot — the guest's own binaries, started the way init starts them —
  and asserts that the shell named in `/etc/passwd` comes up as a login shell,
  with `SHELL` set to it and `TERM` one curses knows. `build-rootfs.sh` runs it on
  the tree before the fakefs conversion; `build-rootfs.yml` runs it on the
  published ZIP; `build-ipa.yml` refuses a pinned root whose manifest shell is not
  in the archive.
- **The rootfs stamp is `rootfs-v4`** (`ROOTFS_TAG` in `build-ipa.yml`), so a
  device that has booted an older root replaces it — the console is the one part
  of the guest an app update cannot reach on its own.

## The Terminal is the guest's console: /sbin/init + login -f root

### Changed
- **The Terminal tab is now the guest's real console.** XForge boots `/sbin/init`
  as pid 1, and the root's `/etc/inittab` respawns `/bin/login -f root` on tty1 —
  which is the same terminal as `/dev/console`, the one the app displays. Log in,
  run commands, log out, and init gives you a fresh login instead of a dead
  screen.
- **The host implements that console as a tty, not a pipe.** The previous transport
  was `tail -f | /bin/sh` over files in the shared folder, which is why it had no
  line editing, no echo from the guest, and an interrupt that had to be sent as a
  signal because `0x03` on a pipe is just a byte. Now the guest's *own* line
  discipline does the work: echo, backspace, `Ctrl-C` and `Ctrl-Z` (signal
  generation for the foreground process group), `Ctrl-D`, and raw mode for
  full-screen programs. The host writes keystrokes into the tty and reads what the
  tty produces.
- **The terminal tells the guest how big the screen is.** Without a window size the
  guest believes it is 0×0, which makes `ls` print one name per line and any
  full-screen program draw into a corner.
- **The key bar's character keys actually type.** `-`, `.`, `/`, `:`, `!`, `|`,
  `Tab` and `Esc` were being appended to a local line buffer that nothing read;
  they are now raw bytes for the console, as are the arrow keys (the shell's own
  line editor handles history).
- **The rootfs is replaced when it is a different revision.** The app compares the
  `stamp:` in the root it has installed with the one in the root it bundles, so an
  update that changes the guest's own configuration — this one changes its
  `/etc/inittab` — actually reaches a device that has booted before.

### Fixed
- **The bundled root's `/etc/inittab` is XForge's, not a full Alpine install's.** The
  minirootfs ships an inittab that starts `openrc` (which this root does not
  contain) and respawns six gettys on terminals that do not exist behind the
  engine's single console. It is replaced with a busybox `rcS` step and one console
  login; `login -f root` skips authentication, which the root needs because the
  minirootfs ships root with a *locked* password.

## ish-arm64 engine, a plain Alpine root, and glibc preinstalled

### Changed
- **The embedded Linux engine is now [ish-arm64](https://github.com/OpenMinis/ish-arm64)**
  (`Vendor/ish-arm64`), replacing iSH-AOK. It is a fork of ish-app/ish that adds a
  native AArch64 guest backend to the threaded-code interpreter, so the bundled
  Alpine *aarch64* root runs as a same-architecture guest instead of being
  cross-translated from x86. Like iSH-AOK it emits no machine code and needs no
  executable memory, so no JIT entitlement is required and it works sideloaded.
- **The bundled root is a plain Alpine userspace, and it is already a fakefs.**
  `EmbeddedLinux/build-rootfs.sh` downloads the official Alpine aarch64 minirootfs,
  converts it with the engine's own `tools/fakefsify`, configures it, and packs
  `alpine-rootfs.zip`. First launch is an unzip, not a multi-minute import of
  thousands of files into SQLite on a phone. Swift and xtool are *not* bundled —
  the guest installs them on demand with `install-toolchain.sh`.
- **The bundled root is stored as a pinned release asset** (`rootfs-v2`) rather
  than rebuilt for every IPA. `.github/workflows/build-rootfs.yml` builds and
  publishes it; `.github/workflows/build-ipa.yml` downloads it and verifies its
  sha256. Building it per IPA run is what used to make the artifact ~1.4 GB; the
  app is 161 MB now.
- **The glibc compatibility layer is preinstalled in the root.** Every tool XForge
  builds with is a glibc binary (xtool is a Swift program built on Ubuntu, and so
  is the toolchain) while Alpine is musl, and `gcompat` is not enough for them.
  Baking the layer in removes the most failure-prone step of an on-device
  provision: a package renamed between Ubuntu releases yields a layer that loads
  but cannot resolve a symbol, which surfaces much later inside a tool. Build the
  root with `XFORGE_SKIP_GLIBC=1` to leave it out and have the guest install it.
- **The rootfs builder runs the guest's own installer in a chroot**, so there is a
  single implementation of provisioning rather than two that can drift. It needs
  root, and says so up front if it does not have it.

### Fixed
- **The engine build no longer leaves kernel assertions live.** meson's `release`
  buildtype implies `-O3` but does not define `NDEBUG`; that is the separate
  `b_ndebug` option. Without it every `assert()` survived into a shipping build
  and called `abort()` on a real device.
- **The guest VDSO is verified rather than assumed.** It is `.incbin`ed into
  `libish.a`, and meson silently substitutes an *empty* file when it cannot find
  an aarch64-linux cross-compiler — so a build could succeed and produce a guest
  with a bogus VDSO. The build now fails loudly in that case.
- **The IPA ships exactly one rootfs.** It briefly carried both the new fakefs ZIP
  and the tarball the app used to import at runtime — 4 MB of dead weight nothing
  opened — because the old file stayed committed and a `.gitignore` rule kept it
  tracked on purpose.
- **Superseding dispatches no longer cancel a packaged IPA mid-publish.** The
  cancellation moved to the provisioning job, and the build job is serialized but
  never cancelled.
- **The payload builder no longer dies measuring the rootfs.** `du -skx` inside a
  command substitution exits non-zero when a `/proc` entry vanishes mid-walk, and
  under `set -e` that aborted a build whose toolchain had already been installed
  and verified.
- **`meta.db` queries compare paths as text.** fakefs stores paths as BLOB, and a
  `LIKE` against a BLOB only works through SQLite's version-dependent implicit
  coercion — the same check passed locally and failed on CI's older SQLite.

### Changed (app)
- **The Sign & Install tab is now the Terminal.** Tab 3 is a full-screen terminal
  into the embedded Alpine system, laid out like the engine's: the screen *is* the
  terminal, with a key bar of the characters a phone keyboard cannot type (Tab,
  Ctrl, Esc, arrows, `- . / : ! |`, paste, hide keyboard) between it and the
  keyboard. Output goes through a small screen model, so SGR colour, the
  carriage-return progress bars `curl` and `apk` draw, and `clear` behave like a
  terminal rather than a log.
- **Sign & Install moved into the Build tab**, next to the artifact it acts on: a
  Sign & Install card under the pipeline, and the same two destinations in the
  Build toolbar.
- **System components are managed by commands, run in that terminal.** The
  Toolchain screen (and Settings → Linux Toolchain) no longer installs anything
  behind its own progress bar; it puts your files where the guest can read them
  and hands over the command, so you can watch it and answer it:
  - **Darwin SDK from your own `Xcode.xip`** — the file is copied into the guest's
    own storage (`/root/xforge/xip/…`) and installed there with
    `xtool sdk install "path/to/xip"`;
  - **the Swift toolchain** — the command swift.org documents, run in the guest
    (`curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz`,
    `tar zxf`, `./swiftly init --quiet-shell-followup`, `env.sh`, `hash -r`);
  - **xtool** with its provisioning step, and the **prebuilt darwin bundle** by
    downloading and installing it inside the guest.
- The Terminal's Components menu — in the toolbar and on the wrench key of its
  key bar — runs those same commands, so nothing depends on remembering a path.
- A command handed over by another screen is queued, echoed in the terminal with
  the screen that asked for it, and runs as soon as the current one finishes.
- The Build screen reports what the guest can actually do, so a fresh install
  reads as "the toolchain is not installed yet" (with the command to fix it)
  rather than as a broken release.

## [0.5.0] — 2026-09-20 — Toolchain preinstalled

> Superseded: this shipped a ~1.4 GB root with Swift, xtool and the glibc layer
> baked in, and imported it on device. The root is now a small plain Alpine fakefs
> and the guest provisions itself. Kept here for history.

### Changed
- **The app shipped a *provisioned* Alpine rootfs, so there was nothing to
  install on the device.** The IPA bundled
  `alpine-minirootfs-3.24.2-aarch64-provisioned.tar.gz`: the Alpine aarch64
  release with the Alpine build dependencies (clang, lld, cmake, ninja, git, …),
  the glibc compatibility layer under `/opt/glibc`, swiftly and the Swift
  toolchain. xtool and the Darwin SDK remained explicit on-device installs.
- **The `darwin` Swift SDK was not bundled.** It is a ~200 MB release asset that
  the app fetches on first use, so it stayed out of the IPA.
- **Provisioning happens at build time**, in
  `EmbeddedLinux/build-rootfs-payload.sh`, on an arm64 Linux host: it chroots
  into the unpacked minirootfs and runs the app's *own*
  `EmbeddedLinux/install-toolchain.sh all` there, so there is no second
  implementation to drift from what a device installs. Every tool is then
  executed inside the finished rootfs and the result is written to
  `/usr/local/share/xforge/payload-manifest.txt` **inside** the archive, which is
  what the IPA build verifies before shipping it.
- `.github/workflows/unsigned-ipa.yml` builds that payload first and then bundles
  it into the released IPA. `EmbeddedLinux/fetch-rootfs.sh` supports
  `XFORGE_ROOTFS=auto|payload|plain` for release and local builds.
- **Bundle identifier is now `com.r0gueee.xforge`** (was `org.xforge.XForge`), and
  the app version is 0.5.0 (8).

### Fixed
- **No guest command's output is sent to `/dev/null` any more.** the engine's arm64
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
  writes the file from the device's servers (ish-arm64's own app does the same, for
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
  headroom exists for the ish-arm64 app's own two); the bridge registered eight of
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
- **Engine smoke test** (`Tools/engine-smoke`)
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

## [0.3.0] — 2026-09-19 — Native Linux via ish-arm64

### Added
- **ish-arm64 is now the embedded Linux engine.** XForge vendors ish-arm64
  (`Vendor/ish-arm64`) and links its core static libraries (`libish`, `libish_emu`,
  `libfakefs`) built for iOS. ish-arm64 runs a real aarch64 Linux guest in-process and
  its "gadget JIT" needs no JIT entitlement, so it works in a sideloaded app.
- **The Alpine aarch64 rootfs is bundled in the app.** `EmbeddedLinux/fetch-rootfs.sh`
  downloads `alpine-minirootfs-3.23.3-aarch64.tar.xz` from ish-arm64; it ships as an app
  resource and is imported into the engine's `fakefs` format on first boot — nothing is
  downloaded after install.
- `App/EmbeddedVM/ISHBridge.{h,c}` — plain-C shim over the engine (boot + headless
  command execution), `ISHEmulator.swift`, and `RootfsInstaller.swift`.
- `EmbeddedLinux/build-ish-aok-core.sh` — builds the iOS engine libraries.
- CI now checks out the engine submodule, fetches the rootfs, and verifies it is present
  in the built `.app`.

### Changed
- `LinuxEmulator` is now a command-execution engine (`runCommand`) instead of a byte
  pipe, matching the engine's guest command runner primitive.
- `XForgeEnvironment.makeEmulator()` returns `ISHEmulator`; `embeddedRoot` gained a
  `roots/` directory for installed `fakefs` filesystems.
- Project version 0.3.0; kernel memory entitlements added to match the engine's own build.

### Removed
- The experimental QEMU emulator scaffolding (`build-emulator.yml`,
  `validate-emulator.yml`) and the apk-based `build-rootfs.sh`, all superseded by
  ish-arm64.

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
