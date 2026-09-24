# The native iPhone toolchain

XForge compiles in its own process: there is no Linux guest and no subprocess. The
compiler and the Mach-O linker are LLVM libraries **linked into the app binary**,
called through a small Objective-C++ bridge.

```
source -> Clang / swift-frontend -> arm64 object -> ld64.lld -> .app -> .ipa
             (in-process, no fork/exec/posix_spawn, no remote build host)
```

## Goal

Run the compiler and Mach-O linker directly inside `XForge.app` on a stock iPhone.
iOS cannot spawn a process, so "run clang" means "call clang's libraries"; the only
alternative would be a remote build host, which is a different product.

## What is implemented

- `App/NativeToolchain/NativeToolchainBridge.mm` — the in-process bridge: Clang
  codegen (`CompilerInvocation` + `EmitObjAction`), the `swift::performFrontend`
  entry point, and the LLD Darwin driver.
- `App/NativeToolchain/NativeToolchain.swift` — the Swift wrapper, plus an
  end-to-end C compile smoke test.
- `App/Build/NativeToolchainInvocation.swift` — the argument lists as pure
  functions. The convention is not obvious and is worth stating: the frontend entry
  point is handed everything *after* `-frontend`, so neither the program name nor
  `-frontend` itself may appear in the array; passing it makes
  `CompilerInvocation::parseArgs` reject the whole invocation.
- **Stub behaviour when the bundle is not linked**, so an ordinary clone (and every
  simulator build) compiles and runs with no toolchain present.
- `.github/workflows/native-toolchain.yml` — builds the iOS-hosted LLVM/Clang/LLD
  libraries and publishes the bundle. See below.
- `NativeToolchain/install-bundle.sh <archive>` — installs that bundle.
- `NativeToolchain/prepare-xcode.sh` — writes the xcconfig the app target consumes.
  `build-ipa.yml` runs it too, so CI never depends on a bundle being installed
  locally; on a checkout with no bundle it writes the disabled configuration and CI
  builds the stub.

## What the bundle contains — and what it does not

The workflow cross-builds, for iPhoneOS arm64:

- **Clang**, as the library set the bridge calls (`clangCodeGen`, `clangFrontend`,
  `clangFrontendTool`, `clangDriver`, `clangSerialization`, `clangSema`, `clangParse`,
  `clangAST`, `clangLex`, `clangBasic`);
- **Mach-O LLD** (`lldMachO`, `lldCommon`).

It does **not** contain the Swift frontend. `swift-frontend` is not part of
`llvm-project`: it has to be built from `swiftlang/swift` against
`swiftlang/llvm-project` **for iOS**, as a library set. That port is the long pole
and it is not done, so:

- **Swift sources cannot be compiled today.** A plan that contains Swift files
  fails at the compile stage with `swiftFrontendMissing`, naming the count of files.
- C, Objective-C and Objective-C++ sources compile and link today.
- The bridge does expose the entry point (`xf_native_swift_frontend`), gated behind
  `XFORGE_HAS_SWIFT_FRONTEND`, so the port has somewhere to land. Until a frontend
  library set exists, the gate is closed and the UI reports `swift-frontend: missing`.

The two halves are deliberately independent: the Clang/LLD port can be validated
and used on its own while the considerably larger Swift compiler port is brought up.

## How the bundle is built (CI)

`.github/workflows/native-toolchain.yml`, job `llvm-ios`, on a `macos-15` runner:

1. Build host TableGen tools (`llvm-tblgen`, `clang-tblgen`) natively — the iOS
   cross-build needs a native TableGen to generate tables it can run.
2. Configure LLVM for iPhoneOS arm64 with `LLVM_ENABLE_PROJECTS="clang;lld"`,
   `LLVM_TARGETS_TO_BUILD=AArch64`, deployment target 17.0, tools and examples off.
3. Build the Clang and LLD library targets listed above.
4. **Compile-check the bridge against the headers just built** — `clang++ -arch arm64
   -isysroot <iPhoneOS SDK> -DXFORGE_HAS_LLVM=1 -c App/NativeToolchain/NativeToolchainBridge.mm`.
   This is the check that keeps a header change in LLVM from silently breaking the
   bridge in a device build nobody can run yet.
5. Stage the headers into two roots — sources into `include/`, the build tree into
   `include-generated/`, because they disagree about `swift/bridging` — then
   **flatten every
   static archive in the build into one** `dist/lib/libXForgeNativeToolchain.a` with
   `libtool -static`. Flattening is deliberate: the app then links one archive
   instead of depending on LLVM's internal archive ordering, which would otherwise
   have to be reproduced by hand in the xcconfig.
6. **Link-check**: link a program that calls `xf_native_toolchain_available()`
   against the flattened archive and the bridge object, and assert the result is a
   real Mach-O. A library set that compiles but cannot link is the failure this step
   exists to catch.
7. Write `manifest.txt` (`target=arm64-apple-ios`, `deployment_target=17.0`,
   `llvm_commit=…`, `built_at=…`, `archive=…`) and tar the result as
   `XForgeNativeToolchain-arm64-ios.tar.gz`, uploaded as the workflow artifact of the
   same name.

It is dispatched by hand (or by a pull request that touches `App/NativeToolchain/**`),
because it takes hours and its output changes only when the LLVM commit does.

## How it is installed

```bash
make toolchain ARCHIVE=XForgeNativeToolchain-arm64-ios.tar.gz
make gen
```

`install-bundle.sh` unpacks the archive into `Vendor/NativeToolchain` and refuses an
archive that is missing `manifest.txt`, `include/`, `include-generated/` or `lib/` — a
partial bundle would otherwise surface as an inscrutable compile error much later. It
then runs `prepare-xcode.sh`, which writes `Support/NativeToolchain.generated.xcconfig`:

```
XFORGE_NATIVE_TOOLCHAIN_AVAILABLE = 1
XFORGE_NATIVE_HEADER_SEARCH_PATHS = $(SRCROOT)/Vendor/NativeToolchain/include-generated $(SRCROOT)/Vendor/NativeToolchain/include
XFORGE_NATIVE_LIBRARY_SEARCH_PATHS = $(SRCROOT)/Vendor/NativeToolchain/lib
XFORGE_NATIVE_CFLAGS = -DXFORGE_HAS_LLVM=1
XFORGE_NATIVE_LDFLAGS = <the archive> -lc++ -lz -liconv -lsqlite3 -framework Foundation
```

The two header roots are searched in that order and are deliberately not merged. The
build tree *generates a file* at `swift/bridging` (the C++ interop header, included as
`<swift/bridging>`) while Swift's sources have a *directory* of the same name
(`include/swift/Bridging/`). On a case-insensitive filesystem that is one path, so
staging both into a single root fails — `cp: .../swift/bridging: Is a directory` — and
the ordered pair is what a normal Swift/LLVM cross-build uses as well.

`project.yml` consumes those variables and nothing else, so the app target never
names a path inside the bundle directly.

When the bundle is **absent**, `prepare-xcode.sh` writes the same file with the
backend disabled. That file is **checked in, disabled**, so a plain clone builds:
the bridge compiles to a "not available" stub and the app says so. This is why
`make gen` alone is a complete build for someone who only wants to work on the UI.

## The runtime contract

The native implementation is enabled only when the app target defines
`XFORGE_HAS_LLVM=1` and can see the LLVM/Clang/LLD headers. Otherwise the bridge
answers `xf_native_toolchain_available() == 0` and every entry point fails
cleanly — no half-linked state, and no path where the app believes it has a
compiler it does not have.

`NativeToolchainCapabilities.current` is the single source of that truth for the
UI. It reports clang, `ld64.lld`, `swift-frontend`, the SDK and the backend version
as separate lines, because "the toolchain is missing" is not one condition:

- `canCompile` requires clang and LLD. It deliberately does **not** require the
  Swift frontend: a C target links fine without it, and refusing to start would be
  wrong about why the build fails.
- When clang or LLD is absent the app reports the missing toolchain and names the
  way to fix it (`NativeToolchain/install-bundle.sh`, then rebuild), rather than
  failing somewhere in the middle with a linker error.

## The smoke test

The Toolchain screen's **Verify** section compiles a C file
(`int xforge_native_smoke(void) { return 42; }`) through the linked clang, against
the installed SDK, in this process, and reports the object file it produced and its
size. The button needs both a linked compiler and an installed SDK, so it cannot
report success on a build that only has one of the two.

This is what a real build does, at the smallest size that can fail: a compiler that
is present but mis-linked (wrong target triple, no SDK, missing resource directory)
fails here in a way the capability rows cannot detect. The screen's own footer
describes the check as compiling *and linking*; the button currently compiles only,
and the build-time link check lives in the toolchain workflow (step 6 above).

## Known gap

Until the Swift frontend libraries exist for iPhoneOS:

- Swift projects cannot be built on device. This is not a fallback situation — there
  is no guest to fall back to — it is the remaining port.
- The Swift capability row is reported honestly (`missing`), the Swift smoke test
  remains unreachable, and a build that needs it fails up front with
  `swiftFrontendMissing` and the file count.
