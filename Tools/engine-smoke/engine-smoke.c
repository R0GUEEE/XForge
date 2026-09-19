//
//  engine-smoke.c
//  XForge
//
//  Host harness for the embedded Linux bridge.
//
//  The app's install paths (the bundled Alpine rootfs, and every guest-side
//  tool) all funnel through the same three bridge calls: import a rootfs into
//  iSH-AOK's fakefs, boot the guest, run a command. When that goes wrong on a
//  device the only symptom is "the app crashed", and the device cannot be
//  attached to a debugger from here — so this harness drives *the same*
//  ISHAOKBridge.c, in *the same* order, on a real machine where the failure is
//  visible.
//
//  Build: see .github/workflows/engine-smoke.yml (adds an `engine_smoke`
//  target to iSH-AOK's meson build, so the bridge is compiled with exactly the
//  engine's own flags and guest-arch defines).
//
//  Usage: engine-smoke <rootfs.tar.xz> [workdir]
//
//  Every step prints a flushed breadcrumb *before* it runs, so a crash leaves
//  the last step it reached on stdout with nothing after it.
//
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "ISHAOKBridge.h"

static int failures = 0;

static void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

// Announce a step before running it: if the process dies inside the step, the
// breadcrumb is already on the wire and nothing follows it.
static void step(const char *what) {
    say("[smoke] >>> %s", what);
}

static void result(const char *what, int ok) {
    say("[smoke] %s %s", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static int rm_rf(const char *path) {
    char cmd[4096];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", path);
    return system(cmd);
}

static int mkdirs(const char *path) {
    return mkdir(path, 0777);
}

// One guest command, with its outcome printed in full.
static void run_guest(const char *label, const char *command, int timeout_ms) {
    step(label);
    struct xf_guest_result r;
    int rc = xf_ish_run(command, NULL, timeout_ms, 1 << 20, &r);
    if (rc != 0) {
        say("[smoke] FAIL %s: could not start (%d): %s", label, rc, xf_ish_last_error());
        failures++;
        return;
    }
    say("[smoke] --- %s ---", label);
    say("launched=%d exited=%d exit_code=%d signal=%d timed_out=%d truncated=%d bytes=%zu",
        r.launched, r.exited, r.exit_code, r.term_signal, r.timed_out, r.truncated, r.output_len);
    if (r.output != NULL && r.output[0] != '\0') {
        fputs(r.output, stdout);
        if (r.output[r.output_len > 0 ? r.output_len - 1 : 0] != '\n')
            fputc('\n', stdout);
    }
    fflush(stdout);
    xf_guest_result_free(&r);

    int ok = r.exit_code == 0 && r.exited;
    result(label, ok);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: engine-smoke <rootfs.tar.xz> [workdir]\n");
        return 2;
    }
    const char *archive = argv[1];
    const char *work = argc > 2 ? argv[2] : "/tmp/xforge-smoke";

    char root[4096], host[4096];
    snprintf(root, sizeof root, "%s/root", work);
    snprintf(host, sizeof host, "%s/host", work);

    say("[smoke] === XForge engine smoke test ===");
    say("[smoke] archive : %s", archive);
    say("[smoke] rootfs  : %s", root);
    say("[smoke] hostdir : %s", host);

    if (access(archive, R_OK) != 0) {
        say("[smoke] FAIL archive is not readable: %s", strerror(errno));
        return 2;
    }

    step("prepare work directory");
    rm_rf(work);
    if (mkdirs(work) != 0 || mkdirs(host) != 0) {
        say("[smoke] FAIL mkdir %s: %s", work, strerror(errno));
        return 1;
    }
    result("prepare work directory", 1);

    // --- 1. import ---------------------------------------------------------
    // This is exactly what ToolchainManager.install(.rootfs) does through
    // RootfsInstaller.installIfNeeded().
    step("import the bundled rootfs (fakefs_import)");
    int rc = xf_ish_import_rootfs(archive, root);
    {
        const char *err = xf_ish_last_error();
        say("[smoke] import returned %d%s%s", rc,
            (err != NULL && err[0] != '\0') ? " : " : "",
            (err != NULL && err[0] != '\0') ? err : "");
    }
    if (rc != 0) {
        result("import the bundled rootfs", 0);
        say("[smoke] === stopped: the import failed, so boot was never attempted ===");
        return 1;
    }
    result("import the bundled rootfs", 1);

    // --- 2. boot -----------------------------------------------------------
    step("boot the guest (mount_root + become_first_process)");
    rc = xf_ish_boot(root, host);
    {
        const char *err = xf_ish_last_error();
        say("[smoke] boot returned %d%s%s", rc,
            (err != NULL && err[0] != '\0') ? " : " : "",
            (err != NULL && err[0] != '\0') ? err : "");
    }
    if (rc != 0) {
        result("boot the guest", 0);
        say("[smoke] === stopped: the guest did not boot ===");
        return 1;
    }
    result("boot the guest", 1);

    // --- 3. run commands ---------------------------------------------------
    // The three probes ToolchainManager.guestHas() runs, then the kind of work
    // the install paths do.
    run_guest("uname", "uname -a", 120000);
    run_guest("alpine-release", "cat /etc/alpine-release; command -v sh; echo home=$HOME path=$PATH", 120000);
    run_guest("probe: swift", "command -v swift >/dev/null 2>&1", 120000);
    run_guest("probe: xtool", "command -v xtool >/dev/null 2>&1", 120000);
    run_guest("multi-command shell", "echo one; echo two >&2; exit 7", 120000);

    // --- 4. the /host share ------------------------------------------------
    // The SDK install stages hundreds of MB here and installs from it, so a
    // share that does not actually reach the guest breaks every install.
    step("write a file into the host share");
    {
        char path[4096];
        snprintf(path, sizeof path, "%s/share-probe.txt", host);
        FILE *f = fopen(path, "w");
        if (f == NULL) {
            say("[smoke] FAIL could not write %s: %s", path, strerror(errno));
            failures++;
        } else {
            fputs("host-share-ok\n", f);
            fclose(f);
        }
    }
    result("write a file into the host share", 1);
    run_guest("read it from the guest at /host", "cat /host/share-probe.txt", 120000);
    run_guest("guest can write into /host", "echo from-guest > /host/written-by-guest.txt && cat /host/written-by-guest.txt", 120000);
    step("read the guest's file back on the host");
    {
        char path[4096];
        snprintf(path, sizeof path, "%s/written-by-guest.txt", host);
        FILE *f = fopen(path, "r");
        char buf[256] = {0};
        int ok = f != NULL && fgets(buf, sizeof buf, f) != NULL
                 && strncmp(buf, "from-guest", 10) == 0;
        if (f != NULL) fclose(f);
        say("[smoke] host sees: %s", ok ? buf : "(missing)");
        result("host share is bidirectional", ok);
    }

    // --- 5. a long-running command, as a build would be --------------------
    run_guest("a slower command (shell loop)", "i=0; while [ $i -lt 200 ]; do i=$((i+1)); done; echo counted=$i", 120000);

    step("shut down");
    xf_ish_shutdown();
    result("shut down", 1);

    say("[smoke] === %s (%d failed step%s) ===",
        failures == 0 ? "PASSED" : "FAILED", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
