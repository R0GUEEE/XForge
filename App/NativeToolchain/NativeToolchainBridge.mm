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
    __has_include(<clang/Serialization/PCHContainerOperations.h>) && \
    __has_include(<lld/Common/Driver.h>)

#include <clang/Basic/Diagnostic.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Serialization/PCHContainerOperations.h>
#include <lld/Common/Driver.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/ADT/IntrusiveRefCntPtr.h>
#include <llvm/Support/raw_ostream.h>

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

extern "C" int xf_native_clang_compile(const char *source_path,
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

    // Three signatures in this revision of Clang are easy to get wrong, and all
    // three are checked against the headers the toolchain ships
    // (swiftlang/llvm-project swift/release/6.2):
    //
    //   DiagnosticsEngine(IntrusiveRefCntPtr<DiagnosticIDs>,
    //                     IntrusiveRefCntPtr<DiagnosticOptions>,
    //                     DiagnosticConsumer *client = nullptr,
    //                     bool ShouldOwnClient = true)
    //   TextDiagnosticPrinter(raw_ostream &os, DiagnosticOptions *diags, ...)
    //   CompilerInstance(shared_ptr<PCHContainerOperations>, ModuleCache * = nullptr)
    //
    // So the options *are* refcounted here (and the printer wants the raw
    // pointer inside that reference), and the invocation is handed over through
    // setInvocation() rather than the constructor.
    auto diagOpts = llvm::makeIntrusiveRefCnt<clang::DiagnosticOptions>();
    auto diagPrinter = std::make_unique<clang::TextDiagnosticPrinter>(diagOS, diagOpts.get());
    auto diagIDs = llvm::IntrusiveRefCntPtr<clang::DiagnosticIDs>(new clang::DiagnosticIDs());
    clang::DiagnosticsEngine diags(diagIDs, diagOpts, diagPrinter.get(), false);

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

    auto invocation = std::make_shared<clang::CompilerInvocation>();
    if (!clang::CompilerInvocation::CreateFromArgs(*invocation, args, diags)) {
        diagOS.flush();
        xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
        return 65;
    }

    clang::CompilerInstance compiler(std::make_shared<clang::PCHContainerOperations>());
    compiler.setInvocation(invocation);
    compiler.createDiagnostics(diagPrinter.release(), true);
    if (!compiler.hasDiagnostics()) {
        xf_copy_diag("native clang: failed to create diagnostics engine", diagnostics, diagnostics_capacity);
        return 66;
    }

    clang::EmitObjAction action;
    const bool ok = compiler.ExecuteAction(action);
    diagOS.flush();
    xf_copy_diag(diagText, diagnostics, diagnostics_capacity);
    return ok ? 0 : 1;
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
