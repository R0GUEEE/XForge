/*
 * futex-pi-probe.c — run *inside* the XForge guest: do PI futexes work?
 *
 * Swift 6's Synchronization.Mutex is built on FUTEX_LOCK_PI, and the engine
 * used to answer ENOSYS for it. Swift's Linux implementation turns an
 * unexpected futex errno into
 *
 *     Synchronization/LinuxImpl.swift:194: Fatal error:
 *     Unknown error occurred while attempting to acquire a Mutex
 *
 * which is a trap (exit 133, "Trace/breakpoint trap"), so any Swift binary
 * doing concurrent work — xtool, libdispatch's DispatchWorker threads — died on
 * its very first Mutex while single-threaded commands kept working.
 *
 * This checks the syscall directly (fast, deterministic) and then through the
 * C library's own PI mutexes, including under contention with real threads,
 * which is the part a wrong implementation would deadlock or double-take on.
 *
 * Built and run by Tools/engine-smoke/engine-smoke.c in the guest.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__has_include)
#  if __has_include(<linux/futex.h>)
#    include <linux/futex.h>
#  endif
#endif
#ifndef FUTEX_LOCK_PI
#define FUTEX_LOCK_PI   6
#define FUTEX_UNLOCK_PI 7
#define FUTEX_TRYLOCK_PI 8
#endif
#ifndef FUTEX_PRIVATE_FLAG
#define FUTEX_PRIVATE_FLAG 128
#endif

static int failures;

static void check(const char *what, int ok, const char *detail) {
    printf("  %-46s %s%s%s\n", what, ok ? "ok" : "FAIL",
           detail != NULL && detail[0] != '\0' ? " — " : "",
           detail != NULL ? detail : "");
    fflush(stdout);
    if (!ok)
        failures++;
}

/* A guest thread blocked on a lock that never comes free would otherwise burn
 * the harness's whole timeout with no output; this turns that into a result.
 * The correct probe finishes in well under a second of guest time (the emulator
 * makes it seconds, not minutes). */
static void watchdog(int sig) {
    (void) sig;
    printf("PI-FUTEX TIMED OUT — a lock or a wait never returned\n");
    fflush(stdout);
    _exit(2);
}

/* FUTEX_LOCK_PI/FUTEX_UNLOCK_PI take the value argument as unused, so this
 * passes 0 like glibc does; errno is the useful result. */
static int pi_op(int *word, int op) {
    return (int) syscall(SYS_futex, word, op | FUTEX_PRIVATE_FLAG, 0, NULL, NULL, 0);
}

/* Deliberately small: these ops are microseconds natively but the guest is an
 * emulated aarch64, and the point is whether lock/unlock/wake work under
 * contention at all — not throughput. 4 x 250 contended pairs is ample. */
#define THREADS 4
#define ROUNDS 250

static int counter;                       /* guarded by the raw PI word */

static void *raw_worker(void *arg) {
    (void) arg;
    for (int i = 0; i < ROUNDS; i++) {
        while (pi_op(&counter, FUTEX_LOCK_PI) != 0) {
            if (errno != EAGAIN && errno != EINTR) {
                printf("  raw FUTEX_LOCK_PI failed: %s\n", strerror(errno));
                return NULL;
            }
        }
        /* The word must name us while we hold it. */
        if (counter != (int) gettid()) {
            printf("  owner tid wrong while held: %d != %d\n", counter, (int) gettid());
            return NULL;
        }
        /* The word must NOT be written here: for a PI futex the kernel owns it,
         * and FUTEX_UNLOCK_PI is what clears it and wakes a waiter. Zeroing it
         * first made the unlock an EPERM no-op, so no wake was ever issued and
         * the waiters slept for good — which is how this probe first timed out. */
        pi_op(&counter, FUTEX_UNLOCK_PI);
    }
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGALRM, watchdog);
    alarm(120);
    printf("futex-pi-probe: tid=%d\n", (int) gettid());

    /* 1. The syscall on its own: free word, lock, unlock, and the owner check. */
    int word = 0;
    int rc = pi_op(&word, FUTEX_LOCK_PI);
    check("FUTEX_LOCK_PI on a free word", rc == 0, rc == 0 ? "" : strerror(errno));
    check("the word records the owner", word == (int) gettid(), "");

    rc = pi_op(&word, FUTEX_TRYLOCK_PI);
    check("FUTEX_TRYLOCK_PI on our own lock is EDEADLK",
          rc == -1 && errno == EDEADLK, rc == -1 ? strerror(errno) : "succeeded");

    rc = pi_op(&word, FUTEX_UNLOCK_PI);
    check("FUTEX_UNLOCK_PI by the owner", rc == 0 && word == 0,
          rc == 0 ? "" : strerror(errno));

    errno = 0;
    rc = pi_op(&word, FUTEX_UNLOCK_PI);
    check("FUTEX_UNLOCK_PI by a non-owner is EPERM",
          rc == -1 && errno == EPERM, rc == -1 ? strerror(errno) : "succeeded");

    /* 2. Contended: take the lock in one thread, TRYLOCK_PI from another. */
    {
        word = 0;
        pi_op(&word, FUTEX_LOCK_PI);
        pid_t child = fork();
        if (child == 0) {
            errno = 0;
            int r = pi_op(&word, FUTEX_TRYLOCK_PI);
            _exit((r == -1 && errno == EAGAIN) ? 0 : 1);
        }
        int status = 0;
        waitpid(child, &status, 0);
        check("FUTEX_TRYLOCK_PI from another task is EAGAIN",
              WIFEXITED(status) && WEXITSTATUS(status) == 0, "");
        pi_op(&word, FUTEX_UNLOCK_PI);
    }

    /* 3. Real threads through the raw syscall, one word, contended. */
    {
        counter = 0;
        pthread_t t[THREADS];
        for (int i = 0; i < THREADS; i++)
            pthread_create(&t[i], NULL, raw_worker, NULL);
        for (int i = 0; i < THREADS; i++)
            pthread_join(t[i], NULL);
        check("raw PI futex, 4 threads x 250 contended lock/unlock",
              counter == 0, "no corruption, no deadlock");
    }

    /* The C library's own PTHREAD_PRIO_INHERIT mutexes are deliberately NOT
     * tested here. musl drives those through a different pattern — an absolute
     * deadline passed as FUTEX_LOCK_PI's timeout, a userspace CAS of the word
     * before a plain FUTEX_WAKE on unlock — and that path hung in the emulated
     * guest, which says something about musl's PI mutexes in this environment
     * rather than about the PI futexes Swift uses. Swift 6's Synchronization.Mutex
     * calls FUTEX_LOCK_PI/FUTEX_UNLOCK_PI directly, which is what the tests above
     * cover, so that is what this probe asserts. */

    alarm(0);
    if (failures == 0)
        printf("PI-FUTEX OK\n");
    else
        printf("PI-FUTEX FAILED (%d)\n", failures);
    return failures == 0 ? 0 : 1;
}
