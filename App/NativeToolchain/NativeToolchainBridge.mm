#include "NativeToolchainBridge.h"
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

static void xf_copy_diag(const std::string &value, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return;
    const size_t n = std::min(value.size(), capacity - 1);
    std::memcpy(buffer, value.data(), n);
    buffer[n] = '\0';
}

#if defined(XFORGE_HAS_LLVM) && \
    __has_include(<clang/CodeGen/CodeGenAction.h>) && \
    __has_include(<clang/Frontend/CompilerInstance.h>) && \
    __has_include(<clang/Frontend/CompilerInvocation.h>) && \
    __has_include(<clang/Frontend/TextDiagnosticPrinter.h>) && \
    __has_include(<lld/Common/Driver.h>)

// Apple's SDK predefines IBAction and IBOutlet as macros (`#define IBOutlet
// __attribute__((iboutlet))`). Clang's generated AttrList.inc expands
// `INHERITABLE_ATTR(IBAction)` into `ATTR(IBAction)` → `class IBAction##Attr;`, so
// the predefined macro is pasted into the token paste and the header does not
// compile: "pasting formed ')Attr', an invalid preprocessing token". Clang's own
// headers undefine them for this reason on some revisions and not others, so it is
// done here, before any clang header is included.
#ifdef IBAction
#undef IBAction
#endif
#ifdef IBOutlet
#undef IBOutlet
#endif

#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <lld/Common/Driver.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/ADT/IntrusiveRefCntPtr.h>
#include <llvm/Support/raw_ostream.h>

#include <memory>
#include <type_traits>

#if defined(XFORGE_HAS_SWIFT_FRONTEND) && __has_include(<swift/FrontendTool/FrontendTool.h>)
#include <swift/FrontendTool/FrontendTool.h>
#define XFORGE_SWIFT_FRONTEND_READY 1
#else
#define XFORGE_SWIFT_FRONTEND_READY 0
#endif

LLD_HAS_DRIVER(macho)

extern "C" bool xf_native_toolchain_available(void) {
    return true;
}

extern "C" const char *xf_native_toolchain_version(void) {
#if XFORGE_SWIFT_FRONTEND_READY
    return "LLVM/Clang/LLD + Swift frontend native iOS backend";
#else
    return "LLVM/Clang/LLD native iOS backend";
#endif
}

extern "C" bool xf_native_swift_available(void) {
#if XFORGE_SWIFT_FRONTEND_READY
    return true;
#else
    return false;
#endif
}

extern "C" int xf_native_swift_frontend(int argc,
                                         const char * const *argv,
                                         char *diagnostics,
                                         size_t diagnostics_capacity) {
#if XFORGE_SWIFT_FRONTEND_READY
    if (argc <= 0 || !argv) {
        xf_copy_diag("native swift: empty frontend argument list", diagnostics, diagnostics_capacity);
        return 64;
    }
    // `swift-frontend -frontend …` is how the driver invokes the frontend, and it
    // hands performFrontend everything *after* `-frontend`. Accept both shapes, so
    // a caller that mirrors the command line does not hand parseArgs a flag it
    // rejects ("error: unknown argument: '-frontend'").
    const char *const *argsBegin = argv;
    size_t argsCount = static_cast<size_t>(argc);
    if (argsCount > 0 && std::strcmp(argsBegin[0], "-frontend") == 0) {
        argsBegin += 1;
        argsCount -= 1;
    }
    llvm::ArrayRef<const char *> args(argsBegin, argsCount);
    const int rc = swift::performFrontend(
        args,
        "swift-frontend",
        reinterpret_cast<void *>(&xf_native_swift_frontend),
        nullptr
    );
    if (rc != 0) {
        xf_copy_diag("swift::performFrontend returned a non-zero status", diagnostics, diagnostics_capacity);
    } else {
        xf_copy_diag("", diagnostics, diagnostics_capacity);
    }
    return rc;
#else
    (void) argc; (void) argv;
    xf_copy_diag("Swift frontend libraries are not linked into this XForge build.",
                 diagnostics, diagnostics_capacity);
    return 78;
#endif
}

namespace {

/// Whether this clang's `DiagnosticOptions` is still reference-counted.
///
/// Swift's LLVM fork (`swift/release/6.2`) is the older generation: options are
/// refcounted, `TextDiagnosticPrinter` takes a `DiagnosticOptions *`, and
/// `CompilerInstance` has no constructor taking an invocation. Upstream LLVM is the
/// newer one: a plain value taken by reference, and the invocation goes in through
/// the constructor. The bundle can be built from either, so both have to compile.
// The marker is the constructor the *printer* takes, because that is the thing
// being branched on: the older generation takes `DiagnosticOptions *`, the newer
// one takes a reference, and a pointer never converts to a reference, so this is
// exactly the generation test. (A trait on a member would not work: `Retain()`
// lives in `RefCountedBase` and is protected, so probing it fails access checking
// and answers "new" for both generations.)
constexpr bool xf_clang_uses_refcounted_diagnostics() {
    return std::is_constructible_v<clang::TextDiagnosticPrinter,
                                   llvm::raw_ostream &,
                                   clang::DiagnosticOptions *>;
}

/// Run one cc1-style invocation through a `CompilerInstance`.
template <bool RefCountedOptions>
bool xf_clang_execute(std::shared_ptr<clang::CompilerInvocation> invocation,
                      std::unique_ptr<clang::TextDiagnosticPrinter> printer) {
    if constexpr (RefCountedOptions) {
        // Older generation: the instance starts empty and is handed its
        // invocation afterwards.
        clang::CompilerInstance compiler;
        compiler.setInvocation(std::move(invocation));
        compiler.createDiagnostics(printer.release(), true);
        if (!compiler.hasDiagnostics()) return false;
        clang::EmitObjAction action;
        return compiler.ExecuteAction(action);
    } else {
        clang::CompilerInstance compiler(std::move(invocation));
        compiler.createDiagnostics(printer.release(), true);
        if (!compiler.hasDiagnostics()) return false;
        clang::EmitObjAction action;
        return compiler.ExecuteAction(action);
    }
}

/// The whole C entry point, as a template.
///
/// It has to be a template, and it has to be instantiated exactly once, for the
/// `if constexpr` below to mean anything: a discarded branch is only exempt from
/// instantiation inside a templated entity, and a *runtime* condition —
/// `if (xf_clang_uses_refcounted_diagnostics())` — instantiates both halves and
/// then fails on whichever one does not belong to this clang.
template <bool RefCountedOptions>
int xf_clang_compile_entry(const char *source_path,
                           const char *object_path,
                           const char *sdk_path,
                           const char *target_triple,
                           const char *language,
                           char *diagnostics,
                           size_t diagnostics_capacity) {
    if (!source_path || !object_path || !sdk_path || !target_triple) {
        xf_copy_diag("native clang: missing required argument", diagnostics, diagnostics_capacity);
        return 64;
    }

    std::string diagText;
    llvm::raw_string_ostream diagOS(diagText);

    std::vector<std::string> owned = {
        "-triple", target_triple,
        "-emit-obj",
        "-o", object_path,
        "-isysroot", sdk_path,
        "-fblocks",
        "-fobjc-arc"
    };

    const std::string lang = language ? language : "c";
    if (lang == "objective-c" || lang == "objc") {
        owned.insert(owned.end(), {"-x", "objective-c"});
    } else if (lang == "objective-c++" || lang == "objc++") {
        owned.insert(owned.end(), {"-x", "objective-c++"});
    } else if (lang == "c++" || lang == "cpp") {
        owned.insert(owned.end(), {"-x", "c++"});
    } else {
        owned.insert(owned.end(), {"-x", "c"});
    }
    owned.push_back(source_path);

    std::vector<const char *> args;
    args.reserve(owned.size());
    for (const auto &arg : owned) args.push_back(arg.c_str());

    auto diagIDs = llvm::IntrusiveRefCntPtr<clang::DiagnosticIDs>(new clang::DiagnosticIDs());
    auto invocation = std::make_shared<clang::CompilerInvocation>();

    if constexpr (RefCountedOptions) {
        // Older generation: reference-counted options, a pointer-taking printer.
        auto diagOpts = llvm::makeIntrusiveRefCnt<clang::DiagnosticOptions>();
        auto printer = std::make_unique<clang::TextDiagnosticPrinter>(diagOS, diagOpts.get());
        clang::DiagnosticsEngine diags(diagIDs, diagOpts, printer.get(), false);
        if (!clang::CompilerInvocation::CreateFromArgs(*invocation, args, diags)) {
            diagOS.flush();
            xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
            return 65;
        }
        const bool ok = xf_clang_execute<true>(invocation, std::move(printer));
        diagOS.flush();
        xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
        return ok ? 0 : 1;
    } else {
        // Newer generation: a plain value taken by reference.
        clang::DiagnosticOptions diagOpts;
        auto printer = std::make_unique<clang::TextDiagnosticPrinter>(diagOS, diagOpts);
        clang::DiagnosticsEngine diags(diagIDs, diagOpts, printer.get(), false);
        if (!clang::CompilerInvocation::CreateFromArgs(*invocation, args, diags)) {
            diagOS.flush();
            xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
            return 65;
        }
        const bool ok = xf_clang_execute<false>(invocation, std::move(printer));
        diagOS.flush();
        xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
        return ok ? 0 : 1;
    }
}

} // namespace

extern "C" int xf_native_clang_compile(const char *source_path,
                                        const char *object_path,
                                        const char *sdk_path,
                                        const char *target_triple,
                                        const char *language,
                                        char *diagnostics,
                                        size_t diagnostics_capacity) {
    // A constant expression as the template argument: exactly one instantiation
    // exists in a build, so the branch for the other generation is never
    // type-checked.
    return xf_clang_compile_entry<xf_clang_uses_refcounted_diagnostics()>(
        source_path, object_path, sdk_path, target_triple, language,
        diagnostics, diagnostics_capacity);
}

extern "C" int xf_native_lld_link(int argc,
                                   const char * const *argv,
                                   char *diagnostics,
                                   size_t diagnostics_capacity) {
    if (argc <= 0 || !argv) {
        xf_copy_diag("native lld: empty argument list", diagnostics, diagnostics_capacity);
        return 64;
    }

    llvm::ArrayRef<const char *> args(argv, static_cast<size_t>(argc));
    std::string stdoutText;
    std::string stderrText;
    llvm::raw_string_ostream stdoutOS(stdoutText);
    llvm::raw_string_ostream stderrOS(stderrText);

    const lld::DriverDef drivers[] = {{lld::Darwin, &lld::macho::link}};
    const lld::Result result = lld::lldMain(args, stdoutOS, stderrOS, drivers);
    stdoutOS.flush();
    stderrOS.flush();

    std::string combined = stdoutText;
    if (!combined.empty() && !stderrText.empty()) combined += "\n";
    combined += stderrText;
    if (!result.canRunAgain) {
        if (!combined.empty()) combined += "\n";
        combined += "lld reported that the linker cannot be safely re-entered.";
    }
    xf_copy_diag(combined, diagnostics, diagnostics_capacity);
    return result.retCode;
}

#else

extern "C" bool xf_native_toolchain_available(void) {
    return false;
}

extern "C" const char *xf_native_toolchain_version(void) {
    return "Native LLVM backend not linked";
}

extern "C" bool xf_native_swift_available(void) {
    return false;
}

extern "C" int xf_native_swift_frontend(int,
                                         const char * const *,
                                         char *diagnostics,
                                         size_t diagnostics_capacity) {
    xf_copy_diag("Native LLVM/Swift backend not linked.",
                 diagnostics, diagnostics_capacity);
    return 78;
}

extern "C" int xf_native_clang_compile(const char *,
                                        const char *,
                                        const char *,
                                        const char *,
                                        const char *,
                                        char *diagnostics,
                                        size_t diagnostics_capacity) {
    xf_copy_diag("XForge was built without XFORGE_HAS_LLVM and the native LLVM bundle.",
                 diagnostics, diagnostics_capacity);
    return 78;
}

extern "C" int xf_native_lld_link(int,
                                   const char * const *,
                                   char *diagnostics,
                                   size_t diagnostics_capacity) {
    xf_copy_diag("XForge was built without XFORGE_HAS_LLVM and the native LLVM bundle.",
                 diagnostics, diagnostics_capacity);
    return 78;
}

#endif
