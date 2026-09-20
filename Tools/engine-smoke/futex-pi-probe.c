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
    if (!ok)
        failures++;
}

/* FUTEX_LOCK_PI/FUTEX_UNLOCK_PI take the value argument as unused, so this
 * passes 0 like glibc does; errno is the useful result. */
static int pi_op(int *word, int op) {
    return (int) syscall(SYS_futex, word, op | FUTEX_PRIVATE_FLAG, 0, NULL, NULL, 0);
}

#define THREADS 4
#define ROUNDS 20000

static int counter;                       /* guarded by the raw PI word */
static pthread_mutex_t pi_mutex;          /* PTHREAD_PRIO_INHERIT */
static int pi_counter;

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
            pi_op(&counter, FUTEX_UNLOCK_PI);
            return NULL;
        }
        counter = 0;
        pi_op(&counter, FUTEX_UNLOCK_PI);
    }
    return NULL;
}

static void *pi_mutex_worker(void *arg) {
    (void) arg;
    for (int i = 0; i < ROUNDS; i++) {
        pthread_mutex_lock(&pi_mutex);
        pi_counter++;
        pthread_mutex_unlock(&pi_mutex);
    }
    return NULL;
}

int main(void) {
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
        check("raw PI futex, 4 threads x 20000 lock/unlock",
              counter == 0, "no corruption, no deadlock");
    }

    /* 4. …and through the C library's PI mutexes, which is what a Swift or
     *    glibc-linked binary actually uses. */
    {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);
        if (pthread_mutex_init(&pi_mutex, &attr) != 0) {
            check("pthread PI mutex init", 0, strerror(errno));
        } else {
            pthread_t t[THREADS];
            for (int i = 0; i < THREADS; i++)
                pthread_create(&t[i], NULL, pi_mutex_worker, NULL);
            for (int i = 0; i < THREADS; i++)
                pthread_join(t[i], NULL);
            check("pthread PI mutex, 4 threads x 20000 lock/unlock",
                  pi_counter == THREADS * ROUNDS, "");
        }
    }

    if (failures == 0)
        printf("PI-FUTEX OK\n");
    else
        printf("PI-FUTEX FAILED (%d)\n", failures);
    return failures == 0 ? 0 : 1;
}
