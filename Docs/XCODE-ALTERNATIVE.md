# XForge as an Xcode alternative on iOS — what it takes

Goal: build an **existing Xcode project** on an iPhone, with no Mac and no CI.
This document is the honest map: what is already in the app, what each remaining
piece needs, and which parts cannot be done at all with the tools that exist.

---

## 1. Where the app is today

| Path | Status |
|---|---|
| Authoring SwiftPM packages (project editor, manifest, files) | works |
| Building a **SwiftPM** package in the embedded Alpine guest via `xtool dev build` | works (slow: it is emulated) |
| Packaging an `.ipa` from a built `.app` | works (`IPABuilder`, host-side) |
| Signing (Apple ID / certificates / ad-hoc) | **stub** — `XKitSigningService` throws |
| Installing to the device | **stub** — export to SideStore/AltStore is the working path |
| Building a **`.xcodeproj`** | not started; reading one now works (`XcodeProjectReader`) |
| Native (no-VM) compilation | POC branch: Clang + Mach-O LLD in-process, C only |

Two things this table already implies: the guest can only build *SwiftPM* projects
(xtool is SwiftPM-only — its `XcodePacker` **generates** an Xcode project from a
SwiftPM package, the reverse of what we want), and nothing in the app has ever
looked at an `.xcodeproj`.

## 2. What an Xcode project needs, and where each piece stands

1. **Project model** — targets, product types, sources, build settings.
   **Readable on-device now** (`App/Models/XcodeProject.swift`). An `.xcodeproj` is a
   property list; `tuist/XcodeProj` parses it in pure Swift on iOS 17.
2. **Build-setting *evaluation*** — the settings a build actually uses are computed,
   not stored: `$(VAR)` expansion, `[sdk=…]`/`[config=…]` conditions, and the large
   set of defaults Xcode supplies (`xcodebuild -showBuildSettings` output is not in
   the pbxproj). The reader today reports values as written and merges the
   inheritance layers in Xcode's order; full evaluation is its own piece of work and
   is a prerequisite for the compiler command lines.
3. **A build driver** — dependency order between targets, Swift module boundaries
   (`-emit-module` ordering, `.swiftmodule` search paths), bridging headers,
   `SWIFT_OBJC_INTERFACE_HEADER_NAME`, entitlements, `Info.plist` variable
   substitution, resource phases, and **script phases** (arbitrary shell, which the
   guest can run — a useful hybrid).
   Nothing here can be borrowed from SwiftPM: `swift-build`/SwiftPM spawn compilers
   as processes, and iOS has no `fork`/`exec`.
4. **Compilers and linkers.**
   - C/Objective-C: `clang::CompilerInstance` driving `EmitObjAction` works in-process
     (POC branch), given `-resource-dir` pointing at a staged `clang/lib/Headers`.
   - Link: `ld64.lld` in-process (same branch).
   - **Swift: the gate.** `swift-frontend` is not in `llvm-project`; it must be built
     from `swiftlang/swift` against `swiftlang/llvm-project` **for iOS**, as a library
     set, and it needs the same resource directory the guest's toolchain has.
     Until that exists, on-device compilation is C/ObjC-only, and every Swift app
     (i.e. almost all of them) still needs the emulated guest.
   - `dsymutil`/`strip` equivalents: LLVM ships `llvm-strip`, and debug maps can be
     skipped for a sideload build.
5. **Resources.** Copying files is trivial. **Compiling them is not:**
   `actool` (asset catalogs → `Assets.car`) and `ibtool` (storyboards/XIB → `.nib`)
   are Xcode's own macOS-only tools. They cannot run on iOS (wrong platform, and no
   process spawning), and they cannot run in the Alpine guest either — which is why
   **xtool has no asset-catalog support at all** (grep its sources: no `actool`, no
   `xcassets`). There is no general open-source replacement to point at.
   Practical consequence: an app whose UI is pure SwiftUI code and whose icon/drawables
   are not in an asset catalog builds; one that needs `Assets.car` does not, on any
   on-device toolchain. Shipping without an icon is an acceptable dev-build trade-off,
   and a minimal `Assets.car` writer for the common cases (app icon + colours) is
   conceivable but is its own project.
6. **Dependencies.** An Xcode project's SPM dependencies (`XCRemoteSwiftPackageReference`)
   need a fetch (git over the network), a checkout, and then the same build treatment
   as the project's own targets. CocoaPods projects are worse: their xcconfigs and
   script phases assume a full Xcode/macOS toolchain.
7. **Signing and installation.** Signing is native-able today via XKit (in-process
   zsign + Developer Services); installing to the device needs a usbmux transport —
   the app sandbox cannot use the system `usbmuxd` socket, which is why SideStore
   embeds a userspace one (Minimuxer) plus a pairing file. Exporting to SideStore
   remains the pragmatic path.

## 3. Staged plan

- **M1 — Read the project.** `XcodeProjectReader` (done). Next: surface it in the
  import flow so an `.xcodeproj` can be opened and its targets listed, instead of
  being rejected as "not a SwiftPM package".
- **M2 — Build one app on-device.** A single app target, no asset catalog, SwiftUI in
  one module: compile with the native path, link with `ld64.lld`, package with
  `IPABuilder`, sign with XKit. This is the milestone that proves the whole concept
  end to end, and it does **not** need the Swift frontend port if the target is
  C/ObjC — but the interesting version of it does.
- **M3 — Build settings and the rest of the bundle.** Full `$(…)` evaluation,
  `Info.plist` processing, resource copy phases, script phases delegated to the guest.
- **M4 — Swift.** Port `swift-frontend` for iOS (the long pole), then the build driver
  for modules and dependencies.
- **M5 — SPM dependencies, then asset catalogs** (with the caveat in §2.5: this may
  never cover the general case).

## 4. What this means for the goal

"An Xcode alternative on iOS" is achievable for a real class of projects — SwiftUI
apps that do not pull assets or storyboards out of a catalog — but the order matters:
the Swift frontend port is the gate on everything Swift, and asset catalogs and
interface files are walled off by tools that only exist on macOS. Until M4 lands,
the embedded guest (or a build server) remains the only way to compile Swift, and
that is a property of the platform, not of this app.
