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
//
// `expect_exit` is the exit status the guest should end with -- 0 for the
// normal cases, 127 for the probes of programs a bare rootfs does not have yet,
// 7 for the deliberate failure below. The struct is read *before* it is freed:
// xf_guest_result_free() zeroes it, which is a mistake this harness made once
// and reported as every command failing.
static void run_guest(const char *label, const char *command, int timeout_ms, int expect_exit) {
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

    int ok = r.launched && r.exited && r.term_signal == 0 && r.exit_code == expect_exit;
    if (!ok)
        say("[smoke]      expected exit %d", expect_exit);
    xf_guest_result_free(&r);
    result(label, ok);
}

// The host's own DNS servers, the way the app gets them from iOS and writes
// them into the guest's /etc/resolv.conf (App/Services/GuestNetwork.swift).
// Without that file the guest cannot resolve anything: the bundled minirootfs
// ships no nameservers, and resolution happens inside the guest.
static int host_dns_servers(char *out, size_t cap) {
    FILE *f = popen("scutil --dns 2>/dev/null | awk '/nameserver\\[[0-9]+\\]/{print $3}' | "
                    "sort -u | head -2", "r");
    if (f == NULL)
        return 0;
    size_t used = 0;
    char line[256];
    out[0] = '\0';
    while (fgets(line, sizeof(line), f) != NULL && used + sizeof("nameserver ") + 64 < cap) {
        char *nl = strchr(line, '\n');
        if (nl != NULL) *nl = '\0';
        if (line[0] == '\0') continue;
        int n = snprintf(out + used, cap - used, "nameserver %s; ", line);
        if (n <= 0) break;
        used += (size_t) n;
    }
    pclose(f);
    return (int) used;
}

// Run a command and print everything about it, but do not judge it: used for
// probes whose failure is a fact about the environment (network reachability,
// package repositories) rather than a regression in the bridge.
static void probe_guest(const char *label, const char *command, int timeout_ms) {
    step(label);
    struct xf_guest_result r;
    int rc = xf_ish_run(command, NULL, timeout_ms, 1 << 20, &r);
    if (rc != 0) {
        say("[smoke] probe could not start (%d): %s", rc, xf_ish_last_error());
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
    // The probes ToolchainManager.guestHas() runs, then the kind of work the
    // install paths do. `swift`/`xtool` are *meant* to be missing here: this is
    // a bare Alpine minirootfs, before any provisioning.
    run_guest("uname", "uname -a", 120000, 0);
    run_guest("alpine-release", "cat /etc/alpine-release; command -v sh; echo home=$HOME path=$PATH", 120000, 0);
    run_guest("probe: swift (absent in a bare rootfs)", "command -v swift >/dev/null 2>&1", 120000, 127);
    run_guest("probe: xtool (absent in a bare rootfs)", "command -v xtool >/dev/null 2>&1", 120000, 127);
    run_guest("a failing command reports its status", "echo one; echo two >&2; exit 7", 120000, 7);

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
    run_guest("read it from the guest at /host", "cat /host/share-probe.txt", 120000, 0);
    run_guest("guest can write into /host", "echo from-guest > /host/written-by-guest.txt && cat /host/written-by-guest.txt", 120000, 0);
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
    run_guest("a slower command (shell loop)", "i=0; while [ $i -lt 200 ]; do i=$((i+1)); done; echo counted=$i", 120000, 0);

    // --- 6. what provisioning will need --------------------------------
    // Installing the Swift toolchain runs `apk add` and then downloads a
    // several-hundred-megabyte tarball *inside* the guest, so the guest needs
    // the host's network. These are probes, not assertions: a failure here is
    // a fact about the environment, and it is far better to see it here than
    // as a silent spinner on a phone.
    step("write the guest's /etc/resolv.conf from the host's DNS");
    {
        char servers[512] = {0};
        host_dns_servers(servers, sizeof servers);
        if (servers[0] == '\0') {
            say("[smoke] host published no DNS servers; leaving the guest alone");
        } else {
            char cmd[1024];
            snprintf(cmd, sizeof cmd,
                     "rm -f /etc/resolv.conf; printf '%s' > /etc/resolv.conf; cat /etc/resolv.conf",
                     servers);
            struct xf_guest_result r;
            int rc = xf_ish_run(cmd, NULL, 60000, 1 << 16, &r);
            if (rc != 0) {
                say("[smoke] could not write resolv.conf: %s", xf_ish_last_error());
            } else {
                say("[smoke] guest resolv.conf now: %s", r.output != NULL ? r.output : "");
            }
            xf_guest_result_free(&r);
        }
    }

    probe_guest("network: DNS + HTTP from the guest",
                "wget -q -T 30 -O /dev/null http://dl-cdn.alpinelinux.org/alpine/ && echo net-ok", 180000);
    probe_guest("network: apk update (the first thing provisioning runs)",
                "apk update 2>&1 | tail -3", 300000);

    step("shut down");
    xf_ish_shutdown();
    result("shut down", 1);

    say("[smoke] === %s (%d failed step%s) ===",
        failures == 0 ? "PASSED" : "FAILED", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
