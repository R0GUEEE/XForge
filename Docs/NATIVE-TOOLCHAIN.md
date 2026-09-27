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
- `NativeToolchain/install-bundle.sh <archive> | --release [tag]` — installs that
  bundle, from a local file or from its release.
- `App/NativeToolchain/XipArchive.swift` — reads Apple's `.xip` container far enough
  to take an SDK out of it. xar header and table of contents, the pbzx stream inside
  the `Content` member, and the `odc` cpio archive that decompresses to — streamed,
  one 16 MB block at a time, with Apple's own `Compression` decoding the LZMA2 blocks
  so the app carries no decompressor of its own.
- `App/NativeToolchain/DarwinSDKBuilder.swift` — turns an `Xcode.xip` into a
  `darwin.artifactbundle` on the device: xtool's path list, its bundle layout, and
  the `swift-sdk.json` `NativeSDK` reads.
- `NativeToolchain/prepare-xcode.sh` — writes the xcconfig the app target consumes.
  `build-ipa.yml` runs it too, so CI never depends on a bundle being installed
  locally; on a checkout with no bundle it writes the disabled configuration and CI
  builds the stub.

## What a bundle contains — and which half it has

The workflow cross-builds, for iPhoneOS arm64:

- **Clang**, as the library set the bridge calls (`clangCodeGen`, `clangFrontend`,
  `clangFrontendTool`, `clangDriver`, `clangSerialization`, `clangSema`, `clangParse`,
  `clangAST`, `clangLex`, `clangBasic`), plus `clangDependencyScanning`;
- **Mach-O LLD** (`lldMachO`, `lldCommon`);
- **`LLVMOrcJIT`**, which Swift's in-process JIT needs;
- and, in a `with_swift` build, **Swift's frontend libraries** (`swiftFrontendTool`
  and the swiftAST / swiftSema / IRGen / ClangImporter set it pulls in), built from
  `swiftlang/swift` against `swiftlang/llvm-project` — for iOS, as a library set.

The target list is not "everything the app might use" but the closure the bundle has
to satisfy, because the link check force-loads every archive: each member's undefined
symbols must resolve *inside* the bundle. `clangDependencyScanning` (used by
`ClangImporter` to scan a target's module dependencies) and `LLVMOrcJIT` (used by
`SwiftMaterializationUnit.cpp`) are the two that no clang library pulls in by itself,
and leaving them out produced a bundle that compiled and then failed to link — with
the missing symbols visible only as a truncated tail. The link check now prints all
of them.

`manifest.txt` is how a consumer knows what it has:

```
bundle_tag=toolchain-<llvm sha>-<swift ref|noswift>-ios<target>-sdk<sdk>
target=arm64-apple-ios
deployment_target=17.0
llvm_commit=…
swift_frontend=0|1
swift_ref=swift-6.2.4-RELEASE|none
xcode=16.4
ios_sdk=18.5
built_at=…
archives=lib/XForgeToolchain.libraries.txt
header_roots=include-generated include
```

`prepare-xcode.sh` reads `swift_frontend` and defines `XFORGE_HAS_SWIFT_FRONTEND`
accordingly, so a bundle without the frontend still builds the whole app: the bridge
compiles to the stub for that entry point and the UI reports `swift-frontend: missing`
rather than claiming a compiler it does not have.

The two halves are deliberately independent. The Clang/LLD half is a complete
deliverable for C, Objective-C and Objective-C++ targets and can be validated on its
own while the considerably larger Swift port is brought up; the tag says which one a
bundle is (`…-swift-<ref>-…` versus `…-noswift-…`), so they never have to be guessed
apart.

## How the bundle is built (CI)

`.github/workflows/native-toolchain.yml`, job `llvm-ios`, on a `macos-15` runner:

1. Check out Swift's LLVM fork (`swiftlang/llvm-project`, the branch paired with the
   Swift version) and, for a `with_swift` build, `swiftlang/swift`, `swift-cmark`,
   `swift-syntax` and `swift-experimental-string-processing`.
2. Restore the build trees from the Actions cache. The key names the LLVM revision,
   the deployment target and the runner's Xcode/SDK, so a hit means "the compiler for
   exactly these inputs" — and the sources are then aged to a fixed past date, so the
   restored tree is newer than every source. Without that ageing ninja treats the
   whole tree as stale and rebuilds it: the restore paid seconds to avoid a
   2601-edge rebuild and got it anyway.
3. Build the host tools natively (`llvm-tblgen`, `clang-tblgen`, `llvm-ar`,
   `llvm-nm`) and, with Swift, a native `cmark` plus the iOS cmark archives.
4. Configure LLVM for iPhoneOS arm64 with `LLVM_ENABLE_PROJECTS="clang;lld"`,
   `LLVM_TARGETS_TO_BUILD=AArch64`, deployment target 17.0, tools and examples off.
   Skipped when the restored tree came back already configured and built.
5. Build the library targets listed above (~37 minutes cold), then, with Swift,
   the frontend libraries (~34 minutes cold).
6. **Compile-check the bridge against the headers just built** — `clang++ -arch arm64
   -isysroot <iPhoneOS SDK> -DXFORGE_HAS_LLVM=1 -c App/NativeToolchain/NativeToolchainBridge.mm`.
   This is the check that keeps a header change in LLVM from silently breaking the
   bridge in a device build nobody can run yet.
7. Stage the headers into two roots — sources into `include/`, the build tree into
   `include-generated/`, because they disagree about `swift/bridging` — and merge
   every static archive in the build into one `dist/lib/libXForgeNativeToolchain.a`
   with `llvm-ar -M` and an MRI `addlib` script. `addlib` copies *every* member:
   `libtool -static` de-duplicates them by name (`duplicate member name 'X86.cpp.o'
   from libclangCodeGen.a and …`), and a dropped member is a silently missing object —
   which is how the JIT symbols once came out undefined while their object was
   demonstrably in the archive. The merge fails if it produced fewer members than it
   consumed.
8. **Link-check**: link a program that calls `xf_native_toolchain_available()` against
   the merged archive and the bridge object, with every archive force-loaded, and
   assert the result is a real Mach-O. Force-loading makes this the strictest check
   available: it fails unless every member resolves inside the bundle. On failure it
   prints every undefined symbol, not a tail of them.
9. Write `manifest.txt` and tar the result as `XForgeNativeToolchain-arm64-ios.tar.gz`
   — uploaded as the workflow artifact of the same name, and, when a hand-dispatched
   run that built the Swift half succeeded, **published as a release asset** tagged
   `toolchain-<llvm>-swift-<ref>-ios<target>-sdk<sdk>`. A `noswift` bundle is a
   complete deliverable for C and Objective-C targets but is not published: a
   consumer asking for "the newest toolchain release" means the full one, and the
   tag would otherwise be the only thing standing between them and a bundle with no
   frontend in it.

The cache is why none of this needs doing twice. A run whose inputs are unchanged
restores both trees and goes straight to the staging and link checks. Everything
unusual about the workflow — the key salts, the save gating (a tree is stored only if
the build that produced it finished), the "skip the configure when the tree is already
built" rule, the aged sources — exists for that one property, and each was added after
a run that spent an hour rebuilding what the cache already had.

Publishing is what takes the cost off everyone else. `build-ipa.yml` installs the
bundle from the newest `toolchain-*` release, so building the app never waits for a
toolchain run and a toolchain run never has to be in the same repository state as the
app it serves. Only dispatched runs publish: a pull request or push run builds the
LLVM-only half, and publishing that as the newest bundle is exactly what a consumer
asking for "the newest one" must not get.

## How it is installed

```bash
make toolchain-release          # the newest published bundle
make gen
```

A specific release, a local tarball, or a bundle that was built but not published:

```bash
make toolchain-release TAG=toolchain-<…>
make toolchain ARCHIVE=XForgeNativeToolchain-arm64-ios.tar.gz
NativeToolchain/install-bundle.sh --release artifact
```

`install-bundle.sh` fetches the asset (the GitHub CLI if it is installed, `curl`
otherwise) or unpacks the local archive into `Vendor/NativeToolchain`, and refuses an
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

## The Darwin SDK

The compiler is in the binary; what it compiles *against* is a bundle in the app's
container, `<Documents>/native-sdk/darwin.artifactbundle`. `NativeSDK` reads it the
way xtool's builder writes it (`swift-sdk.json`: SDK root, Swift resource directory,
static runtime search paths), and the Toolchain screen installs one of three things:

| what you pick | what it is |
| --- | --- |
| *(button)* | the hosted `darwin-sdk-<n>` release asset — about 460 MB, no Mac needed |
| a **folder** or **zip** | a `darwin.artifactbundle`, perhaps built by `xtool sdk build` on a Mac |
| an **`Xcode.xip`** | Apple's Xcode; the app builds the bundle from it here |

The third is the one that would otherwise send you to a Mac. A `.xip` is a xar archive
whose `Content` member is a pbzx stream of LZMA2 blocks decompressing to an `odc` cpio
archive of `Xcode.app`; `XipArchive` walks it in a single streaming pass and writes
only the paths a build SDK needs, and `DarwinSDKBuilder` assembles them into a bundle
— xtool's own list of paths, restricted to the device platform, because XForge only
ever compiles for the device. Extracting is minutes of CPU and about 1.5 GB of disk
on top of the copy the document picker makes, so the import checks free space before
it starts, reports progress while it runs, and deletes the picker's copy afterwards.

`Docs/DESIGN.md` §3 has the format and layout details; the code states them where the
decisions are made.

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

## Which half you have

The frontend is in the bundle or it is not, and `manifest.txt` says which — so the
honest statement is per bundle rather than per project:

- A **`noswift`** bundle has no frontend. Swift projects cannot be built from it and
  fail up front with `swiftFrontendMissing` and the file count; that is not a fallback
  situation — there is no guest to fall back to — it is the other half of the port,
  while C, Objective-C and Objective-C++ work in full.
- A **`swift-*`** bundle carries the frontend, so the Swift capability row reports it
  like any other part and the Swift smoke test is reachable. Its Swift revision has to
  match the app's: the frontend reads the deployment SDK's standard-library modules,
  which is why the workflow pins the LLVM/Swift refs to the pair the Xcode in use
  ships, and why `build-ipa.yml` warns when the installed bundle and the runner's
  Xcode disagree.
