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
| Resolving SwiftPM dependencies | **refused by name** — no package manager can run here |
| Packaging an `.ipa` from a built `.app` | works (`IPABuilder`, host-side) |
| Signing with an existing `.p12` + profile | works (`AppBundleSigner`, XKit, in-process) |
| Signing with an Apple ID (certificate issuance) | **not implemented** — `XKitSigningService.signIn` throws |
| Installing to the device | **stub** — export to SideStore/AltStore is the working path |
| Reading a `.xcodeproj` | works (`XcodeProjectReader`); nothing builds from it |
| Building a `.xcodeproj` | not started |
| Asset catalogs | **not compiled** — `.xcassets` are copied into the bundle with a warning |

Three things that table already implies:

- **The compiler runs in-process, not in a guest.** The embedded Linux is gone; the
  Clang and LLD libraries are linked into the app. That removes the "emulated, so
  slow" caveat, and it removes the escape hatch: there is no longer a guest that can
  do the things the in-process path cannot (install packages, run shell, compile
  Swift through a Linux toolchain).
- **Swift is the gate.** Everything interesting — which is to say almost every iOS
  app — is Swift, and Swift does not compile on device yet.
- **The project model is read-only.** The reader parses an `.xcodeproj`; the import
  flow still requires a `Package.swift` and rejects anything else, so there is no
  path from a read `.xcodeproj` to a build.

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
3. **A build driver** — **still open, and now harder than it looked.** Dependency
   order between targets, Swift module boundaries (`-emit-module` ordering,
   `.swiftmodule` search paths), bridging headers,
   `SWIFT_OBJC_INTERFACE_HEADER_NAME`, entitlements, `Info.plist` variable
   substitution, resource phases. **Script phases are the part the platform takes
   away**: they are arbitrary shell, and an iOS app cannot run shell, so a project
   with a script phase cannot be built on device at all — not by XForge, and not by
   any other on-device tool. Nothing here can be borrowed from SwiftPM either:
   `swift-build` spawns compilers as processes, and iOS has no `fork`/`exec`. The
   plan/executor split in `Docs/DESIGN.md` is the shape a driver would take, but
   the driver itself (one target, one module) is what remains.
4. **Compilers and linkers.**
   - C/Objective-C: clang in-process — **done**, not a POC any more.
   - Link: `ld64.lld` in-process — **done**.
   - **Swift: still the gate.** `swift-frontend` is not in `llvm-project`; it must
     be built from `swiftlang/swift` against `swiftlang/llvm-project` **for iOS**,
     as a library set, and it needs the same resource directory the SDK bundle
     carries. The bridge already exposes the entry point behind
     `XFORGE_HAS_SWIFT_FRONTEND`, and the CI workflow that produces the toolchain
     artifact does not build it. Until it does, every Swift app is out of reach on
     device — there is no guest to fall back to.
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
6. **Dependencies** — **still open, and unfetchable as things stand.** An Xcode
   project's SPM dependencies (`XCRemoteSwiftPackageReference`) need a fetch (git
   over the network), a checkout, and then the same build treatment as the
   project's own targets. An iOS app cannot run `git`, so the fetch is not a matter
   of writing a driver: it means reimplementing enough of git's wire protocol to
   resolve and check out a package graph. For the same reason, XForge today refuses
   a `Package.swift` that declares any dependency, by name.
7. **Signing and installation.** Signing **works** in-process via XKit with an
   identity the user already has (`.p12` + profile); what is missing is *obtaining*
   one — an Apple ID session needs anisette + GrandSlam + 2FA, which is a separate,
   device-only piece. Installing to the device needs a usbmux transport: the app
   sandbox cannot use the system `usbmuxd` socket, which is why SideStore embeds a
   userspace one plus a pairing file. Exporting to SideStore remains the pragmatic
   path.

## 3. Staged plan

- **M1 — Read the project.** `XcodeProjectReader` (**done**). Next: surface it in
  the import flow so an `.xcodeproj` can be opened and its targets listed, instead
  of being rejected as "not a SwiftPM package".
- **M2 — Build one app on-device.** A single app target, no asset catalog, one
  module: compile with the native path, link with `ld64.lld`, package with
  `IPABuilder`, sign with XKit. The toolchain now does the C/ObjC half of this;
  the interesting version needs Swift and therefore M4. This is the milestone that
  proves the concept end to end.
- **M3 — Build settings and the rest of the bundle.** Full `$(…)` evaluation,
  `Info.plist` processing, resource copy phases, and a decision about script phases
  (which cannot be supported at all).
- **M4 — Swift.** Port `swift-frontend` for iOS (the long pole), then the build
  driver for modules and dependencies. **Everything Swift waits on this.**
- **M5 — SPM dependencies, then asset catalogs** — with the caveats in §2.5 and
  §2.6: the first needs a git implementation, and the second may never cover the
  general case.

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
