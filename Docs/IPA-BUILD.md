# XForge IPA Build Tool — design

The on-device engine that turns a SwiftPM project into a signed, sideloadable `.ipa`.
This is the "build tool" layer between the GUI and the embedded Linux.

## 1. Goal

From a project the user has authored, produce a valid `.ipa`:

```
SwiftPM project ──► arm64-apple-ios .app ──► signed .ipa ──► SideStore/device
   (editable)        (compiled in guest)     (packaged+sign on host)
```

Everything is driven from one orchestrator (`BuildManager`) that exposes a strict
state machine to the UI, so the GUI always knows exactly which stage is running.

## 2. Pipeline stages (state machine)

```
1. provision   ensure embedded Linux is booted + Swift toolchain + xtool present
2. sdk         ensure the `darwin` Swift SDK (arm64-apple-ios) is installed
3. configure   write xtool.yml + Info.plist from the user's AppInfo/settings
4. resolve     `swift package resolve` in the project (pull SPM deps)
5. compile     `xtool dev build`  → cross-compile to arm64-apple-ios .app
6. package     host-side IPABuilder: assemble Payload, write Info.plist/entitlements,
               codesign (real identity or ad-hoc), zip → .ipa
7. artifact    stage the .ipa, hand it to the UI for export / install
```

Each stage is idempotent (skippable if already done) and reports progress. Any stage
can fail; failures carry a human message + a machine-readable reason.

## 3. Split of responsibilities

| Concern | Where | Why |
|---|---|---|
| Provision, SDK install, resolve, compile | **Embedded Linux** (VM) via `BuildExecutor` | needs Swift + xtool + SDK |
| Config injection (xtool.yml, Info.plist) | host, before compile | user edits live in the GUI |
| Packaging (Payload, zip), final signing | **host** via `IPABuilder` | testable, works with any .app |
| Certificates / Apple ID | host via `SigningService` (XKit) | native on iOS |

This split means `IPABuilder` is fully testable without the VM: give it any compiled
`.app` + `AppInfo` + a signer and it produces a valid `.ipa`.

## 4. Signing strategy

The current build exports an unsigned `.ipa`, which must be signed by Xcode,
SideStore/AltStore, or another signing service before installation. XKit-based
Apple ID authentication and signing are planned but are not wired into this build.

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

Each stage is a method on `BuildManager` run in order (`provision` → `ensureSDK` →
`configure` → `resolve` → `compile` → `package` → `stageArtifact`), and each one stops
the pipeline on failure. `BuildExecutor` (`App/Models/Project.swift`) is the seam to the
VM: `bootstrap()`, `createProject`, `installSDK`, `resolve` and `build` all return an
`AsyncThrowingStream<BuildEvent, Error>`, which `BuildManager.consume` folds into the
snapshot. Packaging is a single host-side call:
`IPABuilder.buildIPA(appBundle:appInfo:outputDir:)`.

## 6. Failure handling

- Stage-scoped: a failure marks that stage `.failed` and stops the pipeline (unless the
  stage is retryable and the user retries).
- `BuildEvent` stream carries both progress lines (for the console) and structured
  stage transitions (for the step UI).
- Staged artifacts are written under `Documents/staging/` and listed by the Artifacts
  screen.

## 7. Testability

- `IPABuilder` unit tests build a fake `.app` fixture in the test bundle and assert the
  produced `.ipa` contains `Payload/<Name>.app/Info.plist` with the right values and is
  a valid zip.
- `XcodeProjectTests` covers the `.xcodeproj` reader against an embedded project file.
- `ReleaseResolutionTests` drives `ToolchainManager` and `XForgeReleases` through a
  stubbed `LinuxVM`/`ShellSession`, so SDK resolution is testable without the VM.

## 8. Files

```
Docs/IPA-BUILD.md                     this design
App/Models/BuildPipeline.swift        BuildStage, BuildStageState, PipelineSnapshot
App/Models/Project.swift              BuildExecutor protocol, BuildEvent
App/Build/BuildManager.swift          orchestrator / state machine
App/Build/IPABuilder.swift            host-side packaging (Payload, Info.plist, zip)
App/Build/EmbeddedLinuxExecutor.swift the VM-backed BuildExecutor
App/Models/BuildHistoryStore.swift    run history for the History screen
App/Services/SigningService.swift     signing abstraction (integration pending)
AppTests/IPABuilderTests.swift        packaging unit tests
App/Views/Build/*                     UI driven by BuildManager.snapshot
```

Docs that go with this one: `Docs/DESIGN.md` (the whole app),
`Docs/XCODE-ALTERNATIVE.md` (building existing Xcode projects on-device),
`Docs/NATIVE-TOOLCHAIN.md` (the in-process LLVM path) and
`Docs/ISH-ARM64-INTEGRATION.md` (the embedded Linux engine).
