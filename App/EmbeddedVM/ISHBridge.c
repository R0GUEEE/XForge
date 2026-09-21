//
//  ISHBridge.c
//  XForge
//
//  C shim over the embedded Linux engine, ish-arm64. See ISHBridge.h.
//
//  The boot sequence mirrors what the engine's own iOS app does in
//  -[AppDelegate boot] (mount the root, create init, mount the virtual
//  filesystems and create device nodes) and how its ISHShellExecutor spawns a
//  process (become_new_init_child, wire fds, do_execve, task_start), minus the
//  UIKit/terminal machinery XForge does not need.
//
//  The engine is built for the iOS *device* only (see
//  EmbeddedLinux/build-ish-core.sh), so simulator builds — which the unit tests
//  use — compile the stub below instead of linking the engine.
//

#include "ISHBridge.h"
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

// --- simulator stub ---------------------------------------------------------
// No engine is linked in simulator builds. Every entry point reports clearly.

#include <string.h>

static char s_sim_error[256];

const char *xf_ish_last_error(void) { return s_sim_error; }

static int xf_sim_unsupported(void) {
    strncpy(s_sim_error,
            "The ish-arm64 Linux engine runs on device only (simulator builds do not link it).",
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
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// --- ish-arm64 core headers -------------------------------------------------
#include "kernel/init.h"   // mount_root, become_first_process, become_new_init_child
#include "kernel/fs.h"     // struct fs_ops, do_mount, fs_register, fakefs/procfs/...
#include "kernel/task.h"   // struct task, current, task_start, exit_hook
#include "kernel/calls.h"  // do_execve
#include "fs/real.h"       // realfs
#include "fs/fd.h"         // adhoc_fd_create, realfs_fdops
#include "fs/devices.h"    // MEM_MAJOR, DEV_NULL_MINOR, TTY_ALTERNATE_MAJOR, ...
#include "fs/path.h"       // AT_PWD

// --- state ------------------------------------------------------------------

// The engine's `current` is thread-local, so the thread that boots must be the
// one that runs commands. Swift funnels every call through one permanent OS
// thread.
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

// --- engine log --------------------------------------------------------------
//
// The engine's own printk goes through the log handler it was built with
// (-Dlog_handler=nslog here, so it reaches the device console). This file is for
// XForge's own breadcrumbs, which is what a bug report actually needs: the boot
// stage it reached, and the output of the command that failed.

// Hard ceiling on what the log may grow to. A provisioning run that compiles or
// downloads for an hour would otherwise fill the app container.
#define XF_LOG_MAX_BYTES (4 * 1024 * 1024)

static int s_log_fd = -1;
static long long s_log_bytes = 0;
static bool s_log_capped = false;

int xf_ish_log(const char *text) {
    if (text == NULL)
        return -EINVAL;
    if (s_log_fd < 0)
        return -ENODEV;
    if (s_log_capped)
        return -EFBIG;

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
    if (written > 0) {
        s_log_bytes += written;
        if (s_log_bytes > XF_LOG_MAX_BYTES) {
            s_log_capped = true;
            static const char full[] =
                "[xforge] log reached its size limit; further lines are dropped\n";
            write(s_log_fd, full, sizeof(full) - 1);
        }
    }
    return written < 0 ? -errno : 0;
}

// printf-style breadcrumb into the log file.
static void xf_logf(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    xf_ish_log(buf);
}

int xf_ish_set_log_file(const char *path) {
    if (s_log_fd >= 0) {
        close(s_log_fd);
        s_log_fd = -1;
    }
    s_log_bytes = 0;
    s_log_capped = false;
    if (path == NULL || path[0] == '\0')
        return 0;

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return -errno;
    // Continue counting from whatever is already in the file, so the ceiling
    // holds across the session rather than per call.
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 0)
        s_log_bytes = st.st_size;
    s_log_fd = fd;
    return 0;
}

// --- command exit status -----------------------------------------------------
//
// The engine reports a process's exit through its global `exit_hook`, which is
// the only place the status of a guest process is observable from the host
// (there is no host-side waitpid for guest pids). XForge runs one command at a
// time on one thread, so the hook records the status of the pid it is waiting
// for and ignores everything else — the guest starts several tasks of its own
// during boot, and those exits must not be mistaken for the command's.
static pthread_mutex_t s_exit_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_exit_cond = PTHREAD_COND_INITIALIZER;
static pid_t_ s_wait_pid = 0;
static int s_wait_status = 0;
static bool s_wait_done = false;

static void xf_exit_hook(struct task *task, int code) {
    pthread_mutex_lock(&s_exit_lock);
    if (s_wait_pid != 0 && task != NULL && task->pid == s_wait_pid) {
        s_wait_status = code;
        s_wait_done = true;
        pthread_cond_broadcast(&s_exit_cond);
    }
    pthread_mutex_unlock(&s_exit_lock);
}

// --- guest output reader -----------------------------------------------------

#define XF_READ_CHUNK 8192

// --- API --------------------------------------------------------------------

int xf_ish_is_booted(void) {
    return s_booted ? 1 : 0;
}

// One-time process-global emulator init. Mirrors what the engine's app does
// before its first guest process: arm the memory governor, then seed the
// emulator. Kept to what a headless host needs.
static void xf_global_init(void) {
    if (s_global_inited) return;
    s_global_inited = true;
    xf_logf("engine: global init");
}

// The bundled minirootfs ships an empty /dev, and the guest userland needs the
// standard nodes before anything else runs. Mirrors the device nodes the
// engine's app creates in -[AppDelegate boot].
static void xf_ensure_devices(void) {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/dev/shm", 01777);
    generic_mkdirat(AT_PWD, "/run", 0755);

    static const struct { const char *path; mode_t_ mode; int major; int minor; } nodes[] = {
        {"/dev/null",    S_IFCHR | 0666, MEM_MAJOR,           DEV_NULL_MINOR},
        {"/dev/zero",    S_IFCHR | 0666, MEM_MAJOR,           DEV_ZERO_MINOR},
        {"/dev/full",    S_IFCHR | 0666, MEM_MAJOR,           DEV_FULL_MINOR},
        {"/dev/random",  S_IFCHR | 0666, MEM_MAJOR,           DEV_RANDOM_MINOR},
        {"/dev/urandom", S_IFCHR | 0666, MEM_MAJOR,           DEV_URANDOM_MINOR},
        {"/dev/tty",     S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx",    S_IFCHR | 0666, TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
    };
    for (size_t i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) {
        // EEXIST is expected on every boot after the first.
        generic_mknodat(AT_PWD, nodes[i].path, nodes[i].mode,
                        dev_make(nodes[i].major, nodes[i].minor));
    }

    // Linux guarantees these modes; a tarball can leave them stricter.
    generic_setattrat(AT_PWD, "/tmp", (struct attr) { .type = attr_mode, .mode = S_IFDIR | 01777 }, false);
    generic_setattrat(AT_PWD, "/",    (struct attr) { .type = attr_mode, .mode = S_IFDIR | 0755 }, false);
}

int xf_ish_boot(const char *root_dir, const char *host_dir) {
    if (root_dir == NULL) return -EINVAL;
    if (s_booted) return 0;

    xf_global_init();
    xf_logf("boot: mounting %s/data as /", root_dir);

    // The fakefs filesystem is the root's `data` directory; `meta.db` sits
    // beside it. This is the same source the engine's app passes to mount_root.
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

    // NOTE: nothing is registered here on purpose. The engine's fs/mount.c
    // already carries a static table of the filesystems it uses (realfs,
    // procfs, devptsfs, tmpfs) and MAX_FILESYSTEMS is 10. A registration path
    // that overflows it hits `assert(!"reached filesystem limit")`, which is an
    // abort() — and in an iOS app stderr goes nowhere, so that presents as the
    // app simply dying during boot with no message. Registration is only for
    // filesystems that are *not* in that table, so there is nothing to add.

    // The engine reports guest exits through this global hook; it is how
    // xf_ish_run learns a command's exit status.
    exit_hook = xf_exit_hook;

    // Creates pid 1. After this the guest has an init task, which is all the
    // headless command runner needs — XForge does not run /sbin/init, it runs
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
    xf_logf("boot: device nodes + /proc /dev/pts");
    xf_ensure_devices();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    // Share the app's own container into the guest at /host (realfs) so large
    // artifacts — the darwin Swift SDK is hundreds of megabytes — can be staged
    // by the host instead of being pushed through the command pipe. Not fatal.
    if (host_dir != NULL && host_dir[0] != '\0') {
        generic_mkdirat(AT_PWD, "/host", 0777);
        int merr = do_mount(&realfs, host_dir, "/host", "", 0);
        if (merr < 0) {
            xf_logf("boot: could not share %s at /host: %s", host_dir, strerror(-merr));
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

    const char *exec_path = (shell != NULL && shell[0] != '\0') ? shell : "/bin/sh";
    xf_logf("run: %.200s", command);

    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        xf_fail("pipe failed: %s", strerror(errno));
        return -errno;
    }

    struct task *saved_current = current;

    int err = become_new_init_child();
    if (err < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        current = saved_current;
        xf_fail("become_new_init_child failed: %s (%d)", strerror(-err), err);
        return err;
    }
    struct task *task = current;

    // stdin: /dev/null. stdout+stderr: the pipe, merged — XForge presents one
    // combined transcript, and separating them would need a second reader
    // thread for no gain here.
    struct fd *stdin_fd = adhoc_fd_create(&realfs_fdops);
    if (stdin_fd != NULL) {
        stdin_fd->real_fd = open("/dev/null", O_RDONLY);
        task->files->files[0] = stdin_fd;
    }
    for (int idx = 1; idx <= 2; idx++) {
        struct fd *out_fd = adhoc_fd_create(&realfs_fdops);
        if (out_fd != NULL) {
            out_fd->real_fd = dup(pipe_fds[1]);
            task->files->files[idx] = out_fd;
        }
    }
    close(pipe_fds[1]);

    // argv, as the NUL-separated, double-NUL-terminated block do_execve wants.
    // `-c` is what turns the command into something /bin/sh runs and reports the
    // exit status of.
    static const char *const argv0 = "sh";
    static const char *const flag = "-c";
    char *argv_buf = NULL;
    size_t argv_len = strlen(argv0) + 1 + strlen(flag) + 1 + strlen(command) + 1 + 1;
    argv_buf = calloc(1, argv_len);
    if (argv_buf == NULL) {
        close(pipe_fds[0]);
        current = saved_current;
        xf_fail("out of memory building argv");
        return -ENOMEM;
    }
    size_t pos = 0;
    memcpy(argv_buf + pos, argv0, strlen(argv0) + 1); pos += strlen(argv0) + 1;
    memcpy(argv_buf + pos, flag, strlen(flag) + 1);   pos += strlen(flag) + 1;
    memcpy(argv_buf + pos, command, strlen(command) + 1); pos += strlen(command) + 1;
    argv_buf[pos] = '\0';

    // A build environment needs a real PATH, and HOME for the toolchains.
    static const char *const envp =
        "TERM=dumb\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";

    err = do_execve(exec_path, 3, argv_buf, envp);
    if (err < 0) {
        free(argv_buf);
        close(pipe_fds[0]);
        current = saved_current;
        xf_fail("do_execve(%s) failed: %s (%d)", exec_path, strerror(-err), err);
        return err;
    }
    free(argv_buf);

    pid_t_ pid = task->pid;
    task_start(task);
    current = saved_current;

    result->launched = 1;

    // Register interest in this pid BEFORE reading, so a command that finishes
    // immediately cannot report its exit before anyone is listening.
    pthread_mutex_lock(&s_exit_lock);
    s_wait_pid = pid;
    s_wait_status = 0;
    s_wait_done = false;
    pthread_mutex_unlock(&s_exit_lock);

    // Read until the child closes the pipe (it does so when it exits), which
    // both collects the output and waits for the command. The timeout is
    // enforced with poll() so a hung guest command cannot wedge XForge.
    char *buffer = malloc(XF_READ_CHUNK * 4);
    if (buffer == NULL) {
        close(pipe_fds[0]);
        pthread_mutex_lock(&s_exit_lock);
        s_wait_pid = 0;
        pthread_mutex_unlock(&s_exit_lock);
        xf_fail("out of memory reading command output");
        return -ENOMEM;
    }
    size_t length = 0, capacity = XF_READ_CHUNK * 4;
    int truncated = 0;
    struct timeval start;
    gettimeofday(&start, NULL);
    bool pipe_eof = false;

    while (!pipe_eof) {
        if (timeout_ms > 0) {
            struct timeval now;
            gettimeofday(&now, NULL);
            long long elapsed = (long long) (now.tv_sec - start.tv_sec) * 1000
                              + (now.tv_usec - start.tv_usec) / 1000;
            if (elapsed >= timeout_ms) {
                result->timed_out = 1;
                xf_logf("run: timeout after %d ms (pid %d)", timeout_ms, (int) pid);
                break;
            }
            struct pollfd pfd = { .fd = pipe_fds[0], .events = POLLIN };
            int pr = poll(&pfd, 1, (int) (timeout_ms - elapsed));
            if (pr < 0 && errno != EINTR) {
                pipe_eof = true;
                break;
            }
            if (pr == 0) {
                result->timed_out = 1;
                xf_logf("run: timeout waiting for pid %d", (int) pid);
                break;
            }
        }
        // poll() said there is data (or the write end closed, which shows up as
        // POLLHUP). Drain what is available; EOF ends the loop.
        char chunk[XF_READ_CHUNK];
        ssize_t n = read(pipe_fds[0], chunk, sizeof(chunk));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0) {
            pipe_eof = true;
            break;
        }
        if (max_output == 0 || length < max_output) {
            size_t room = (max_output == 0 ? (size_t) n : max_output - length);
            size_t take = (size_t) n < room ? (size_t) n : room;
            if (length + take + 1 > capacity) {
                size_t want = capacity * 2;
                while (want < length + take + 1)
                    want *= 2;
                char *grown = realloc(buffer, want);
                if (grown == NULL)
                    break;
                buffer = grown;
                capacity = want;
            }
            memcpy(buffer + length, chunk, take);
            length += take;
            if (take < (size_t) n)
                truncated = 1;
        } else {
            truncated = 1;
        }
    }

    close(pipe_fds[0]);
    buffer[length] = '\0';

    // Wait for the exit status, briefly: the pipe closes when the process exits,
    // but the hook that records the status may run a moment later.
    pthread_mutex_lock(&s_exit_lock);
    if (!s_wait_done) {
        struct timeval then;
        gettimeofday(&then, NULL);
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += 5;
        while (!s_wait_done) {
            if (pthread_cond_timedwait(&s_exit_cond, &s_exit_lock, &deadline) != 0)
                break;
        }
        (void) then;
    }
    bool have_status = s_wait_done;
    int status = s_wait_status;
    s_wait_pid = 0;
    s_wait_done = false;
    pthread_mutex_unlock(&s_exit_lock);

    result->truncated = truncated;
    result->output = buffer;
    result->output_len = length;
    if (have_status) {
        result->exited = 1;
        // The guest reports a wait(2)-style status; expose the plain exit code.
        result->exit_code = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 0;
        result->term_signal = (status & 0x7f) == 0 ? 0 : (status & 0x7f);
    } else if (!result->timed_out) {
        // Output stopped but no exit was observed: the command was killed or the
        // engine never reported it. Say so rather than reporting success.
        result->exited = 1;
        result->exit_code = -1;
    }

    xf_logf("run: collected %zu bytes (truncated=%d timed_out=%d exited=%d "
            "code=%d signal=%d)",
            length, truncated, result->timed_out, result->exited,
            result->exit_code, result->term_signal);
    return 0;
}

void xf_guest_result_free(xf_guest_result *result) {
    if (result == NULL) return;
    free(result->output);
    memset(result, 0, sizeof(*result));
}

void xf_ish_shutdown(void) {
    // The engine cannot boot a second machine inside the same process, so there
    // is nothing to tear down beyond forgetting that we booted.
    s_booted = false;
}

#endif /* TARGET_OS_SIMULATOR */
