# XForge as an Xcode alternative on iOS — what it takes

Goal: build an **existing Xcode project** on an iPhone, with no Mac and no CI.
This document is the honest map: what is already in the app, what each remaining
piece needs, and which parts cannot be done at all with the tools that exist.

---

## 1. Where the app is today

| Path | Status |
|---|---|
| Authoring a SwiftPM-shaped project (project editor, manifest, files) | works |
| Compiling and linking **C / Objective-C** sources in-process | works (`NativeBuildExecutor`) |
| Compiling **Swift** sources in-process | needs a `with_swift` bundle: the frontend ships in it and links into the app, but no Swift build has been run on a device |
| Resolving SwiftPM dependencies | manifests are never executed; one exact ZIPFoundation pin is handled from `Package.resolved` |
| Packaging an `.ipa` from a built `.app` | works (`IPABuilder`, host-side) |
| Signing with an existing `.p12` + profile | works (`AppBundleSigner`, XKit, in-process) |
| Signing with an Apple ID (certificate issuance) | **not implemented** — `XKitSigningService.signIn` throws |
| Installing to the device | **stub** — export to SideStore/AltStore is the working path |
| Reading a `.xcodeproj` | works (`XcodeProjectReader`) |
| Building an `.xcodeproj` | experimental: one simple Swift app target only; see constraints below |
| Asset catalogs | **not compiled** — `.xcassets` are copied into the bundle with a warning |

Three things that table already implies:

- **The compiler runs in-process, not in a guest.** The embedded Linux is gone; the
  Clang and LLD libraries are linked into the app. That removes the "emulated, so
  slow" caveat, and it removes the escape hatch: there is no longer a guest that can
  do the things the in-process path cannot (install packages, run shell, compile
  Swift through a Linux toolchain).
- **Swift can compile in the native driver** when the `with_swift` bundle is linked;
  the module-based dependency and Xcode-target paths are experimental and still need
  a physical-device smoke test.
- **The project model is read-only, but a narrow build adapter exists.** It consumes
  the selected `.xcodeproj` target without editing the project file. Unsupported
  inputs fail closed before compilation.

## 2. What an Xcode project needs, and where each piece stands

1. **Project model** — targets, product types, sources, build settings.
   **Readable on-device now** (`App/Models/XcodeProject.swift`), with XForge's own
   OpenStep parser (see the note in that file on why `tuist/XcodeProj` cannot be
   used from this dependency graph). An `.xcodeproj` is a text property list.
2. **Build-setting *evaluation*** — **still open.** The settings a build actually
   uses are computed, not stored: `$(VAR)` expansion, `[sdk=…]`/`[config=…]`
   conditions, and the large set of defaults Xcode supplies. The reader today
   merges the project's own inheritance layers in Xcode's order and reports values
   as written; full evaluation is its own piece of work and is a prerequisite for
   the compiler command lines.
3. **A bounded build adapter** — **experimental.** The current adapter translates one
   application target with literal bundle/deployment settings and Swift-only sources
   importing Foundation/UIKit/SwiftUI into the native plan. It rejects multiple app
   targets, resources, assets, scripts/copy phases, linked non-SDK products,
   xcconfigs, bridging headers, custom compiler/linker flags, and unresolved
   settings. It reuses the existing in-process compiler/linker and is not a general
   Xcode build driver. Script phases cannot run in the iOS app and remain unsupported.
4. **Compilers and linkers.**
   - C/Objective-C: clang in-process — **done**, not a POC any more.
   - Link: `ld64.lld` in-process — **done**.
   - **Swift: experimental, not yet physically device-validated.** The `with_swift`
     toolchain bundle carries the in-process frontend and CI verifies the app archive.
     The narrow Xcode/dependency paths rely on module emission and import behavior
     which still need a real device smoke test.
   - `dsymutil`/`strip` equivalents: LLVM ships `llvm-strip`, and debug maps can be
     skipped for a sideload build.
5. **Resources.** Copying files is trivial and the executor does it. **Compiling
   them is not:** `actool` (asset catalogs → `Assets.car`) and `ibtool`
   (storyboards/XIB → `.nib`) are Xcode's own macOS-only tools. They cannot run on
   iOS — wrong platform, and no process spawning — and no general open-source
   replacement exists to point at. Practical consequence: an app whose UI is pure
   SwiftUI code and whose icon and drawables are not in an asset catalog builds;
   one that needs `Assets.car` does not, on any on-device toolchain. XForge copies
   `.xcassets` into the bundle uncompiled and says so, so the failure is visible
   rather than an app that ships without its icon and cannot say why. A minimal
   `Assets.car` writer for the common cases (app icon + colours) is conceivable but
   is its own project.
6. **Dependencies** — an experimental module path exists for exactly one pinned
   ZIPFoundation revision in the SwiftPM flow. It does not provide general package
   resolution or Xcode-project package integration. Local/registry/private pins,
   transitive graphs, plugins, binaries and other package products remain unsupported.
7. **Signing and installation.** Signing **works** in-process via XKit with an
   identity the user already has (`.p12` + profile); what is missing is *obtaining*
   one — an Apple ID session needs anisette + GrandSlam + 2FA, which is a separate,
   device-only piece. Installing to the device needs a usbmux transport: the app
   sandbox cannot use the system `usbmuxd` socket, which is why SideStore embeds a
   userspace one plus a pairing file. Exporting to SideStore remains the pragmatic
   path.

## 3. Staged plan

- **M1 — Read the project.** `XcodeProjectReader` and target inventory (**done**).
- **M2 — Build one Xcode app on-device.** An experimental planner now accepts a
  strict single-target Swift subset and rejects unsupported build phases/settings.
  CI compiles/archives XForge, but a dependent target still needs a physical-device
  build/runtime smoke test.
- **M3 — Broaden settings/resources.** Full `$(…)` evaluation, `Info.plist`
  processing, asset/storyboard compilation and custom link/resource phases remain
  unsupported; shell scripts cannot execute in the app.
- **M4 — Swift module validation.** The Swift frontend is bundled, but module
  emission/import/link paths need physical-device verification.
- **M5 — Dependency graph.** One exact ZIPFoundation profile is experimental.
  General package resolution, transitive graphs, plugins and arbitrary products
  remain unsupported.

## 4. What this means for the goal

"An Xcode alternative on iOS" is achievable for a real class of projects — apps
whose sources are C/Objective-C, or SwiftUI apps once the frontend is ported, that
pull nothing from an asset catalog and run no script phase. The order matters:

- the **Swift frontend port** is the gate on everything Swift, and not having it is
  now a plain gap in the app rather than a reason to boot Linux instead;
- **asset catalogs and interface files** are walled off by tools that only exist on
  macOS, and no on-device toolchain can change that;
- **dependency fetching** is a network-protocol problem, not a compiler problem;
- **signing** is done, and **install** is the part the sandbox will not allow.

Until M4 lands, XForge is a working on-device C/Objective-C build tool, and a
Swift project cannot be built on device by anything at all.
