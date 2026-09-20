#!/usr/bin/env python3
"""Implement PI futexes in the vendored iSH-AOK kernel (kernel/futex.c).

Why
---
Swift 6's `Synchronization.Mutex` is built on FUTEX_LOCK_PI. iSH-AOK answered
ENOSYS for every PI futex op, and Swift's Linux implementation turns an
unexpected futex errno into

    Synchronization/LinuxImpl.swift:194: Fatal error:
    Unknown error occurred while attempting to acquire a Mutex

which is a trap: the guest reports exit 133, "Trace/breakpoint trap". Any Swift
binary doing concurrent work (xtool, libdispatch's DispatchWorker threads) died
on its first Mutex, while single-threaded commands such as `swift --version` kept
working — which is what made it look like flakiness rather than a missing syscall.

The engine is a pinned submodule, so the change is applied at build time instead
of being committed into it: EmbeddedLinux/build-ish-aok-core.sh and the
engine-smoke workflow both run this script against the checkout.

It edits by exact anchor, so if upstream moves or rewrites the code being
replaced this fails loudly instead of producing a subtly wrong kernel, and it is
idempotent — running it twice is a no-op.

Usage:  EmbeddedLinux/patches/0001-futex-pi.py [ish-AOK-checkout]   (default Vendor/ish-AOK)
"""
import pathlib
import sys

HELPERS = '''// ---------------------------------------------------------------------------
// PI futexes
//
// FUTEX_LOCK_PI / FUTEX_TRYLOCK_PI / FUTEX_UNLOCK_PI. The word holds the owning
// task's TID and is 0 when free. A real kernel also tracks the owner so it can
// lend a waiter's priority to it; under an emulator there is no guest-visible
// priority to inherit, so the word plus the existing wait queue is the whole
// contract: take the word if it is free, otherwise sleep on the futex until the
// unlock path wakes us, then try again.
//
// Worth having, because Swift 6's Synchronization.Mutex is built on
// FUTEX_LOCK_PI: while these ops returned ENOSYS, Synchronization/LinuxImpl.swift
// turned the unexpected errno into
//     fatalError("Unknown error occurred while attempting to acquire a Mutex")
// -- a SIGTRAP, which the guest reports as exit 133 "Trace/breakpoint trap".
// Every Swift binary doing concurrent work (xtool, libdispatch's DispatchWorker
// threads) died on its first Mutex, while single-threaded commands such as
// `swift --version` kept working, which is what made it look like a flake.
//
// Owner checks follow Linux: LOCK_PI from the task that already owns the word is
// EDEADLK (a guest re-locking its own mutex has a bug, and Linux says so rather
// than deadlocking it), and UNLOCK_PI from a task that does not own it is EPERM.
static int futex_pi_take(guest_addr_t uaddr, pid_t *owner) {
    mem_read_lock_quiesce_aware(current->mem);
    _Atomic int32_t *word = (_Atomic int32_t *) mem_ptr(current->mem, uaddr, MEM_WRITE);
    int err = 0;
    if (word == NULL) {
        err = _EFAULT;
    } else {
        int32_t held = atomic_load_explicit(word, memory_order_acquire);
        *owner = (pid_t) held;
        if (held == 0) {
            // Interlocked with the guest's own atomic instructions the same way
            // futex_wake_op's read-modify-write is (see its comment): on this
            // arch an aligned guest atomic is a host atomic on the same word.
            int32_t expected = 0;
            if (atomic_compare_exchange_strong_explicit(word, &expected,
                    (int32_t) current->pid, memory_order_acq_rel, memory_order_relaxed))
                err = 0;
            else {
                *owner = (pid_t) expected;
                err = (pid_t) expected == current->pid ? _EDEADLK : _EAGAIN;
            }
        } else {
            err = (pid_t) held == current->pid ? _EDEADLK : _EAGAIN;
        }
    }
    mem_read_unlock_quiesce_aware(current->mem);
    return err;
}

static int futex_pi_release(guest_addr_t uaddr) {
    mem_read_lock_quiesce_aware(current->mem);
    _Atomic int32_t *word = (_Atomic int32_t *) mem_ptr(current->mem, uaddr, MEM_WRITE);
    int err = 0;
    if (word == NULL)
        err = _EFAULT;
    else if ((pid_t) atomic_load_explicit(word, memory_order_acquire) != current->pid)
        err = _EPERM;
    else
        atomic_store_explicit(word, 0, memory_order_release);
    mem_read_unlock_quiesce_aware(current->mem);
    return err;
}

// Acquire the word, sleeping while somebody else holds it. `try_only` is
// FUTEX_TRYLOCK_PI: never sleeps, and reports a held lock as EAGAIN.
static int futex_lock_pi(guest_addr_t uaddr, dword_t op, bool try_only, struct timespec *timeout) {
    for (;;) {
        struct futex *futex = futex_get(uaddr, op);
        if (futex == NULL)
            return _ENOMEM;
        pid_t owner = 0;
        int err = futex_pi_take(uaddr, &owner);
        futex_put(futex);
        if (err == 0)
            return 0;
        if (err != _EAGAIN)
            return err;
        if (try_only)
            return _EAGAIN;
        // Contended: sleep while the word still names `owner`. FUTEX_WAIT
        // re-checks the value under the futex lock before parking, so a release
        // that lands between the take above and this call is an immediate EAGAIN
        // rather than a lost wakeup.
        err = futex_wait_masked(uaddr, op, (dword_t) owner, timeout, ~0u);
        if (err == _ETIMEDOUT)
            return err;
        if (err == _EINTR) {
            // A signal interrupted the wait. FUTEX_WAIT parks the futex so that
            // a re-executed syscall (SA_RESTART) can resume the same wait; this
            // op is re-entered in kernel context instead, so the park has to be
            // dropped before reporting EINTR -- and a restartable interrupt has
            // to look like one, or a caller with SA_RESTART would see an errno
            // Linux would never have given it. Swift's Mutex accepts EINTR and
            // re-locks, so an ordinary delivery is fine to surface.
            if (signal_should_restart_syscall())
                return _ERESTART;
            futex_release_restart_park();
            return _EINTR;
        }
        if (err != 0 && err != _EAGAIN)
            return err;
        // Woken, or the word moved under us: try to take it again.
    }
}

static int futex_unlock_pi(guest_addr_t uaddr, dword_t op) {
    struct futex *futex = futex_get(uaddr, op);
    if (futex == NULL)
        return _ENOMEM;
    int err = futex_pi_release(uaddr);
    futex_put(futex);
    if (err != 0)
        return err;
    // One waiter takes the word; any others wake up, fail the take and go back
    // to sleep on the new owner.
    futex_wake(uaddr, 1);
    return 0;
}

'''

TIMEOUT_OLD = """    if (((op & FUTEX_CMD_MASK_) == FUTEX_WAIT_ || (op & FUTEX_CMD_MASK_) == FUTEX_WAIT_BITSET_) && timeout_or_val2) {"""
TIMEOUT_NEW = """    // FUTEX_LOCK_PI's fourth argument is a relative timeout too, so it has to
    // be read here or a blocked PI lock could never time out.
    if (((op & FUTEX_CMD_MASK_) == FUTEX_WAIT_ ||
         (op & FUTEX_CMD_MASK_) == FUTEX_WAIT_BITSET_ ||
         (op & FUTEX_CMD_MASK_) == FUTEX_LOCK_PI_) && timeout_or_val2) {"""

CASES_OLD = """        case FUTEX_LOCK_PI_:
            STRACE("Unimplemented futex(FUTEX_LOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            FIXME("Unsupported futex FUTEX_LOCK_PI(%#x, %d, %d, timeout=%#x, %#x, %d) (FUTEX_LOCK_PI) from %s[%d]", uaddr, op, val, timeout_or_val2, uaddr2, val3, current->comm, current->pid);
            return _ENOSYS;
        case FUTEX_UNLOCK_PI_:
            STRACE("Unimplemented futex(FUTEX_UNLOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            FIXME("Unsupported futex FUTEX_UNLOCK_PI(%#x, %d, %d, timeout=%#x, %#x, %d) (FUTEX_UNLOCK_PI) from %s[%d]", uaddr, op, val, timeout_or_val2, uaddr2, val3, current->comm, current->pid);
            return _ENOSYS;
        case FUTEX_TRYLOCK_PI_:
            STRACE("Unimplemented futex(FUTEX_TRYLOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            FIXME("Unsupported futex FUTEX_TRYLOCK_PI(%#x, %d, %d, timeout=%#x, %#x, %d) (FUTEX_TRYLOCK_PI) from %s[%d]", uaddr, op, val, timeout_or_val2, uaddr2, val3, current->comm, current->pid);
            return _ENOSYS;"""

CASES_NEW = """        case FUTEX_LOCK_PI_:
            STRACE("futex(FUTEX_LOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            return futex_lock_pi(uaddr, op, false, timeout_or_val2 ? &timeout : NULL);
        case FUTEX_UNLOCK_PI_:
            STRACE("futex(FUTEX_UNLOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            return futex_unlock_pi(uaddr, op);
        case FUTEX_TRYLOCK_PI_:
            STRACE("futex(FUTEX_TRYLOCK_PI, %#x, %d, %#x)", uaddr, val, uaddr2);
            return futex_lock_pi(uaddr, op, true, NULL);"""

ANCHOR = "dword_t sys_futex_common(guest_addr_t uaddr, dword_t op, dword_t val, guest_addr_t timeout_or_val2,"


def main() -> int:
    base = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Vendor/ish-AOK")
    path = base / "kernel" / "futex.c"
    if not path.is_file():
        print(f"error: {path} not found — is the submodule checked out?", file=sys.stderr)
        return 1

    text = path.read_text()
    if "futex_lock_pi(" in text:
        print(f"{path}: PI futexes already implemented, nothing to do")
        return 0

    for name, needle in (("timeout parsing", TIMEOUT_OLD), ("PI futex ops", CASES_OLD), ("syscall", ANCHOR)):
        if text.count(needle) != 1:
            print(f"error: expected exactly one {name} anchor in {path}, found {text.count(needle)}.\n"
                  f"       upstream changed this code; update EmbeddedLinux/patches/0001-futex-pi.py",
                  file=sys.stderr)
            return 1

    text = text.replace(TIMEOUT_OLD, TIMEOUT_NEW, 1)
    text = text.replace(CASES_OLD, CASES_NEW, 1)
    text = text.replace(ANCHOR, HELPERS + ANCHOR, 1)
    path.write_text(text)
    print(f"{path}: PI futexes implemented (LOCK_PI, TRYLOCK_PI, UNLOCK_PI)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
