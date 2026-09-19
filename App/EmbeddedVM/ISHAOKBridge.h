//
//  ISHAOKBridge.h
//  XForge
//
//  Thin C shim over the embedded iSH-AOK Linux engine.
//
//  iSH-AOK (github.com/emkey1/ish-AOK) runs a real Linux guest in-process on
//  iOS: its "gadget JIT" needs no JIT entitlement, so it works in a sideloaded
//  app. XForge links iSH-AOK's core static libraries (`libish`, `libish_emu`,
//  `libfakefs`) plus `tools/fakefs.c` and this shim, then boots the bundled
//  Alpine aarch64 root filesystem from inside the app.
//
//  Everything here is a plain C ABI so Swift can call it through the bridging
//  header. All calls must be made from one dedicated serial queue: iSH-AOK's
//  `current` task pointer is thread-local, and both boot and command execution
//  temporarily repoint it.
//
#ifndef XFORGE_ISHAOK_BRIDGE_H
#define XFORGE_ISHAOK_BRIDGE_H

#include <stddef.h>

/// Outcome of one headless guest command. Mirrors iSH-AOK's
/// `struct guest_command_result`.
typedef struct xf_guest_result {
    int launched;    ///< the command started in the guest
    int exited;      ///< exit_code is valid
    int exit_code;   ///< exit status when exited != 0
    int term_signal; ///< terminating signal when exited == 0
    int timed_out;   ///< killed because timeout_ms elapsed
    int truncated;   ///< output hit max_output
    char *output;    ///< merged stdout+stderr, malloc'd (free with xf_guest_result_free)
    size_t output_len;
} xf_guest_result;

/// Import a rootfs archive (`.tar.xz`, `.tar.gz`, ...) into a brand-new fakefs
/// root directory (`data/` + `meta.db`). `dest_dir` must not exist yet.
/// Returns 0 on success or a negative errno. See `xf_ish_last_error`.
int xf_ish_import_rootfs(const char *archive_path, const char *dest_dir);

/// Boot the guest from an already-imported fakefs root directory.
///
/// `host_dir` (may be NULL) is mounted read-write into the guest at `/host` with
/// realfs, so the app's own container is reachable from inside Linux. That is how
/// the darwin Swift SDK and other large artifacts get in without pushing gigabytes
/// through the shell pipe. Returns 0 on success or a negative errno.
int xf_ish_boot(const char *root_dir, const char *host_dir);

/// 1 once the guest is booted and commands can be run.
int xf_ish_is_booted(void);

/// Run one command headlessly as a fresh child of init and capture its merged
/// stdout+stderr. `shell` is an absolute guest path (e.g. "/bin/sh") or NULL for
/// `/bin/sh`. `timeout_ms` of 0 means no timeout. Returns 0 if the command was
/// launched (inspect `result`), or a negative errno if it could not start.
int xf_ish_run(const char *command, const char *shell, int timeout_ms,
               size_t max_output, xf_guest_result *result);

/// Free `result->output` and zero the struct.
void xf_guest_result_free(xf_guest_result *result);

/// Shut the guest down for this launch. iSH-AOK cannot boot a second machine in
/// the same process, so this only tears down local state.
void xf_ish_shutdown(void);

/// Human-readable description of the last failure on this thread.
const char *xf_ish_last_error(void);

#endif /* XFORGE_ISHAOK_BRIDGE_H */
