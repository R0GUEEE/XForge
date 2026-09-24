# Native iPhone toolchain proof of concept

This branch starts the migration away from the embedded Linux runtime.

## Goal

Run the compiler and Mach-O linker directly inside `XForge.app` on a stock iPhone:

```
source -> Clang/Swift frontend -> arm64 object -> LLD Mach-O -> .app -> sign -> IPA
```

No Linux rootfs, `fork`, `exec`, `posix_spawn`, or remote build host is required at runtime.

## What is implemented

- `NativeToolchainBridge.mm`: in-process Objective-C++ bridge for Clang codegen and
  the LLD Darwin driver.
- `NativeToolchain.swift`: safe Swift wrapper plus an end-to-end C -> arm64 iOS
  object smoke test.
- Stub behavior when the LLVM bundle is not linked, so normal XForge builds remain
  buildable while the native toolchain artifact is being produced.
- `.github/workflows/native-toolchain.yml`: builds the iOS-hosted LLVM/Clang/LLD
  libraries on a macOS GitHub runner.

The existing Alpine executor is intentionally retained as a fallback until the native
backend can compile Swift and package a complete app.

## Runtime contract

The native implementation is enabled only when the app target defines
`XFORGE_HAS_LLVM=1` and can see the LLVM/Clang/LLD headers. Otherwise the bridge
returns `Native LLVM backend not linked`.

The first validation milestone is:

```
int xforge_native_smoke(void) { return 42; }
        |
        v
clang::CompilerInstance + EmitObjAction
        |
        v
arm64-apple-ios main.o
```

The next milestone is linking that object with the Darwin LLD driver against a
minimal iPhoneOS SDK, followed by embedding the Swift frontend.


## Native Darwin SDK

The app now has a host-side SDK store at:

```
Documents/native-sdk/darwin.artifactbundle
```

It consumes xtool's existing `swift-sdk.json` metadata directly and resolves the
`arm64-apple-ios` SDK root, Swift resource directory and platform library search
paths without booting Alpine.

The Native Toolchain settings screen can download the existing
`darwin.artifactbundle.zip` release directly into this store and run the C smoke test.

## Swift frontend boundary

The bridge now also exposes an optional Swift frontend:

```
Swift source
    |
    v
xf_native_swift_frontend
    |
    v
swift::performFrontend(...)
    |
    v
arm64-apple-ios .o
```

This is compile-time gated behind `XFORGE_HAS_SWIFT_FRONTEND`. Until a Swift
frontend library set has been cross-built for iPhoneOS, the UI reports
`Swift frontend: Not linked` and the Swift smoke test remains disabled.

This separation is intentional: the LLVM/Clang/LLD port can be validated and used
independently while the significantly larger Swift compiler port is brought up.
