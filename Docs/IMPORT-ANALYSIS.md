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

The dependency manager fetches source snapshots for eligible pins, and the native builder currently supports exactly one audited compile profile: the public ZIPFoundation `0.9.19` pin at commit `02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0`, one Swift target/module, and its `PrivacyInfo.xcprivacy` resource. XForge emits the dependency module first, compiles its source files in module context, gives the app the module search path, links its object files, and includes the package resource bundle. The build checks the lockfile, installer marker, source layout/count/size, and archive root revision before accepting the profile.

Everything else remains fetch/inspect-only or unsupported: version solving, transitive manifest execution, package plugins, local/registry/private/non-GitHub pins, multiple dependencies/products, target graphs, binary targets, arbitrary resources, CocoaPods/Carthage, and build scripts. No project manifest is executed, and no subprocess is launched. See the build compatibility report before relying on an IPA.
