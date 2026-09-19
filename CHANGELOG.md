# Changelog

All notable changes to **XForge** are documented here.

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
