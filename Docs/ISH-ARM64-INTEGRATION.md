# Embedding ish-arm64: what the reference requires, and where XForge stands

XForge's embedded Linux is **ish-arm64** (`Vendor/ish-arm64`, a git submodule of
[OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64)) running a **plain
Alpine aarch64 rootfs** that is shipped as an already-converted **fakefs ZIP**.

The reference for that integration is OpenMinis's own app — the engine's author —
and its guide `deps/ISH_INTEGRATION.md` ("iSH-ARM64 iOS 集成指南"), plus the two
scripts that build the engine (`deps/build_ish.sh`) and the root
(`deps/prepare_alpine_rootfs.sh`). This document records what the guide requires,
what XForge does instead, and *why* where the two differ. It exists because the
differences are the interesting part: several of them are deliberate, and the ones
that are not were bugs.

## The guide's checklist, item by item

| The guide says | XForge | Where |
|---|---|---|
| Link `deps/libs/libish.a`, `libish_emu.a`, `libfakefs.a` | linked, plus `libfakefsify.a` and `libarchive.a` | `project.yml` (`OTHER_LDFLAGS[sdk=iphoneos*]`) |
| Add system library `libsqlite3.tbd` | `-lsqlite3` | same |
| Header search path `deps/include` | `$(ISH_ROOT)` and `$(ISH_ROOT)/deps/libarchive/libarchive` | `project.yml` (`HEADER_SEARCH_PATHS[sdk=iphoneos*]`) |
| Other linker flags `-ObjC`, `-all_load` | **not used** — see below | — |
| Other C flags `-DISH_INTERNAL` | **not used** — see below | — |
| Bundle `alpine-rootfs.zip` | bundled, and CI asserts the app contains exactly one rootfs | `.github/workflows/build-ipa.yml`, "Verify the built app" |
| Bundle `libvdso.so.elf` (*optional* per the guide) | not bundled: it is compiled and linked **into `libish.a`** | `EmbeddedLinux/build-ish-core.sh` |
| Unzip the root to `Documents/alpine-rootfs`, mount `<root>/data` | same layout, unpacked into a staging directory and moved into place | `App/EmbeddedVM/RootfsInstaller.swift` |
| `mount_root(&fakefs, <path>/data)` then `become_first_process()` | same order, then device nodes, `/proc`, `/dev/pts` | `App/EmbeddedVM/ISHBridge.c` (`xf_ish_boot`) |
| `current->thread = pthread_self()` after `become_first_process()` | not needed: every guest task is started with `task_start()`, which sets `task->thread` via `pthread_create` (`kernel/task.c:243`) | `ISHBridge.c` (`xf_ish_start_init`, `xf_spawn_child`) |
| Register a custom tty driver: `DEFINE_TTY_DRIVER(..., TTY_CONSOLE_MAJOR, 8)` with `init`/`write`/`cleanup` | same driver on the same major, plus `/dev/tty1` and `set_console_device(4,1)` | `ISHBridge.c` (`xf_console_driver`) |
| Feed keystrokes with `tty_get()` + `tty_input()` + `tty_release()` | equivalent: the tty is recorded in the driver's `init` and typed into with `tty_input` (which reads no per-thread engine state) | `ISHBridge.c` (`xf_ish_console_write`, `xf_ish_console_*`) |
| `do_execve` + `task_start(current)` to run the console program | same, for pid 1 **and** for every command the app runs | `ISHBridge.c` |
| Build options (`build_ish.sh`): `--buildtype=release`, `-Db_ndebug=true`, `-Dlog=""`, `-Dlog_handler=nslog`, `-Dkernel=ish`, `-Dengine=asbestos`, `-Dguest_arch=arm64` | identical set | `EmbeddedLinux/build-ish-core.sh` |

### Why not `-ObjC -all_load`

The guide asks for both, and the reason is a static-library one: a linker drops any
object file nothing references, and Objective-C categories (and code reachable only
through the ObjC runtime or a constructor) can be dropped with it. Neither applies
here:

* XForge's engine libraries are **C** — there is no category to preserve — and the
  bridge references every subsystem it needs directly, so a wrongly-dropped object
  would be a *link error* rather than silent misbehaviour.
* The objects that *do* rely on a constructor (`fs/fake.c`'s `init_fake_fdops`,
  `kernel/memory.c`'s `get_real_page_size`, `kernel/task.c`'s `create_attr`) are all
  in objects that are already pulled in by symbols the app calls (`fakefs`,
  `mount_root`, `task_start`). The engine's own authors avoid constructors precisely
  where that is not true — see the comment in `kernel/native_offload_sym.c:111`
  ("not via a constructor, which a static-library linker dead-strips when the TU is
  otherwise unreferenced").
* `-all_load` would then force the whole of `libish.a` and `libarchive.a` into the
  app, for no reachability benefit.

### Why not `-DISH_INTERNAL`

The guide needs it because its `ISHKernel.m` includes `ish/fs/fake.h`, which refuses
to compile otherwise:

```c
#ifndef ISH_INTERNAL
#error "for internal use only"
#endif
```

`fs/fake.h` is the *only* header with that gate. XForge's bridge needs the fakefs
instance, and that is declared in a header that is not gated
(`kernel/fs.h:184: extern const struct fs_ops fakefs;`), which the bridge already
includes. If it ever needs `fs/fake.h` (the bind-mount API there, for instance),
`-DISH_INTERNAL` has to be added to `OTHER_CFLAGS[sdk=iphoneos*]` in `project.yml`.

## What the console is, and why XForge's is not the reference's

The guide's terminal does this:

```swift
create_stdio("/dev/tty1", TTY_CONSOLE_MAJOR, 1)      // pid 1's stdio is the console
ISHKernel.execute(command: ["/bin/sh", "-l"])        // …then pid 1 *becomes* the shell
```

So in the reference the shell **is pid 1**, and the shell's controlling terminal is
the one pid 1 claimed when its stdio was wired. XForge instead boots a real init
(`/sbin/init`) which respawns `/sbin/xforge-login root` on `tty1`; that script reads
root's login shell out of `/etc/passwd` and execs it. That buys a guest that behaves
like a system — a real init for the guest's own scripts, `exit` giving a fresh
session, a motd — and it is what the Terminal tab and the whole rootfs design assume.

It also had a consequence the reference never sees, because the reference never
creates a second session: **`create_stdio` opens the console without `O_NOCTTY`**,
so wiring pid 1's stdio made the console *pid 1's* controlling terminal and pinned
`tty->session` to it (`fs/tty.c:126`, `tty_open` hands a tty over only while
`tty->session == 0`). The login session init then started could never take it, and
the shell ran with no controlling terminal: bash printed

```
-bash: cannot set terminal process group (-1): Not a tty
-bash: no job control in this shell
```

and no `Ctrl-C`, `Ctrl-Z` or `SIGWINCH`-on-resize reached the shell. XForge's fix is
to open pid 1's stdio with `O_NOCTTY` (`xf_create_console_stdio` in
`App/EmbeddedVM/ISHBridge.c`), which is what Linux does too: init has no controlling
terminal, the console belongs to the login session that opens it. Same flags, same
`create_stdio` shape, one bit different — and the guest keeps its init.

## The rootfs: what the reference configures, and what XForge adds

`deps/prepare_alpine_rootfs.sh` downloads the plain Alpine minirootfs, converts it
with the engine's own `tools/fakefsify`, configures it in place (mount points,
`/etc/passwd`, `/etc/profile`, `/etc/motd`, `/etc/inittab`, `/etc/resolv.conf`,
`/etc/apk/repositories`) and packs it with `zip -r alpine-rootfs.zip`, excluding the
SQLite `-wal`/`-shm` sidecars. XForge's `EmbeddedLinux/build-rootfs.sh` does the same
thing and keeps the same ordering rule, which is the one that is easy to get wrong:

> **`fakefsify` writes `meta.db` as an index of the tree as it stands.** Anything
> added to the root after the conversion exists in `data/` and is invisible to the
> guest. XForge installs the glibc layer and the guest's packages *before* the
> conversion, and asserts afterwards that they are indexed.

On top of the reference's list, XForge's root also carries:

* the **glibc compatibility layer** (`/opt/glibc`, wired through `/lib` and
  `/usr/lib`) — xtool and the Swift toolchains are glibc binaries and Alpine is musl;
* the **console packages** (`bash coreutils less ncurses-terminfo`) and root's login
  shell in `/etc/passwd`;
* `/sbin/xforge-login` and XForge's `/etc/inittab` (the stock one starts openrc,
  which is not in this root, and six gettys on terminals that do not exist);
* `EmbeddedLinux/verify-rootfs.sh`, which runs the console program in a chroot of the
  root — for a plain tree — and checks the fakefs ZIP through `meta.db`, which is the
  database the engine actually resolves through.

## Building it: the engine is a prerequisite of the app

The guide treats the engine as something you build first and then link. That is fine
for a human following instructions and wrong for a pipeline: any build that does not
know to run `deps/build_ish.sh` / `EmbeddedLinux/build-ish-core.sh` first fails
part-way through compiling the bridge, with

```
App/EmbeddedVM/ISHBridge.c:123:10: error: 'kernel/init.h' file not found
```

which reads like a missing header rather than a missing engine (and a fresh clone
has the submodule empty, so the header really is missing). So the app target now
carries a **first build phase**, `EmbeddedLinux/build-engine-for-xcode.sh`, which:

* skips itself for simulator builds (which compile the stub branch in `ISHBridge.c`)
  and for `XFORGE_SKIP_ENGINE=1`;
* fetches the engine's submodules if the checkout is empty;
* installs meson/ninja/llvm/lld/libarchive with Homebrew when they are missing
  (Xcode build phases get a bare `PATH`, so Homebrew is put on it first);
* runs `build-ish-core.sh`, which is a no-op unless the engine revision, the script
  or `project.yml` changed (`XFORGE_REBUILD_ENGINE=1` forces a rebuild).

The result is that `xcodebuild`, Xcode itself, the IPA workflow and any other
pipeline all produce the same app from the same checkout.

## Verification, and what is still only verified on a device

What CI checks, on every IPA build (`.github/workflows/build-ipa.yml`):

* the pinned rootfs release's sha256, its contents, and that the glibc layer and the
  console paths are indexed in `meta.db`;
* that the engine libraries exist and that `libish_emu.a` carries the arm64 backend;
* that the app is arm64, contains exactly one rootfs (the fakefs ZIP), has no build
  leftovers, and that its entitlements are the four the engine needs
  (`extended-virtual-addressing` and `increased-memory-limit` among them);
* for the rootfs itself, that `/sbin/xforge-login` starts the shell `/etc/passwd`
  names, as a login shell, in a chroot of the root.

What that cannot check is the guest *running on iOS*: the engine executes in-process,
under the app's entitlements, with the host's real networking and the app's tty. That
is what the Terminal tab and the smoke harness (`Tools/engine-smoke/`) are for, and
it is why a change to the console path is worth trying on a device before believing
it.
