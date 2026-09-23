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
