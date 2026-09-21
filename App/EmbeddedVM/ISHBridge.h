//
//  ISHBridge.h
//  XForge
//
//  Thin C shim over the embedded Linux engine, **ish-arm64**
//  (github.com/OpenMinis/ish-arm64).
//
//  ish-arm64 is a fork of ish-app/ish that adds a native AArch64 guest backend
//  to the threaded-code interpreter. That matters for XForge: the bundled root
//  filesystem is an Alpine *aarch64* minirootfs, so with this engine it runs as
//  a same-architecture guest (a handful of host instructions per guest
//  instruction) instead of being cross-translated from x86. It emulates
//  instructions by dispatching to pre-compiled "gadget" functions — it does not
//  emit machine code at runtime and needs no executable memory, so it works in
//  a sideloaded app with no JIT entitlement.
//
//  XForge links the engine's core static libraries (`libish`, `libish_emu`,
//  `libfakefs`) plus `tools/fakefs.c` (for `fakefs_import`) and this shim, then
//  boots the root filesystem bundled in the app.
//
//  Everything here is a plain C ABI so Swift can call it through the bridging
//  header. All calls must be made from one dedicated permanent OS thread:
//  the engine's `current` task pointer is thread-local, and a serial dispatch
//  queue does not guarantee pthread affinity.
//
#ifndef XFORGE_ISH_BRIDGE_H
#define XFORGE_ISH_BRIDGE_H

#include <stddef.h>

/// Outcome of one headless guest command.
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

/// Point the engine's own log at `path` (append mode) and remember it for
/// `xf_ish_log`. Pass NULL to stop logging.
///
/// The engine's `printk` goes through its `log_handler`, chosen at build time.
/// XForge builds with `-Dlog_handler=nslog` (see EmbeddedLinux/build-ish-core.sh)
/// so kernel messages reach the device console. This file is for the messages
/// XForge itself produces around them — boot stages, import progress, and the
/// output of a command that failed — which is what makes a bug report readable.
///
/// Returns 0 on success or a negative errno.
int xf_ish_set_log_file(const char *path);

/// Append one timestamped line to the log set by `xf_ish_set_log_file`.
/// No-op (returning -ENODEV) when no log file is set.
int xf_ish_log(const char *text);

/// Progress callback for the rootfs import. `fraction` is 0..1 and `message` is
/// the archive entry currently being unpacked (both may be NULL/0 on the first
/// call). Return 0 to continue or non-zero to cancel the import.
typedef int (*xf_import_progress_fn)(void *cookie, double fraction, const char *message);

/// Import a rootfs archive (`.tar.gz`, `.tar.xz`, ...) into a brand-new fakefs
/// root directory (`data/` + `meta.db`). `dest_dir` must not exist yet.
///
/// `progress` may be NULL. When supplied it is called from the importing thread
/// — frequently, once per archive entry, so callers should throttle whatever
/// they do with it rather than drawing per call.
///
/// Returns 0 on success or a negative errno. See `xf_ish_last_error`.
int xf_ish_import_rootfs(const char *archive_path, const char *dest_dir,
                         xf_import_progress_fn progress, void *cookie);

/// Boot the guest from an already-imported fakefs root directory.
///
/// `host_dir` (may be NULL) is mounted read-write into the guest at `/host`, so
/// the app's own container is reachable from inside Linux. That is how the
/// darwin Swift SDK and other large artifacts get in without pushing gigabytes
/// through the shell pipe. Returns 0 on success or a negative errno.
///
/// XForge boots deliberately headless: it does NOT exec `/sbin/init`. XForge
/// only needs a pid 1 that can be the parent of the commands it runs, so it
/// stops after `become_first_process()` instead of handing over to the guest's
/// init and its console machinery.
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

/// Shut the guest down for this launch. The engine cannot boot a second machine
/// in the same process, so this only tears down local state.
void xf_ish_shutdown(void);

/// Human-readable description of the last failure on this thread.
const char *xf_ish_last_error(void);

#endif /* XFORGE_ISH_BRIDGE_H */
