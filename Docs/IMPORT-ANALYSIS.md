# GitHub snapshot analysis and Xcode handoff

GitHub import currently retrieves a ZIP of one public Git revision, preserving the repository working tree (but not `.git` history). It is not a Git clone. The analyzer inventories Xcode projects, workspaces, package manifests, lockfiles, dependency markers, scripts, Git LFS pointers, case-only path collisions, and extraction size.

## Generated handoff

For a repository containing exactly one Swift application target with a literal bundle ID, a literal deployment target, and exactly one Swift `@main`/`@UIApplicationMain` entry point, **Generate Xcode handoff** writes a deterministic minimal `.xcodeproj`, shared scheme, `.xcconfig`, and `XFORGE-IMPORT-REPORT.md` under `.xforge-generated/`. The user can share the whole imported project ZIP and open it in Xcode on a Mac.

This is an exportable starting point, not a faithful conversion and not a build feature. It intentionally does not reproduce all original Xcode settings, resource/framework/embed phases, entitlements, localization, extensions, scripts, workspace resolution, or dependency graphs. The report lists detected blockers and limitations. Review the generated project before building it elsewhere.

## Dependency and platform boundaries

- SwiftPM manifests are Swift programs; XForge does not execute them. A `Package.resolved` file is reported, not resolved.
- CocoaPods, Carthage, and binary frameworks are inventoried. XForge does not run `pod install`, `carthage`, arbitrary build scripts, or package plugins.
- GitHub ZIP archives omit submodule contents. LFS pointers are detected; their objects are not fetched.
- GitHub ZIP snapshots do not contain history. Private repositories are not supported by this importer.
- XForge does not yet build general `.xcodeproj` projects. Existing in-process build support remains a narrow, dependency-free SwiftPM subset. A generated Xcode project must be built with Xcode elsewhere.
- `actool`/`ibtool` are unavailable in the iOS app process, and script build phases cannot be executed there.

The goal of this analysis is to make imports and handoffs more truthful and reproducible, not to claim support for every app repository.

## Pinned dependency source cache

The Dependency Manager uses `Package.resolved` only. It can fetch immutable public GitHub source snapshots for parsed pins into `.xforge-dependencies/` without executing the package manifest. This is source acquisition for inspection/reproducibility only: it does not claim package build support. XForge still refuses dependency builds because it cannot yet emit modules or link products.
