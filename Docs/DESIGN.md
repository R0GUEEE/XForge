# XForge — build iOS apps on-device with xtool

Working title: **XForge**. An iOS app (sideload-only) that compiles an authored
project into a real, signed iOS app entirely on the phone, using the compiler,
linker and signing libraries linked into its own process.

Status: fully on-device, no remote build host. The old architecture — an embedded
iSH-style Linux — is gone; this document describes what replaced it and why the
replacement takes the shape it does.

---

## 1. How the build works (the mechanism)

XForge does not orchestrate a build by running other programs. **iOS does not let
an app spawn a process** — there is no `fork`/`exec`/`posix_spawn` in the sandbox —
so every step that a build tool would normally run as a child is instead a library
call in XForge's own process:

1. **Read the project into a plan.** `NativeBuildPlanFactory` walks the project
   directory (`Package.swift`, `Sources/<Target>/`) and produces a
   `NativeBuildPlan`: the module and executable names, the Swift and C-family
   translation units, the resources, the frameworks, and the `-L`/`-F` search
   paths. Nothing compiles until this value exists, and nothing in the executor
   re-decides any of it.
2. **Compile.** Swift sources would go through `swift::performFrontend` — but the
   frontend libraries are only in a bundle built with `with_swift`, so a plan with
   Swift files is refused at this point when the installed bundle has none (§2,
   third bullet). C, Objective-C and
   Objective-C++ sources compile through clang's `CompilerInstance` with
   `EmitObjAction`. Both take an argument list built by
   `NativeToolchainInvocation`, against the iPhoneOS SDK in the Darwin SDK bundle.
3. **Link.** `ld64.lld` (through `lld::lldMain`) links the objects against the SDK's
   `.tbd` stubs and the static Swift runtime into an `arm64-apple-ios` executable.
4. **Assemble.** The executor writes `<Name>.app`: the executable at mode 0755, an
   `Info.plist` (generated keys, over which a hand-written project template is
   merged), and the resources.
5. **Package.** `IPABuilder` lays the bundle out under `Payload/` and zips it. The
   result is an **unsigned** `.ipa`.
6. **Sign.** `IPASigningJob` + `AppBundleSigner` sign with `XKit`, xtool's own
   library and the same code path that signs on a Mac. Signing is a separate step
   from packaging on purpose: the pipeline can hand an unsigned IPA to a signing
   service, and it can hand the same IPA to XKit.

### Why the plan is a separate value

The compiler only exists in a *device* build — the libraries are linked in by
`Support/NativeToolchain.generated.xcconfig`, which is disabled on a plain clone.
A wrong argument list would therefore be undiscoverable until a build ran on a
phone with a real SDK. Splitting "what to build" (the plan) and "how to invoke
the tools" (the pure `NativeToolchainInvocation` functions) from "call the tools"
(the executor) means the parts that can be wrong silently are the parts that unit
tests can check, on a simulator, with no compiler present. `AppTests/NativeBuildTests.swift`
is exactly that.

### Where the plan draws the line

An in-process driver cannot do everything a build system does. Rather than fail
somewhere in the middle, the plan factory refuses by name where it cannot resolve
what is needed, and the executor states plainly where it can only copy:

- **SwiftPM dependencies.** Resolving them means fetching packages and *running*
  their manifests, which needs a package manager process. The factory scans
  `Package.swift` textually for `.package(` lines — enough to answer "are there
  any", which is all it needs — and refuses the project, naming the packages.
- **Projects with no `Sources/` directory**, or no compilable sources in it: there
  is no useful build to produce and no way to guess one.
- **Asset catalogs are *not* refused**, but they are not compiled either: `.xcassets`
  are copied into the bundle whole and the console says why. `actool` is a
  macOS-only tool, so an app whose icon lives in a catalog ships without it. Copying
  rather than dropping them keeps the project round-tripping.

## 2. Where the toolchain comes from

The Clang/LLD libraries are **cross-built for iPhoneOS in CI** on a macOS runner
(`.github/workflows/native-toolchain.yml`), merged into a single static archive and
published as a release asset (tagged `toolchain-<llvm>-<swift|noswift>-ios…`).
`NativeToolchain/install-bundle.sh --release` fetches it, or unpacks a local archive,
into `Vendor/NativeToolchain`, and `NativeToolchain/prepare-xcode.sh` writes the
xcconfig the app target consumes.

The consequences of linking the compiler in rather than shipping it as data:

- **It cannot be installed at runtime.** Either the libraries are in the binary or
  they are not; the Toolchain screen can only *report* them. That is why
  `NativeToolchainCapabilities` exists and why the first build stage fails with an
  explanation instead of a linker error.
- **A plain clone still builds.** `Support/NativeToolchain.generated.xcconfig` is
  checked in with the backend disabled, so the bridge compiles to a "not available"
  stub. Simulator builds and `make test` need nothing else.
- **The Swift frontend is a separate, larger port.** The workflow builds Clang and
  LLD only, so `swift-frontend` is absent from the artifact and Swift sources
  cannot be compiled yet. The capability is reported honestly rather than assumed:
  `canCompile` requires clang and LLD, not the frontend, because refusing to start
  a C build would be wrong about why it works.

## 3. Where the `darwin` SDK comes from

`xtool sdk build <Xcode.xip>` produces the `darwin` SDK from a real Xcode. That is a
macOS program shelling out to `xar`, so the `.xip` path used to stop at "impossible
on a phone" — and the default is still the cheap one: a `darwin.artifactbundle` is
**built once in CI** and published as a release asset under XForge's own
`darwin-sdk-<n>` release series, and the app resolves the newest matching release at
build time. About 460 MB.

The bundle is installed into the app container at
`<Documents>/native-sdk/darwin.artifactbundle` and read directly: `NativeSDK` parses
the same `swift-sdk.json` layout xtool's builder emits, resolving the SDK root, the
Swift resource directory and the static runtime search paths.

Three things can be installed from the Toolchain screen, told apart by what they are
rather than by what they are called: that hosted bundle (a zip), a
`darwin.artifactbundle` **folder** (perhaps built by `xtool sdk build` on a Mac), and
an Apple **`Xcode.xip`**, which the app now builds into a bundle itself
(`DarwinSDKBuilder` + `XipArchive`). The third is the one that needs no Mac:

- a `.xip` is a xar archive whose `Content` member is a pbzx stream of LZMA2 blocks,
  which decompresses to an `odc` cpio archive of `Xcode.app`. `XipArchive` reads it
  in one pass, streaming, and hands only the wanted entries to disk;
- which entries those are is xtool's own list (`SDKBuilder.wanted`), not a guess:
  `Contents/Developer/Platforms/iPhoneOS.platform/{Info.plist,Developer/{SDKs,usr/lib,Library/Frameworks,Library/PrivateFrameworks}}`
  and `Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/{swift,swift_static,clang}`,
  minus `swift/prebuilt-modules` (per-configuration build output measured in GB);
- one deliberate narrowing: xtool builds a bundle for three platforms because a Mac
  builds for all of them, and XForge only ever compiles for the device, so only
  `iPhoneOS.platform` is extracted and `swift-sdk.json` declares only
  `arm64-apple-ios`. A third of the work and a third of the disk for the same
  capability.

Extraction is minutes of CPU and ~1.5 GB of disk on top of whatever the document
picker copied, and both are checked before it starts rather than discovered halfway
through. The install is staged and validated (`NativeSDK.layout`) before it replaces
what is there, so a bad bundle cannot leave the app without an SDK.

> Note: Apple also publishes official iOS Swift SDKs on swift.org, but they use the
> triple `aarch64-apple-ios` under a different bundle name. xtool hardcodes
> `darwin` + `arm64-apple-ios`, so we produce our own `darwin` bundle to match
> xtool exactly.

## 4. App architecture

```
XForge.app  (nothing else — no guest, no subprocesses)
├─ Projects             — author a SwiftPM package; ProjectFiles reads/writes the directory
│   ├─ project directory   <Documents>/projects/<name>
│   ├─ file browser / source editor / manifest editor
│   ├─ import              copy a folder picked in Files (no git: an app cannot spawn it)
│   └─ export              ProjectExporter → <Documents>/exports/<name>.zip
├─ Build
│   ├─ BuildManager        — the stage state machine the Build screen draws
│   ├─ NativeBuildPlan     — what to build, resolved and refused up front
│   ├─ NativeBuildExecutor — the BuildExecutor; calls the libraries
│   ├─ NativeToolchain*    — the C++ bridge (clang, swift-frontend, ld64.lld)
│   └─ IPABuilder          — Payload/ + zip → unsigned .ipa
├─ Signing              — IPASigningJob: .p12 + profile → AppBundleSigner (XKit) → signed .ipa
├─ Toolchain            — capabilities, Darwin SDK install/remove, smoke test
└─ Settings             — app sandbox browser, build history, log, diagnostics
```

Two structural decisions are worth stating because they are not obvious:

- **The build pipeline has one executor.** There used to be a choice between a
  local guest and a "remote" backend that never existed. Both the choice and the
  guest are gone; `XForgeEnvironment.makeExecutor` returns one implementation.
- **Signing is not part of the build stage.** The stage named "Package & sign
  .ipa" packages; the signing happens on the Signing screen, where the user
  supplies the identity. Keeping them apart is what lets the same unsigned IPA be
  signed by XKit or handed to SideStore.

## 5. What is backed up, and what is not

Everything XForge generates lives in `Documents`, which iOS backs up to iCloud and
— because the app declares `UIFileSharingEnabled` — shows in the Files app. Two
kinds of things live there and they want opposite treatment:

- **Regenerable**: downloads, the Darwin SDK, staged build artifacts, the log.
  Marked `isExcludedFromBackup` at launch (`XForgeEnvironment.prepareStorage`).
  Backing them up bloats every device backup with data the app can produce again,
  which the storage guidelines forbid.
- **User data**: projects and exports. Both are backed up, deliberately.

**Projects are ordinary directories in the app container and are backed up.** That
is a reversal of the old position, and the reason it changed is worth recording: a
project used to live *inside* the guest filesystem, which had to be excluded as a
whole — several gigabytes of Linux, toolchain and SDK — and nothing could mark the
megabyte of source without also marking the gigabytes around it. The only way work
survived a device restore was to export it. Now that the toolchain runs in-process,
a project is a directory of files this process can open, so it is excluded from
nothing and restored like any other document. Export remains, and is still the way
work leaves the app, but it is a convenience rather than the only escape hatch.

The rule the code follows is: exclude what can be downloaded or rebuilt, back up
what the user wrote. `XForgeEnvironment` is the single place that decides which
directories these are, so the storage rules cannot drift from `prepareStorage`.

## 6. BuildExecutor, and what is left of the abstraction

```swift
@MainActor
protocol BuildExecutor {
    func bootstrap() async throws -> AsyncThrowingStream<BuildEvent, Error>
    func installSDK(from source: SDKSource) async throws
    func createProject(named:organizationIdentifier:) async throws -> Project
    func resolve(_ project: Project) async throws -> AsyncThrowingStream<BuildEvent, Error>
    func build(_ project: Project, configuration: BuildConfiguration) async throws -> AsyncThrowingStream<BuildEvent, Error>
}
```

`NativeBuildExecutor` is the only implementation. The protocol survives for two
reasons: it is the seam a future `RemoteExecutor` would implement, and it keeps the
`BuildManager` state machine honest about what a stage is allowed to assume.

Every method streams `BuildEvent`s — progress lines for the console, structured
stage transitions for the step UI — so long work reports while it happens instead
of at the end.

## 7. Honest performance note

Compilation is native code now, not emulation: the old note about a JIT emulator
being slow no longer applies to the compiler itself. What is still true is that the
executor compiles translation units **one at a time**, so it does not use the
device's cores the way `swift build` or `xcodebuild` do, and that a phone compiles
more slowly than a Mac. How much of either matters for a real project is
**unverified** — it has not been measured on a device against a non-trivial
project, and it cannot even be approached until Swift compiles at all. XForge is a
*demonstrator and authoring tool* for the on-device path; a remote executor is the
sane answer for large projects, and the protocol above is where it would attach.

## 8. Delivery / sideload pipeline

- **CI (GitHub Actions, macOS runner)** builds the unsigned IPA, verifies it, and
  publishes it as a release asset.
- **Device install**: the user installs XForge via SideStore/AltStore.
- **Built apps**: XForge produces `.ipa`s that are signed with XKit (with an
  identity the user supplies) or handed to SideStore to sign and install on the
  same device.

## 9. Repo layout

```
.github/workflows/    build-ipa.yml (the unsigned IPA), native-toolchain.yml (the
                      iOS LLVM cross-build), ios-share.yml (a simulator build)
project.yml           XcodeGen definition
App/                  SwiftUI app sources
App/Build/            the pipeline: plan, invocation, executor, IPABuilder, manager
App/NativeToolchain/  the in-process compiler bridge + the Darwin SDK store
App/Services/         signing, project files, export, releases, log
App/Models/           pipeline, history, project store, XcodeProject
App/Views/            Projects, Build, Signing, Toolchain, Settings
AppTests/             unit tests (plan and argument construction)
Vendor/NativeToolchain/  the installed toolchain bundle (absent by default)
NativeToolchain/      install-bundle.sh, prepare-xcode.sh
Support/              Info.plist spec, entitlements, assets, the generated xcconfig
Tools/                gen-appicon.py
Docs/                 this design doc + the pipeline, toolchain and Xcode-alternative notes
```
