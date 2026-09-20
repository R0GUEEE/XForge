// swift-mutex-probe.swift — run *inside* the XForge guest: does a Swift 6
// Synchronization.Mutex work, under real concurrency?
//
// This is the exact shape of the failure the app hit:
//
//     Synchronization/LinuxImpl.swift:194: Fatal error:
//     Unknown error occurred while attempting to acquire a Mutex
//     ... Trace/breakpoint trap        (exit 133)
//
// Swift's Mutex is built on FUTEX_LOCK_PI, and the engine answered ENOSYS for
// it, so any Swift binary doing concurrent work died on its first Mutex —
// xtool's `xtool sdk build`, which drives libdispatch worker threads, was the
// one that surfaced it. `DispatchQueue.concurrentPerform` reproduces the same
// thread pattern without needing xtool's download, so this is the fast check
// that the engine fix actually reaches Swift.
//
// Built and run by Tools/engine-smoke/engine-smoke.c in the guest.

import Dispatch
import Synchronization

let counter = Mutex(0)
let iterations = 64 * 1000
let workers = 8

DispatchQueue.concurrentPerform(iterations: workers) { _ in
    for _ in 0..<(iterations / workers) {
        counter.withLock { $0 += 1 }
    }
}

let total = counter.withLock { $0 }
if total == iterations {
    print("swift-mutex-ok \(total)")
} else {
    print("swift-mutex-wrong \(total) of \(iterations)")
}
