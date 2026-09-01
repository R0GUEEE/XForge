# Changelog

All notable changes to **XForge** are documented here.

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
