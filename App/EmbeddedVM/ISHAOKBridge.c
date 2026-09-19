//
//  ISHAOKBridge.c
//  XForge
//
//  C shim over the embedded iSH-AOK Linux engine. See ISHAOKBridge.h.
//
//  The boot sequence mirrors what iSH-AOK's own iOS app does in
//  -[AppDelegate boot] (mount the root, create init, mount the virtual
//  filesystems) and what its headless Shortcuts runner does
//  (run_guest_command_capture_shell), minus the UIKit/terminal machinery XForge
//  does not need.
//
//  The iSH-AOK core is built for the iOS *device* only (see
//  EmbeddedLinux/build-ish-aok-core.sh), so simulator builds — which the unit
//  tests use — compile the stub below instead of linking the engine.
//

#include "ISHAOKBridge.h"
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

// --- simulator stub ---------------------------------------------------------
// No engine is linked in simulator builds. Every entry point reports clearly.

#include <string.h>

static char s_sim_error[256];

const char *xf_ish_last_error(void) { return s_sim_error; }

static int xf_sim_unsupported(void) {
    strncpy(s_sim_error,
            "The iSH-AOK Linux engine runs on device only (simulator builds do not link it).",
            sizeof(s_sim_error) - 1);
    return -1;
}

int xf_ish_set_log_file(const char *path) {
    (void) path;
    return 0;
}

int xf_ish_log(const char *text) {
    (void) text;
    return 0;
}

int xf_ish_import_rootfs(const char *archive_path, const char *dest_dir) {
    (void) archive_path; (void) dest_dir;
    return xf_sim_unsupported();
}

int xf_ish_boot(const char *root_dir, const char *host_dir) {
    (void) root_dir; (void) host_dir;
    return xf_sim_unsupported();
}
int xf_ish_is_booted(void) { return 0; }

int xf_ish_run(const char *command, const char *shell, int timeout_ms,
               size_t max_output, xf_guest_result *result) {
    (void) command; (void) shell; (void) timeout_ms; (void) max_output;
    if (result != NULL) memset(result, 0, sizeof(*result));
    return xf_sim_unsupported();
}

void xf_guest_result_free(xf_guest_result *result) {
    if (result != NULL) memset(result, 0, sizeof(*result));
}

void xf_ish_shutdown(void) {}

#else

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// --- iSH-AOK core headers ---------------------------------------------------
#include "kernel/init.h"   // mount_root, become_first_process, run_guest_command_capture_shell
#include "kernel/fs.h"     // struct fs_ops, do_mount, fs_register, fakefs/procfs/...
#include "fs/real.h"       // realfs
#include "fs/devices.h"    // MEM_MAJOR, DEV_NULL_MINOR, TTY_ALTERNATE_MAJOR, ...
#include "fs/path.h"       // AT_PWD
#include "tools/fakefs.h"  // fakefs_import, fakefs_ensure_utf8_locale

// Core entry points that live in libish but have no small header of their own.
// (`main.c` reaches them the same way.)
extern void run_at_boot(void);
extern void host_mem_pressure_start(void);
extern void lockstats_init(void);
extern void guestprof_init(void);
extern void ish_accel_init(void);
extern void ish_accel_pix_init(void);
extern bool doEnableMulticore;

// --- state ------------------------------------------------------------------

// iSH-AOK's `current` is thread-local, so the thread that boots must be the one
// that runs commands. Swift funnels every call through one serial queue.
static __thread char s_error[512];
static bool s_global_inited = false;
static bool s_booted = false;

static void xf_fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s_error, sizeof(s_error), fmt, ap);
    va_end(ap);
}

const char *xf_ish_last_error(void) {
    return s_error[0] ? s_error : "";
}

// --- kernel log capture ------------------------------------------------------
//
// The engine's printk writes each line to file descriptor 555 (kernel/log.c,
// the dprintf log handler) -- the iSH-AOK app builds the engine with
// log_handler=nslog, but XForge's core build takes meson's default. Nothing in
// XForge opens 555, so until this exists, every kernel message is discarded:
// fakefs complaints, syscall errors, and the message `die()` prints on its way
// to `abort()`.
//
// Keeping the descriptor itself (rather than dup2'ing stderr) is deliberate:
// 555 is the number the engine writes to, and leaving it open means a message
// that arrives from a guest thread long after boot still lands somewhere.

#define XF_LOG_FD 555

static int s_log_fd = -1;

// printf-style breadcrumb into the log file.
static void xf_logf(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    xf_ish_log(buf);
}

int xf_ish_log(const char *text) {
    if (text == NULL)
        return -EINVAL;
    if (s_log_fd < 0)
        return -ENODEV;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &tm);

    char line[2048];
    int head = snprintf(line, sizeof(line), "[%02d:%02d:%02d.%03d] ",
                        tm.tm_hour, tm.tm_min, tm.tm_sec, (int) (tv.tv_usec / 1000));
    if (head < 0)
        head = 0;
    // Truncate rather than split: a partial line is worse than a clipped one.
    size_t room = sizeof(line) - (size_t) head - 2;
    size_t len = strlen(text);
    if (len > room)
        len = room;
    memcpy(line + head, text, len);
    line[head + (int) len] = '\n';
    ssize_t written = write(s_log_fd, line, (size_t) head + len + 1);
    return written < 0 ? -errno : 0;
}

int xf_ish_set_log_file(const char *path) {
    if (s_log_fd == XF_LOG_FD) {
        close(s_log_fd);
        s_log_fd = -1;
    }
    if (path == NULL || path[0] == '\0')
        return 0;

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return -errno;
    if (fd != XF_LOG_FD) {
        // The engine writes to the literal descriptor 555, so that is where the
        // file has to live for its output to be captured at all.
        if (dup2(fd, XF_LOG_FD) < 0) {
            int err = errno;
            close(fd);
            return -err;
        }
        close(fd);
        fd = XF_LOG_FD;
    }
    s_log_fd = fd;
    return 0;
}

// One-time process-global emulator init. Mirrors the head of iSH-AOK's
// `main()` (main.c): the same order, because lockstats hooks must be armed
// before any lock is taken and `run_at_boot` seeds the emulator's memory.
static void xf_global_init(void) {
    if (s_global_inited) return;
    s_global_inited = true;
    xf_logf("engine: global init on this thread (host_mem_pressure, lockstats, "
            "guestprof, run_at_boot, accel)");
    host_mem_pressure_start();
    lockstats_init();
    guestprof_init();
    run_at_boot();
    doEnableMulticore = true;
    ish_accel_init();
    ish_accel_pix_init();
}

// Make the guest filesystems reachable by name for the guest's own mount(2),
// and for our do_mount() calls below.
static void xf_register_filesystems(void) {
    fs_register(&fakefs);
    fs_register(&realfs);
    fs_register(&procfs);
    fs_register(&sysfs);
    fs_register(&devptsfs);
    fs_register(&tmpfs);
    fs_register(&devtmpfs);
    fs_register(&cgroupfs);
}

// The bundled minirootfs ships an empty /dev, and the guest userland needs the
// standard nodes before anything else runs. Mirrors the app's hand-built /dev.
static void xf_ensure_devices(void) {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/dev/shm", 01777);
    generic_mkdirat(AT_PWD, "/run", 0755);

    static const struct { const char *path; mode_t_ mode; int major; int minor; } nodes[] = {
        {"/dev/null",    S_IFCHR | 0666, MEM_MAJOR,          DEV_NULL_MINOR},
        {"/dev/zero",    S_IFCHR | 0666, MEM_MAJOR,          DEV_ZERO_MINOR},
        {"/dev/full",    S_IFCHR | 0666, MEM_MAJOR,          DEV_FULL_MINOR},
        {"/dev/random",  S_IFCHR | 0666, MEM_MAJOR,          DEV_RANDOM_MINOR},
        {"/dev/urandom", S_IFCHR | 0666, MEM_MAJOR,          DEV_URANDOM_MINOR},
        {"/dev/kmsg",    S_IFCHR | 0644, MEM_MAJOR,          DEV_KMSG_MINOR},
        {"/dev/tty",     S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx",    S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
        {"/dev/fuse",    S_IFCHR | 0666, MISC_MAJOR,         DEV_FUSE_MINOR},
    };
    for (size_t i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) {
        // EEXIST is expected on every boot after the first.
        generic_mknodat(AT_PWD, nodes[i].path, nodes[i].mode,
                        dev_make(nodes[i].major, nodes[i].minor));
    }

    ensure_dev_fd_links();
    ensure_root_fstab_entry();
    // Linux guarantees these modes; a tarball can leave them stricter.
    generic_setattrat(AT_PWD, "/tmp", (struct attr) { .type = attr_mode, .mode = S_IFDIR | 01777 }, false);
    generic_setattrat(AT_PWD, "/",    (struct attr) { .type = attr_mode, .mode = S_IFDIR | 0755 }, false);
}

// --- API --------------------------------------------------------------------

int xf_ish_import_rootfs(const char *archive_path, const char *dest_dir) {
    if (archive_path == NULL || dest_dir == NULL) return -EINVAL;

    xf_logf("import: begin %s -> %s", archive_path, dest_dir);
    xf_global_init();

    // libarchive needs a UTF-8 LC_CTYPE to read tarballs whose entries carry
    // UTF-8 link paths; iSH-AOK's rootfs importer does this too.
    fakefs_ensure_utf8_locale();

    struct fakefsify_error err;
    memset(&err, 0, sizeof(err));
    struct progress progress = { .cookie = NULL, .callback = NULL };

    if (!fakefs_import(archive_path, dest_dir, &err, progress)) {
        xf_logf("import: failed: %s: %s",
                err.type == ERR_ARCHIVE ? "archive" :
                err.type == ERR_SQLITE  ? "sqlite"  :
                err.type == ERR_POSIX   ? "posix"   : "cancelled",
                err.message ? err.message : "unknown error");
        xf_fail("rootfs import failed (%s): %s",
                err.type == ERR_ARCHIVE ? "archive" :
                err.type == ERR_SQLITE  ? "sqlite"  :
                err.type == ERR_POSIX   ? "posix"   : "cancelled",
                err.message ? err.message : "unknown error");
        free(err.message);
        return -EIO;
    }
    xf_logf("import: done");
    return 0;
}

int xf_ish_is_booted(void) {
    return s_booted ? 1 : 0;
}

int xf_ish_boot(const char *root_dir, const char *host_dir) {
    if (root_dir == NULL) return -EINVAL;
    if (s_booted) return 0;

    xf_global_init();
    xf_logf("boot: mounting %s/data as /", root_dir);

    // The fakefs filesystem is the root's `data` directory; `meta.db` sits
    // beside it. This is the same source iSH-AOK passes to mount_root.
    char data_dir[4096];
    int n = snprintf(data_dir, sizeof(data_dir), "%s/data", root_dir);
    if (n <= 0 || (size_t) n >= sizeof(data_dir)) {
        xf_fail("root path too long");
        return -ENAMETOOLONG;
    }

    intptr_t err = mount_root(&fakefs, data_dir);
    if (err < 0) {
        xf_logf("boot: mount_root failed: %s (%ld)", strerror((int) -err), (long) err);
        xf_fail("mount_root failed: %s (%ld)", strerror((int) -err), (long) err);
        return (int) err;
    }
    xf_logf("boot: root mounted");

    xf_register_filesystems();

    // Creates pid 1. After this the guest has an init task, which is all the
    // headless command runner needs -- XForge does not run /sbin/init, it runs
    // build commands as fresh children of init.
    xf_logf("boot: become_first_process");
    err = become_first_process();
    if (err < 0) {
        xf_logf("boot: become_first_process failed: %s (%ld)", strerror((int) -err), (long) err);
        xf_fail("become_first_process failed: %s (%ld)", strerror((int) -err), (long) err);
        return (int) err;
    }
    xf_logf("boot: pid 1 created");

    // Virtual filesystems and device nodes the guest userland expects. Failures
    // are not fatal: the rootfs may already provide some of these.
    xf_logf("boot: device nodes + /proc /sys /dev/pts");
    xf_ensure_devices();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&sysfs, "sysfs", "/sys", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // Share the app's own container into the guest at /host (realfs, world-
    // writable via MOUNT_ISH_SHARED_) so large artifacts — the darwin Swift SDK
    // is hundreds of megabytes — can be staged by the host instead of being
    // pushed through the command pipe. Not fatal if it fails.
    if (host_dir != NULL && host_dir[0] != '\0') {
        generic_mkdirat(AT_PWD, "/host", 0777);
        int merr = do_mount(&realfs, host_dir, "/host", "", MOUNT_ISH_SHARED_);
        if (merr < 0) {
            xf_logf("boot: could not share %s at /host: %s", host_dir, strerror(-merr));
            fprintf(stderr, "xforge: could not share the app container at /host: %s\n",
                    strerror(-merr));
        } else {
            xf_logf("boot: %s shared at /host", host_dir);
        }
    }

    s_booted = true;
    xf_logf("boot: guest is up");
    return 0;
}

int xf_ish_run(const char *command, const char *shell, int timeout_ms,
               size_t max_output, xf_guest_result *result) {
    if (command == NULL || result == NULL) return -EINVAL;
    memset(result, 0, sizeof(*result));

    if (!s_booted) {
        xf_fail("guest is not booted");
        return -ENODEV;
    }

    struct guest_command_result r;
    xf_logf("run: %.200s", command);
    int rc = run_guest_command_capture_shell(shell, command, NULL,
                                             timeout_ms, max_output, &r);
    if (rc < 0) {
        xf_logf("run: could not start: %s", strerror(-rc));
        xf_fail("could not start command: %s", strerror(-rc));
        return rc;
    }
    xf_logf("run: rc=%d launched=%d exited=%d code=%d signal=%d timed_out=%d "
            "truncated=%d bytes=%zu",
            rc, r.launched, r.exited, r.exit_code, r.term_signal, r.timed_out,
            r.truncated, r.output_len);

    // A failing command's own output is the most useful thing in the log --
    // that is where `swift sdk install` and `apk` say what went wrong. Cap it:
    // this file is meant to be shareable, not exhaustive.
    if (r.output != NULL && r.output_len > 0 &&
        (!r.exited || r.exit_code != 0 || r.timed_out || r.term_signal != 0)) {
        size_t cap = 4000;
        size_t len = r.output_len < cap ? r.output_len : cap;
        char *head = malloc(len + 1);
        if (head != NULL) {
            memcpy(head, r.output, len);
            head[len] = '\0';
            xf_logf("run: output%s:\n%s", r.output_len > cap ? " (truncated)" : "", head);
            free(head);
        }
    }

    result->launched    = r.launched;
    result->exited      = r.exited;
    result->exit_code   = r.exit_code;
    result->term_signal = r.term_signal;
    result->timed_out   = r.timed_out;
    result->truncated   = r.truncated;
    result->output      = r.output;
    result->output_len  = r.output_len;
    return 0;
}

void xf_guest_result_free(xf_guest_result *result) {
    if (result == NULL) return;
    free(result->output);
    memset(result, 0, sizeof(*result));
}

void xf_ish_shutdown(void) {
    // iSH-AOK cannot boot a second machine inside the same process, so there is
    // nothing to tear down beyond forgetting that we booted.
    s_booted = false;
}

#endif /* TARGET_OS_SIMULATOR */
