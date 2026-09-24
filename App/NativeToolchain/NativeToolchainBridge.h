#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True when XForge was linked with the native LLVM/Clang/LLD bundle.
bool xf_native_toolchain_available(void);

/// Human-readable backend description. Pointer remains valid for process lifetime.
const char *xf_native_toolchain_version(void);

/// True when the Swift frontend libraries are linked into this build.
bool xf_native_swift_available(void);

/// Compile one Swift source file through swift::performFrontend.
/// argv contains swift-frontend arguments without argv[0] or "-frontend".
int xf_native_swift_frontend(int argc,
                             const char * const *argv,
                             char *diagnostics,
                             size_t diagnostics_capacity);

/// Compile one C/Objective-C translation unit directly to an arm64 iOS object file.
/// Returns 0 on success. Diagnostics are copied into diagnostics when provided.
int xf_native_clang_compile(const char *source_path,
                            const char *object_path,
                            const char *sdk_path,
                            const char *target_triple,
                            const char *language,
                            char *diagnostics,
                            size_t diagnostics_capacity);

/// Link object files into a Mach-O executable with LLD's Darwin driver.
/// argv entries are passed directly to ld64.lld; argv[0] should be "ld64.lld".
int xf_native_lld_link(int argc,
                       const char * const *argv,
                       char *diagnostics,
                       size_t diagnostics_capacity);

#ifdef __cplusplus
}
#endif
