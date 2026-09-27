# XForge IPA Build Tool — design

The on-device engine that turns an authored project into a signed, sideloadable
`.ipa`. This is the "build tool" layer between the GUI and the compiler libraries
linked into the app.

## 1. Goal

From a project the user has authored, produce a valid `.ipa`:

```
project directory ──► NativeBuildPlan ──► arm64-apple-ios executable
   (editable)          (resolved, refused           (clang / swift-frontend,
                        up front)                    linked with ld64.lld,
                                                     in this process)
        ──► <Name>.app ──► unsigned .ipa ──► signed .ipa
                            (Payload/ + zip)   (XKit, on the Signing screen)
```

Everything is driven from one orchestrator (`BuildManager`) that exposes a strict
state machine to the UI, so the GUI always knows exactly which stage is running.

## 2. Pipeline stages (state machine)

```
1. provision   report the linked toolchain (clang, ld64.lld, swift-frontend) and
               require the Darwin SDK; fail with an explanation if either is absent
2. sdk         install the Darwin SDK into the app container, if it is not there
3. configure   check the project directory and record the app identity
4. resolve     report "nothing to resolve", or refuse a project that declares
               SwiftPM dependencies
5. compile     plan → per-file compile → link → assemble .app → package unsigned .ipa
6. package     accept the packaged artifact
7. artifact    confirm the .ipa exists, is non-empty, and report its size
```

Each stage is idempotent (skippable if already done) and reports progress. Any stage
can fail; failures carry a human message, and the pipeline stops at the **first**
one, because everything after it fails as a consequence and would bury the cause.

There is no "boot a guest" stage, and that is the whole point of the current design:
the compiler is a library call, so there is nothing to start before compiling.

### What each stage actually does

| Stage | Implementation | Notes |
|---|---|---|
| provision | `NativeBuildExecutor.bootstrap` + `NativeToolchainCapabilities` | Reports one line per component. Fails when clang or LLD is not linked; *warns* when the Swift frontend is not. |
| sdk | `NativeSDK.install(fromRemote:)` | Skips itself when the bundle is already in the container. |
| configure | `BuildManager.configure` | Writes `<project>/.xforge-build/build.json` (bundle ID, version, build number, configuration) so a failed build is reproducible, and throws `missingProjectDirectory` if the directory is gone. |
| resolve | `NativeBuildExecutor.resolve` + `NativeBuildPlanFactory.swiftPackageDependencies` | A textual scan of `Package.swift`; the answer it needs is only "are there any". |
| compile | `NativeBuildExecutor.build` | The real work: plan, compile, link, assemble, package. Also the stage that refuses Swift sources (`swiftFrontendMissing`). |
| package | `BuildManager.package` | The executor packages the IPA as the last step of compiling, so this stage accepts the result rather than producing it. |
| artifact | `BuildManager.stageArtifact` | A final stage that checks the file rather than reporting success unconditionally. |

### The Swift frontend limitation, stated where it bites

`NativeBuildExecutor.build` throws `NativeBuildError.swiftFrontendMissing(n)` — with
`n` the number of Swift files — when the plan has Swift sources and the frontend is
not linked. In the shipped toolchain bundle the frontend is never linked: the CI
workflow that builds the bundle builds Clang and Mach-O LLD only. So **a Swift
project cannot be compiled today**, and the failure happens before any file is
compiled, not after a partial build.

The consequence for this pipeline is structural, not cosmetic: the stages that
exist are correct and exercised for C and Objective-C targets, and the Swift-
specific stages (module boundaries, a dependency graph, asset catalogs) are the
work that remains. Until then the pipeline can honestly describe itself as "a build
tool that compiles C", and the app says so rather than letting a user discover it
three stages in.

## 3. Split of responsibilities

| Concern | Where | Why |
|---|---|---|
| Reading a project into a plan | `NativeBuildPlanFactory` (host) | Pure directory reading; no compiler needed, so it is fully testable |
| Argument construction | `NativeToolchainInvocation` (host) | Pure functions; the compiler only exists on a device, so this is the only half that can be unit-tested |
| Compiling and linking | `NativeToolchain*` (in-process libraries) | iOS cannot spawn a compiler |
| Bundle assembly, `Info.plist` merge | `NativeBuildExecutor` | Needs the plan and the compiled executable |
| Packaging (Payload, zip) | `IPABuilder` (host) | Testable, works with any `.app`, has no opinion about what built it |
| Signing | `AppBundleSigner` / `IPASigningJob` (XKit, in-process) | A separate step, on its own screen, so the unsigned IPA stays a first-class artifact |

This split means `IPABuilder` is fully testable without a compiler: give it any
compiled `.app` + `AppInfo` and it produces a valid `.ipa`.

## 4. Signing strategy: unsigned first, then signed

The build produces an **unsigned** `.ipa`, staged at
`<Documents>/staging/<name>-<version>.ipa`. Signing is `IPASigningJob`:

1. Unzip the `.ipa` into a temporary directory and find the single `.app` under
   `Payload/` (more or fewer than one is an error, not a guess).
2. Read the `.p12` through the Security framework (`PKCS12Identity.load`), with the
   password held only for the duration of the attempt and cleared afterwards. The
   private key is used in memory and written nowhere — which is why the old
   `zsign` password-file workaround is gone with `zsign`.
3. Apply the identity overrides the user typed (bundle ID, display name, version)
   to the bundle's `Info.plist`. Only those three: replacing the plist wholesale
   would drop `CFBundleExecutable` and produce an app that cannot launch.
4. Write `embedded.mobileprovision` into the bundle **before** signing — the signer
   reads it to decide which entitlements the signature may carry, and a signature
   that does not match its profile is rejected at install time.
5. Sign with XKit's `Signer`, and re-zip the `Payload/` as
   `<Documents>/Signed-<name>.ipa`.

What this does **not** do is obtain a certificate. An Apple ID session needs
anisette + GrandSlam + 2FA (XKit's `SigningContext`/`DeveloperServices` path), which
is a separate, device-only piece of work; `XKitSigningService.signIn` throws rather
than reporting a signed-in account it does not have. The signer takes an existing
`.p12` and profile.

## 5. The pipeline's own types

`BuildManager` owns one run and publishes a `PipelineSnapshot` for the UI
(`App/Models/BuildPipeline.swift`):

```swift
enum BuildStage: String, CaseIterable {
    case provision, sdk, configure, resolve, compile, package, artifact
}
enum BuildStageState: Equatable { case pending, running, succeeded, failed }

struct PipelineSnapshot: Equatable {
    var stages: [BuildStage: BuildStageState]
    var consoleText: String
    var isRunning: Bool
    var lastIpa: URL?
    var error: String?
}
```

Each stage is a method on `BuildManager` run in order, and each one stops the
pipeline on failure. `BuildExecutor` is the seam to the toolchain: `bootstrap()`,
`createProject`, `installSDK`, `resolve` and `build` all return an
`AsyncThrowingStream<BuildEvent, Error>`, which `BuildManager.consume` folds into
the snapshot. Packaging inside the executor is a single host-side call:
`IPABuilder.buildIPA(appBundle:appInfo:outputDir:)`.

The stage **title** for `package` in `BuildPipeline.swift` reads "Package & sign
.ipa", which is a leftover from when the stage did both; the stage now packages and
the Signing screen signs.

## 6. Failure handling

- Stage-scoped: a failure marks that stage `.failed` and stops the pipeline (unless
  the stage is retryable and the user retries).
- The `BuildEvent` stream carries both progress lines (for the console) and
  structured stage transitions (for the step UI).
- Compile and link failures carry the tool's diagnostics text; an empty diagnostics
  buffer is reported as "reported a failure without diagnostics" rather than
  silently producing a bare exit code.
- Staged artifacts are written under `Documents/staging/` and listed by the
  Artifacts screen. Intermediate objects and the `.app` live under
  `<project>/.xforge-build`, which is discarded at the start of the next build.

## 7. Testability

- `NativeBuildTests` covers the half of the build that can be tested without a
  compiler: plan acceptance and refusals (including the SwiftPM-dependency refusal
  and the textual dependency scan ignoring local targets), the Swift frontend and
  linker argument lists, the `main.swift` case, and search-path filtering.
- `IPABuilderTests` builds a fake `.app` fixture in the test bundle and asserts the
  produced `.ipa` contains `Payload/<Name>.app/Info.plist` with the right values and
  is a valid zip.
- `XcodeProjectTests` covers the `.xcodeproj` reader against an embedded project
  file.
- Nothing tests the compiler itself: it does not exist in a simulator build. That
  is the boundary this design accepts, and the reason argument construction was
  extracted into pure functions.

## 8. Files

```
Docs/IPA-BUILD.md                        this design
App/Models/BuildPipeline.swift           BuildStage, BuildStageState, PipelineSnapshot
App/Models/Project.swift                 BuildExecutor protocol, BuildEvent, SDKSource
App/Build/BuildManager.swift             orchestrator / state machine
App/Build/NativeBuildPlan.swift          the plan and the factory that refuses
App/Build/NativeToolchainInvocation.swift argument construction (pure)
App/Build/NativeBuildExecutor.swift      the BuildExecutor: compile, link, assemble, package
App/Build/IPABuilder.swift               host-side packaging (Payload, Info.plist, zip)
App/Build/NativeToolchainCapabilities.swift  what this build can compile with
App/Services/AppBundleSigner.swift       XKit signing, in process
App/Services/IPASigningJob.swift         the signing workflow (unzip, overrides, re-zip)
App/Models/BuildHistoryStore.swift       run history for the History screen
AppTests/NativeBuildTests.swift          plan + argument unit tests
AppTests/IPABuilderTests.swift           packaging unit tests
App/Views/Build/*                        UI driven by BuildManager.snapshot
```

Docs that go with this one: `Docs/DESIGN.md` (the whole app) and
`Docs/XCODE-ALTERNATIVE.md` (building existing Xcode projects on-device). The
toolchain bundle that makes any of this run is described in
`Docs/NATIVE-TOOLCHAIN.md`.
