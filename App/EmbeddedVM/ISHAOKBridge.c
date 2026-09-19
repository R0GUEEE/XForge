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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

// One-time process-global emulator init. Mirrors the head of iSH-AOK's
// `main()` (main.c): the same order, because lockstats hooks must be armed
// before any lock is taken and `run_at_boot` seeds the emulator's memory.
static void xf_global_init(void) {
    if (s_global_inited) return;
    s_global_inited = true;
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

    xf_global_init();

    // libarchive needs a UTF-8 LC_CTYPE to read tarballs whose entries carry
    // UTF-8 link paths; iSH-AOK's rootfs importer does this too.
    fakefs_ensure_utf8_locale();

    struct fakefsify_error err;
    memset(&err, 0, sizeof(err));
    struct progress progress = { .cookie = NULL, .callback = NULL };

    if (!fakefs_import(archive_path, dest_dir, &err, progress)) {
        xf_fail("rootfs import failed (%s): %s",
                err.type == ERR_ARCHIVE ? "archive" :
                err.type == ERR_SQLITE  ? "sqlite"  :
                err.type == ERR_POSIX   ? "posix"   : "cancelled",
                err.message ? err.message : "unknown error");
        free(err.message);
        return -EIO;
    }
    return 0;
}

int xf_ish_is_booted(void) {
    return s_booted ? 1 : 0;
}

int xf_ish_boot(const char *root_dir, const char *host_dir) {
    if (root_dir == NULL) return -EINVAL;
    if (s_booted) return 0;

    xf_global_init();

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
        xf_fail("mount_root failed: %s (%ld)", strerror((int) -err), (long) err);
        return (int) err;
    }

    xf_register_filesystems();

    // Creates pid 1. After this the guest has an init task, which is all the
    // headless command runner needs -- XForge does not run /sbin/init, it runs
    // build commands as fresh children of init.
    err = become_first_process();
    if (err < 0) {
        xf_fail("become_first_process failed: %s (%ld)", strerror((int) -err), (long) err);
        return (int) err;
    }

    // Virtual filesystems and device nodes the guest userland expects. Failures
    // are not fatal: the rootfs may already provide some of these.
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
            fprintf(stderr, "xforge: could not share the app container at /host: %s\n",
                    strerror(-merr));
        }
    }

    s_booted = true;
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
    int rc = run_guest_command_capture_shell(shell, command, NULL,
                                             timeout_ms, max_output, &r);
    if (rc < 0) {
        xf_fail("could not start command: %s", strerror(-rc));
        return rc;
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
