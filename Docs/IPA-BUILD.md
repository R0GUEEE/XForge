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

1. If a free-Apple-ID identity is active → sign with that certificate (XKit Zupersign).
2. Otherwise → **ad-hoc** (fake-sign) so the `.ipa` is structurally valid and can be
   handed to SideStore/AltStore, which apply their own provisioning.
3. Entitlements: `get-task-allow`, `application-identifier`; team entitlements when a
   certificate is present.

## 5. BuildRequest / BuildResult

```swift
struct BuildRequest {
    var project: Project
    var configuration: BuildConfiguration     // debug | release
    var appInfo: AppInfo                      // bundle id, display name, version…
    var identity: SigningIdentity?            // nil → ad-hoc
}

struct BuildResult {
    let ipaURL: URL
    let stages: [BuildStageOutcome]           // per-stage timing/success
    let buildNumber: Int
}
```

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
- `BuildManager` transitions are testable by stubbing `BuildExecutor` to succeed/fail
  at each stage.

## 8. Files

```
Docs/IPA-BUILD.md                     this design
App/Models/BuildPipeline.swift        BuildStage, BuildRequest, BuildResult, BuildEvent
App/Build/IPABuilder.swift            host-side packaging (Payload, Info.plist, zip)
App/Build/CodeSigning.swift           signer abstraction (XKit real / ad-hoc)
App/Build/BuildManager.swift          orchestrator / state machine
AppTests/IPABuilderTests.swift        packaging unit tests
App/Views/Build/*                     UI driven by BuildManager.stages
```
