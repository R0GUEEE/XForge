# XForge

**Build iOS apps on your iPhone, with no Mac in the loop.**

XForge is an on-device alternative to Xcode's build step. It is built on
[xtool](https://github.com/xtool-org/xtool)'s libraries — `XKit` for in-process
codesigning, and xtool's `darwin.artifactbundle` for the iPhoneOS SDK — and it
runs no helper process: the compiler and the Mach-O linker are linked into the app
binary and called in-process through a small C++ bridge.

> **Status: active, and narrower than it looks.** A project authored in the SwiftUI
> shell is read into a build plan, compiled and linked in-process, packaged into an
> unsigned `.ipa`, and — with a certificate the user already has — signed with XKit.
> **C, Objective-C and Objective-C++ targets build today. Swift sources do not**,
> because the Swift frontend libraries are not part of the toolchain artifact yet;
> such a project stops at the compile stage with a message naming how many files it
> could not compile. See *What works today* and *What does not*.

## How it is put together

```
project (a directory)  →  build plan  →  compile + link in-process  →  <Name>.app
   →  unsigned .ipa  →  XKit signing  →  signed .ipa
```

1. **Project.** A project is an ordinary directory in the app's container,
   `<Documents>/projects/<name>`, holding a `Package.swift`, `Sources/<Target>/`,
   an optional `Support/Info.plist` and the `xtool.yml` metadata XForge and xtool
   both read. `ProjectFiles` reads and writes it directly, keeping the
   relative-path discipline the editor needs (a `..` is rejected rather than
   normalised, because the paths come from editable text in the UI). A folder
   picked in the Files app is copied in: an iOS process cannot run `git`, so a
   clone is not something XForge can do.
2. **Build plan.** `NativeBuildPlanFactory` turns that directory into a fully
   resolved `NativeBuildPlan` — module, sources, resources, frameworks, search
   paths. It is deliberately conservative: it refuses, *by name*, the one thing an
   in-process driver cannot resolve (SwiftPM dependencies, which need a package
   manager that fetches and runs manifests) instead of failing halfway through a
   build.
3. **Compile and link.** `NativeBuildExecutor` turns the plan into argument lists
   (`NativeToolchainInvocation`, pure functions, so they can be unit-tested on a
   simulator where no compiler exists) and calls the entry points behind the
   bridge: clang through `CompilerInvocation` + `EmitObjAction`, `swift-frontend`
   through `swift::performFrontend`, `ld64.lld` through `lld::lldMain`. The
   blocking calls are pushed off the main actor so the Build screen keeps drawing.
   The result is assembled into `<Name>.app` with an `Info.plist` and the
   project's resources.
4. **Package.** `IPABuilder` puts the bundle under `Payload/` and zips it into an
   unsigned `.ipa`, staged as `<Documents>/staging/<name>-<version>.ipa`.
5. **Sign.** `IPASigningJob` + `AppBundleSigner` do the signing in this process
   with XKit: the `.p12` is read through the Security framework, used in memory,
   and never written anywhere. The result lands as `<Documents>/Signed-<name>.ipa`.

Every screen reports from the same values, so the app cannot claim a capability it
does not have: the Build screen's stages, the Toolchain screen (capabilities, SDK,
smoke test) and the Settings screen (log, project files, diagnostics) all read the
in-process toolchain and the SDK in the container.

## What works today

- **Building a project on device.** C, Objective-C and Objective-C++ sources are
  compiled by clang and linked by `ld64.lld` against the Darwin SDK, in-process,
  into a `.app` and then an unsigned `.ipa`.
- **A project's own `Info.plist`.** A hand-written `Support/Info.plist` is merged
  over the generated keys, so scene manifests and orientations survive a build.
- **Signing an app with an identity you already have** — a `.p12` and a
  provisioning profile, with entitlements if you have them.
- **Exporting.** `ProjectExporter` zips a project into `<Documents>/exports`, and
  the file is visible in the Files app and shareable from there. Build output
  (`.xforge-build`, `.build`) is left out of the archive.
- **Reading an `.xcodeproj`.** `App/Models/XcodeProject.swift` parses the project
  model on device, with its own OpenStep parser. Nothing builds from it yet.
- **Building and testing XForge itself without any toolchain bundle.** A plain
  clone compiles the bridge to a "not available" stub; `make test` runs on the
  simulator.

## What does not work (yet)

- **Swift.** The Swift frontend libraries are not in the toolchain artifact: the
  CI workflow that builds it builds Clang and LLD only. A plan with Swift sources
  fails at the compile stage with `swiftFrontendMissing`, naming the number of
  files, rather than pretending otherwise. This is the single largest gap; it is
  the difference between "an Xcode alternative for C projects" and the thing the
  app is for.
- **SwiftPM dependencies.** Refused by name at plan time. Fetching and resolving
  packages means running a package manager, which cannot happen here — and a
  dependency editor that could only produce unbuildable projects was removed
  rather than kept as a trap.
- **Asset catalogs.** `.xcassets` are copied into the bundle uncompiled, with a
  warning: `actool` is a macOS-only tool and there is no open-source replacement
  to point at, so an app whose icon lives in a catalog ships without it.
- **Apple ID provisioning.** Obtaining a certificate without one already in hand
  means anisette + GrandSlam + 2FA, which is a separate, device-only piece of
  work. The signer takes an existing identity; `XKitSigningService` throws rather
  than reporting a session it does not have.
- **Installing to the device.** Exporting to SideStore/AltStore remains the
  working path; in-app install needs a usbmux transport the sandbox cannot reach.
- **A remote build server.** `RemoteExecutor` is still a plan, not code.

## Build the app

Requires macOS + Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen

make gen && open XForge.xcodeproj
```

That is the whole of it for a plain clone: there is no submodule to initialise and
no second build system to drive. The app builds with the compiler bridge compiled
to a stub and says so on the Toolchain screen.

To build with the compiler *linked in*, install the toolchain bundle first:

```bash
make toolchain-release          # the newest published bundle
make gen
```

`install-bundle.sh --release` fetches the bundle from its release (a specific tag,
or a local tarball, also work — see `make toolchain`), unpacks it into
`Vendor/NativeToolchain` and runs `prepare-xcode.sh`, which writes
`Support/NativeToolchain.generated.xcconfig` — the file the app target consumes.
That xcconfig is checked in *with the backend disabled*, so a clone without the
bundle is buildable; see
[Docs/NATIVE-TOOLCHAIN.md](Docs/NATIVE-TOOLCHAIN.md).

The only build prerequisite beyond XcodeGen is the toolchain bundle, and only if
you want a working compiler.

Or build the unsigned IPA for sideloading via GitHub Actions
(`.github/workflows/build-ipa.yml`) and install it with SideStore/AltStore.

## On-device build pipeline

1. **Check build toolchain** — `NativeToolchainCapabilities` reports clang,
   `ld64.lld`, `swift-frontend` and the SDK; the stage fails with an explanation
   when nothing is linked, rather than letting a build die in the middle.
2. **Install Darwin SDK** — the SDK is a folder in the app container. The stage
   skips itself when it is already there, otherwise it downloads the newest
   `darwin-sdk-*` release asset.
3. **Configure app** — records the app identity (bundle ID, version, build number,
   configuration) into `<project>/.xforge-build/build.json` so a failed build is
   reproducible, and checks that the project directory exists.
4. **Resolve dependencies** — reports "nothing to resolve" for a project with no
   dependencies, and refuses a project that declares any.
5. **Compile (arm64-apple-ios)** — the work described above; also assembles the
   `.app` and packages the unsigned `.ipa`.
6. **Package & sign .ipa** — accepts the packaged artifact. (The signing itself is
   on the Signing screen, not in this stage.)
7. **Stage artifact** — confirms the `.ipa` exists and is non-empty, and reports
   its size.

## Repo layout

```
App/                    SwiftUI app — project editing, build pipeline, signing
App/Build/              BuildExecutor protocol, the NativeBuild* pipeline, IPABuilder
App/Models/             pipeline, history, project store, XcodeProject (reads .xcodeproj)
App/NativeToolchain/    in-process Clang/LLD bridge + the Darwin SDK store
App/Services/           signing, project files, export, device seams, the log
App/Views/              screens: Projects, Build, Signing, Settings (Toolchain, …)
AppTests/               unit tests (plan and argument construction, which run without a compiler)
Vendor/NativeToolchain/ where an installed toolchain bundle goes (absent by default)
NativeToolchain/        install-bundle.sh, prepare-xcode.sh
Support/                entitlements, assets, the generated toolchain xcconfig
Tools/                  gen-appicon.py (writes the app icon into the asset catalog)
project.yml             XcodeGen definition
Makefile                gen, build, test, ipa, toolchain
.github/workflows/      build-ipa.yml (the unsigned IPA),
                        native-toolchain.yml (the iOS LLVM cross-build),
                        ios-share.yml (a simulator build for MobAI)
Docs/DESIGN.md                  full architecture write-up
Docs/IPA-BUILD.md               the build pipeline and its stages
Docs/NATIVE-TOOLCHAIN.md        the toolchain bundle, how it is built and linked
Docs/XCODE-ALTERNATIVE.md       what building existing Xcode projects on-device takes
CHANGELOG.md            what changed, release by release
```

## App information

Everything about the app's identity lives in the project-level `settings` block of
`project.yml`:

| Field | Value |
|---|---|
| Bundle identifier | `com.r0gueee.xforge` |
| Display name | `XForge` |
| Apple team | set in `XFORGE_DEVELOPMENT_TEAM` |
| Marketing version | `XFORGE_MARKETING_VERSION` |
| Build number | `XFORGE_BUILD_NUMBER` |
| App icon | `Support/Assets.xcassets/AppIcon.appiconset` |
| Accent colour | `Support/Assets.xcassets/AccentColor.colorset` |

The `XFORGE_*` settings feed `Info.plist` (`CFBundleDisplayName`, the version keys)
and the signing configuration (`DEVELOPMENT_TEAM`), so changing the app's identity
is a one-line edit. CI asserts bundle ID, display name, version and a wired-up icon
on every build, so a regression fails the build rather than shipping.

`Support/Info.plist` is **generated** by XcodeGen from the target's
`info.properties` and is gitignored — edit `project.yml`, not the plist. (XcodeGen
would otherwise write its own hardcoded `1.0`/`1` version, which is why the version
is set explicitly in `info.properties`.)

Signing: `CODE_SIGN_STYLE` is `Automatic` with the team above, so opening the
project in Xcode and building to a device signs normally. The CI workflow passes
`CODE_SIGNING_ALLOWED=NO` to produce an unsigned IPA for sideloading.

The app icon is generated from `Tools/gen-appicon.py` (a terminal-prompt motif in
the forge palette) and written into the asset catalog:

```bash
make icon        # rewrites Support/Assets.xcassets
```

## Continuous integration

- **`build-ipa.yml`** — runs the unit tests, archives the app unsigned
  (`CODE_SIGNING_ALLOWED=NO`), verifies the built app and the final IPA, and
  publishes the unsigned IPA for sideloading. It runs `prepare-xcode.sh` too, so CI
  never depends on a toolchain bundle being installed in the checkout.
- **`native-toolchain.yml`** — cross-builds LLVM's Clang and Mach-O LLD for
  iPhoneOS (and, with `with_swift=true`, Swift's frontend libraries) on a macOS
  runner, merges the static archives into one, compile-checks and link-checks
  `NativeToolchainBridge.mm` against the LLVM headers it just built, and publishes
  `XForgeNativeToolchain-arm64-ios.tar.gz` as a release asset tagged
  `toolchain-<llvm>-<swift|noswift>-ios<target>-sdk<sdk>` (and as a workflow
  artifact). It is dispatched by hand or by a pull request that touches
  `App/NativeToolchain/**`; only a dispatched run publishes, because a run that
  never built the Swift half must not become "the newest bundle". Its build trees
  are cached, so a run whose inputs are unchanged finishes in minutes rather than
  the ~80 minutes a cold build takes.
  See [Docs/NATIVE-TOOLCHAIN.md](Docs/NATIVE-TOOLCHAIN.md).
- **`ios-share.yml`** — builds the app for the simulator and keeps that simulator
  usable from a machine that is not a Mac, so a build can be tried by hand.

## Roadmap

- [x] In-process compilation: clang + `ld64.lld` linked into the app, called
      through a C++ bridge
- [x] Projects as ordinary directories in the app container
- [x] XKit signing wired into the export flow, for an identity the user has
- [x] Native toolchain bundle, built in CI and installed by `make toolchain`
- [ ] **The Swift frontend (`swift-frontend`) ported to iOS** — the gate on every
      Swift project, and the reason the artifact carries Clang and LLD only
- [ ] Build-setting evaluation and a build driver for a dependency graph
- [ ] `actool`/`ibtool` replacements (asset catalogs, storyboards)
- [ ] Apple ID provisioning (certificate issuance, 2FA) in-app
- [ ] Hand-off of built `.ipa` to SideStore/AltStore for install
- [ ] `RemoteExecutor` (build server) for fast compilation of real apps

## Licence note

XForge links no emulator and no kernel code; the app target is the SwiftUI sources
plus two SwiftPM dependencies, xtool's `XKit` and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT). xtool's own terms
apply to `XKit` — see its repository. The GPL note that used to be here concerned a
bundled emulator that is no longer part of the app.
