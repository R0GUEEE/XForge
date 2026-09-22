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
#include <sys/types.h>

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

/// Console — the guest's own terminal.
///
/// XForge implements the guest console as a tty driver, which is what makes the
/// terminal a *terminal* rather than a pipe: the line discipline lives in the
/// guest's kernel, so echo, line editing, Ctrl-C (ISIG), Ctrl-D and job control
/// all behave exactly as they do on a console. The engine calls the driver when
/// the guest writes to `/dev/tty1` or `/dev/console`; the host pushes input back
/// with `xf_ish_console_write`.
///
/// `/dev/tty1` and `/dev/console` are the same terminal (major `TTY_CONSOLE_MAJOR`,
/// minor 1), and it is the one pid 1's stdio is wired to — so `/sbin/init` and
/// everything it starts (login, its shell) talk to the screen in the app.
///
/// Read and write are safe from any thread: the write callback only appends to a
/// host buffer, `xf_ish_console_write` takes the tty's own lock inside the engine,
/// and neither touches the engine's per-thread state.

/// Start the guest's init as pid 1, giving it the console as its stdio.
///
/// This is what turns the mounted root into a *booted system*: `/sbin/init`
/// reads `/etc/inittab`, which respawns `/bin/login -f root` on the console.
/// Must be called on the engine thread, after `xf_ish_boot`. Returns 0, or a
/// negative errno.
int xf_ish_start_init(const char *program);

/// 1 once the guest console exists (something has opened `/dev/console`).
int xf_ish_console_ready(void);

/// Copy output produced by the guest console into `buf`, waiting up to
/// `timeout_ms` for at least one byte (-1 waits indefinitely, 0 returns at once).
///
/// Returns the number of bytes copied, 0 if the wait timed out, or a negative
/// errno. Callers poll this in a loop; it does not touch the engine's thread-
/// local state, so it may block on a thread of its own.
ssize_t xf_ish_console_read(char *buf, size_t len, int timeout_ms);

/// Feed host input into the guest console (keystrokes, pastes, control bytes).
/// Returns the number of bytes accepted, or a negative errno.
ssize_t xf_ish_console_write(const char *buf, size_t len);

/// Tell the guest console how big the screen is, so the guest's programs wrap
/// and lay out correctly. Returns 0, or a negative errno.
int xf_ish_console_resize(int cols, int rows);

/// Boot the guest from an installed fakefs root directory.
///
/// The root is *already* fakefs — a `data/` tree plus `meta.db`, converted on the
/// build machine by `tools/fakefsify` (see EmbeddedLinux/build-rootfs.sh). The app
/// only unzips it, so there is no import step here: `fakefs_import` is a build-time
/// tool in this design, not a runtime one.
///
/// `host_dir` (may be NULL) is mounted read-write into the guest at `/host`, so
/// the app's own container is reachable from inside Linux. That is how large
/// artifacts get in without pushing megabytes through the shell pipe. Returns 0
/// on success or a negative errno.
///
/// This creates pid 1, mounts the virtual filesystems, wires pid 1's stdio to the
/// console tty and brings up the host's end of that terminal — but it does not
/// exec anything: the caller decides when the guest's own `init` takes over, with
/// `xf_ish_start_init`. Keeping the two apart is what lets XForge verify the
/// mounted root before handing the machine to `/sbin/init`.
int xf_ish_boot(const char *root_dir, const char *host_dir);

/// 1 once the guest is booted and commands can be run.
int xf_ish_is_booted(void);

/// Run one command headlessly as a fresh child of init and capture its merged
/// stdout+stderr. `shell` is an absolute guest path (e.g. "/bin/sh") or NULL for
/// `/bin/sh`. `timeout_ms` of 0 means no timeout. Returns 0 if the command was
/// launched (inspect `result`), or a negative errno if it could not start.
///
/// This call blocks until the command exits.
int xf_ish_run(const char *command, const char *shell, int timeout_ms,
               size_t max_output, xf_guest_result *result);

/// Start a command and return its guest pid immediately, without waiting for it.
///
/// This exists because `xf_ish_run` blocks until the child exits, and the guest
/// engine may only be driven from one thread at a time — so a long-lived process
/// (an interactive shell) started through `xf_ish_run` would hold that thread
/// forever and nothing else could ever run. Starting it detached leaves the
/// engine free, and the caller polls the pid instead.
///
/// Returns the guest pid (> 0) on success, or a negative errno.
///
/// The process reads its stdin from `stdin_path` when that is not NULL: it is
/// opened once, when the child is created. Output is *not* captured — a detached
/// command is expected to redirect its own stdout/stderr (that is how the
/// terminal's transport works), so pass a path in the command itself.
int xf_ish_run_detached(const char *command, const char *shell, const char *stdin_path);

/// Whether a detached process is still running. Returns 1 while it is alive,
/// 0 once it has exited, or a negative errno for an unknown pid.
int xf_ish_process_alive(int pid);

// There is deliberately no blocking "wait for a detached process": the engine
// may only be driven from one thread, and a wait would hold it for the process's
// whole lifetime — the starvation that detached runs exist to avoid. Callers poll
// `xf_ish_process_alive` instead, which answers without blocking.

/// Ask a detached process to stop, by delivering `signal` to it. Returns 0 if the
/// signal was delivered or a negative errno.
///
/// This is a real guest signal, so Ctrl-C on an interactive shell reaches the
/// foreground program rather than merely detaching the screen.
int xf_ish_kill_process(int pid, int signal);

/// Free `result->output` and zero the struct.
void xf_guest_result_free(xf_guest_result *result);

/// Shut the guest down for this launch. The engine cannot boot a second machine
/// in the same process, so this only tears down local state.
void xf_ish_shutdown(void);

/// Human-readable description of the last failure on this thread.
const char *xf_ish_last_error(void);

#endif /* XFORGE_ISH_BRIDGE_H */
