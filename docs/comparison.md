# hotreload-nim vs hotreload-hx

Measured 2026-09-29 (program size: 2026-10-01), on Linux, with Nim 2.2.12, Haxe 4.3.6 and hxcpp (a fork, for the
debugger). The same file is in both repos:
[hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim/blob/main/docs/comparison.md)
and [hotreload-hx](https://github.com/whirlinggizmo/hotreload-hx/blob/main/docs/comparison.md).

## Summary

Three ways to hot reload, and none best at everything: hotreload-hx on JS reloads fastest,
runs reloaded code at full speed and takes the most kinds of change, but runs in a page or
node; hotreload-nim is the only one whose reloaded code is native and can call anything;
hotreload-hx on hxcpp (cppia) sits between them, and debugs best.

- **hotreload-hx, JS** (added 2026-09-29): 0.23–0.25 s from a save to the new code, the
  same speed after a reload as before (V8), and nothing to mark: every class reloads,
  and signature changes just reload.
- **hotreload-hx, hxcpp**: 0.35–0.55 s. With the forked hxcpp and hxcpp-debugger, its
  breakpoints stay aligned after a reload. Reloaded code runs 5–13× slower under cppia's
  JIT, and up to 56× slower interpreted.
- **hotreload-nim**: 1.6–1.8 s, but reloaded code runs natively (a release hot build the
  same after a reload as before), and can call any C function.
- **Bugs** (below): hotreload-nim's that silently corrupted state across a reload, enums
  and refs shared between hot globals, are fixed; hotreload-hx on hxcpp still runs stale
  code after a restart until the first edit.

## All three, side by side

The sections after this one compare hotreload-nim and hotreload-hx on hxcpp in detail; JS
was measured the same way: wgrender-hx's `simple` as a guest in a headless browser, and
`tests/matrix` (`run.py js`) in node.

| | hotreload-nim | hotreload-hx, hxcpp (cppia) | hotreload-hx, JS |
| --- | --- | --- | --- |
| How it reloads | rebuilds the reloaded modules as a native shared library | rebuilds the reloaded code as a cppia module | rebuilds the whole bundle; the page takes on its classes |
| What reloads | modules with `{.hot.}`, and what they import; not the main module | the hot classes' directories; not the main class | everything, the main class too |
| What you mark | `{.hot.}` globals and procs | `@:hot` statics and functions | nothing |
| Save to new code (`simple`) | 1.62–1.78 s | 0.35–0.55 s | 0.22–0.25 s (first reload 0.77 s) |
| Build per reload | ~1.3 s | 0.05–0.07 s | 0.04–0.06 s |
| Reloaded code's speed | native (release hot build: the same; `-Og`: 1.5× on one loop) | 5–13× slower (JIT), up to 56× (`-debug`) | the same as before the reload (V8) |
| Memory per reload | ~0.2 MB, and a copy of ref-held hot state | ~1.25 MB | not measured (old bundles are collected, but the first) |
| Files left behind | none | none | none (one bundle, rewritten) |
| Hot build's program | a 7 MB executable | a 77 MB executable | a bundle, and a wasm host exporting all of wgrender |
| Debugging reloaded code | gdb/lldb; breakpoints go stale after a reload | the hxcpp/debugger forks; breakpoints stay aligned (interpreted only) | browser devtools or VS Code; not tried across reloads |
| Native code from reloaded code | any C function | only what the executable already compiled | any wgrender call (the hot host exports them all) |
| Where it runs | Linux tested (macOS in CI; Windows needs MinGW) | Linux tested | a page, or node |
| Release builds | ordinary, no cost | ordinary, no cost | ordinary, no cost |

| # | Change made while running | hotreload-nim | hotreload-hx, cppia | hotreload-hx, JS |
| --- | --- | --- | --- | --- |
| S1 | Body of a hot function | Works | Works | Works |
| S2 | Add a hot global/static | Works | Works | Works |
| S3 | Add a field with a default | Works: its default | Works: its initializer | Works: its initializer |
| S4 | Rename a field | value lost | value lost (0) | value lost (`undefined`) |
| S5 | Field type int → float | reset to its default | carried | carried |
| S6 | A static's own type int → string | reset, and says so | reset, and says so | reset, and says so |
| S7 | Insert an enum member first | Works, by name | Works, by name | Works, by name |
| S8 | Hot state holding a subclass object | refused at compile time | Works: the new override | Works: the new override |
| S9 | A closure in hot state | refused at compile time | allowed; runs old code | allowed; runs old code |
| S10 | A callback made before a reload | old code; writes to ref globals lost | old code; writes land | old code; writes land |
| S11 | Shared refs and cycles | Works, in one global and between two | Works | Works |
| S12 | Add a source file | Works | Works | Works |
| S13 | Change a hot function's signature | refused; restart | refused; restart | Works: just reloads |
| S14 | An object the main module made | old code (hot procs on it are new) | old code | new code |
| S15 | A compile error | old code runs on; the fix reloads | old code runs on; the fix reloads | old code runs on; the fix reloads |
| S16 | Speed of reloaded code | native | 5–56× slower | the same |
| S17 | A native call the first build didn't make | Works: any C function | `__cpp__` refused; a new extern "Bad link" | any wgrender call; not tested |
| S18 | A std module the first build didn't use | Works | pure Haxe works; native "Bad link" | Works |

On S11, cppia and JS keep one identity map for all the statics, which covers two globals by
design; their tests shared refs within one.

## How it was measured

Every result here comes from running the libraries, not from their READMEs. Edits were
saved as editors save them: a temporary file, then a rename. The test programs are in
`tests/matrix/` in each repo, with how to run them.

| Program | What it measured |
| --- | --- |
| wgrender's `simple` example (`examples/simple` in each repo), a window at 60 fps | save-to-reload time, build size and time |
| A console test program per library | what each can and can't do (S1–S18) |
| A timed loop in a hot function | the speed of reloaded code |

For the windowed runs, screen blanking was off, and the app's own `elapsed` counter was
checked against the wall clock. A sleeping display blocks vsync and stalls frames, which
made an earlier run's numbers wrong.

## Reload turnaround

hotreload-hx puts new code on screen 3–4× sooner. The difference is almost all build time:
0.05 s through the Haxe compilation server, against 1.3 s of `nim c` and gcc.

| Measure (`simple`, 60 fps, 5 edits each) | hotreload-nim | hotreload-hx |
| --- | --- | --- |
| Save to build start (a check every 0.25 s, then one quiet check) | 0.31–0.48 s | 0.30–0.48 s |
| Build + swap | 1.30–1.32 s | 0.05–0.07 s (first reload 0.54 s) |
| **Save to new code running** | **1.62–1.78 s** | **0.35–0.55 s** (first reload 0.88 s) |
| Same, in a console program | 1.16–1.55 s | about 0.75 s (hello, which only updates 4 times a second) |
| Full hot build of `simple` | 6.4 s (Nim cache cold) | 3.6 s (hxcpp compile cache already warm) |
| Hot executable size | 7 MB | 77 MB (`-D scriptable`, `-dce no`) |

The two full-build times aren't comparable: the Haxe build reused C++ from hxcpp's compile
cache. Haxe's first reload in a session is slower because the compilation server hasn't
cached the edited files yet.

## Reload time by program size

Measured 2026-10-01 with hotreload-hx's `tests/scale/run.py`, on Haxe 4.3.6: a generated
program of N classes (modules, for Nim), each about 60 lines, with a hot `Game` class and
a chain of dependencies, C0 → C1 → … → C(N-1), so that the last class is one everything
depends on. Build + swap is the time from the reloader's "building" line to the new
code's first output; a save adds the reloader's 0.3–0.5 s wait for the file to settle.

| Edit, build + swap | 100 classes | 1,000 classes | 3,000 classes |
| --- | --- | --- | --- |
| hxcpp, every class reloaded: the hot class | 0.07 s | 0.6 s | 1.8–1.9 s |
| hxcpp, only the hot class reloaded, the rest in the executable | 0.02–0.04 s | 0.06–0.08 s | 0.2–0.3 s |
| JS: the hot class | 0.05 s | 0.23 s | 0.8 s |
| Nim: any edit | 0.9 s | 16.6–17.3 s | 167–201 s |

A full hot build took 7 s, 59 s and about 155 s on hxcpp (the C++ compile), 0.3, 1.3 and
5.0 s on JS, and 1.3, 17.5 and 168 s with Nim.

Nim's reloads cost as much as its full build: `nim c` has no incremental mode, so every
edit re-checks every module of the hot library (gcc then recompiles only the C files
that changed), and it grows faster than the program does, 10× for 3× the modules. Haxe
builds through its compilation server, which re-types only the changed files and what
depends on them, and its reloads grow about linearly with what's in the module. With the
big part of the program compiled into the executable and only the hot classes in the
module, a reload barely grows at all.

**Editing a class everything depends on** (C(N-1), at the end of the chain) hit a bug in
the Haxe compilation server: 11 s at 1,000 classes and about 290 s at 3,000, the same on
hxcpp and JS (and 6.6 s and 159 s on the 5.0 nightly), where a build without the server
takes 1.5 s and 5 s. When the server skips a cached module whose dependency changed, it
formats the reason, the whole dependency chain, into a string before deciding whether to
print it, with a printer that's quadratic in the chain's depth: cubic in the depth, once
per module on the chain. It takes a chain hundreds deep to notice: the same 1,000
classes depending on the last one directly reload in 0.9 s. Reported as
[haxe#13057](https://github.com/HaxeFoundation/haxe/issues/13057) and fixed by
[#13058](https://github.com/HaxeFoundation/haxe/pull/13058), merged into `development`
(Haxe 5) on 2026-10-01; 4.3.7 and earlier still have it, a cost on every reload that's
tiny for ordinary programs.

## Speed of reloaded code

"Before" is the same code compiled into the executable, before the first reload. "After"
is the same loop in the same run, after a reload.

| Build | Loop | Before | After | After ÷ before |
| --- | --- | --- | --- | --- |
| Nim, `-d:release` hot build | A (a dependency chain), 50M iterations | 148 ms | 149 ms | 1.0× |
| Nim, `-d:release` hot build | B (independent steps), 50M iterations | 33.6 ms | 33.5 ms | 1.0× |
| Nim, default hot build (`-Og`) | A | 152 ms | 150 ms | 1.0× |
| Nim, default hot build (`-Og`) | B | 170 ms | 258 ms | 1.5× |
| Haxe, no `-debug` (cppia JIT) | 1,000 objects × 5,000 frames | 7 ms | 41 ms | 5.9× |
| Haxe, no `-debug` (cppia JIT) | math, 20M iterations | 62 ms | 748 ms | 12.1× |
| Haxe, `-debug` (cppia interpreted) | 1,000 objects × 5,000 frames | 89 ms | 603 ms | 6.8× |
| Haxe, `-debug` (cppia interpreted) | math, 20M iterations | 43 ms | 2,421 ms | 56.3× |

Nim's one slowdown is loop B in the default hot build: the library is built `-fPIC -Og`,
and its gcc output differs from the executable's. With `-d:release` it's identical. cppia
only honours breakpoints when interpreted, so a Haxe session you're debugging in is also
the slowest mode.

The Haxe slowdown arrives all at once at the first reload; it doesn't grow over a
session. Each module is built whole from the reloaded code: every class in the watched
directories that the hot classes reach, not only the files that changed. So one edit
moves all of it into cppia, and later reloads run at the same speed as the first. Code
outside those directories stays native for the whole session: the main class, std,
haxelibs and the engine. Keeping heavy code there keeps it native, at the price of a
restart when it changes.

## What each can do

Each row was tested by editing a running program. "Old code" means the change is accepted,
but that call still runs the version from before the reload.

| # | Change made while running | hotreload-nim | hotreload-hx |
| --- | --- | --- | --- |
| S1 | Body of a hot function | Works | Works |
| S2 | Add a hot global/static | Works | Works |
| S3 | Add a field with a default to a type in hot state | Works: the new field gets its default | Works: the new field runs its initializer |
| S4 | Rename a field | Value lost (by design) | Value lost (by design) |
| S5 | Field type int → float | Reset to the default | Carried (3 stays 3) |
| S6 | Hot global's own type int → string | Reset; the message says it started over (fixed: it used to say "carried over what still fits") | Reset; the message says it started over |
| S7 | Insert an enum member at the front | Works: by name, `Blue` stays `Blue` (fixed: it kept the ordinal, so `Blue` became `Green`) | Works: by name, `Happy(1)` stays `Happy(1)` |
| S8 | Hot state holding a subclass object | Refused when the executable compiles | Works: runs the new override |
| S9 | A closure stored in hot state | Refused when the executable compiles | Accepted; the closure runs old code |
| S10 | A callback made before a reload, called after | Old code; **writes to ref-holding globals are lost on every reload** | Old code; its writes land (one storage for the whole run) |
| S11 | Shared refs and cycles in hot state | Works, within one global and between two (fixed: refs shared between two globals split after the first reload) | Works (one identity map for all hot statics; tested within one) |
| S12 | Add a new source file | Works | Works |
| S13 | Change a hot function's signature | Refused; old code runs; reverting reloads | Refused; old code runs; reverting reloads |
| S14 | An object the main module made, called after a reload | Old code (hot procs on it run new code) | Old code (the executable's own copy of the class) |
| S15 | A compile error | Old code keeps running; the fix reloads | Old code keeps running; the fix reloads |
| S16 | Speed of reloaded code | Native (above) | 5–56× slower (above) |
| S17 | Call a C function the executable never used | Works (`importc` of `abs`, `strtol`) | `__cpp__`: refused at build. A new extern: builds, then "Bad link" at load; old code keeps running |
| S18 | Use a std module the executable never used | Works (`std/json`) | Pure Haxe works (`haxe.Json`); a native one fails with "Bad link" (`sys.db.Sqlite`) |

## Debugging reloaded code

| | hotreload-nim | hotreload-hx |
| --- | --- | --- |
| Debugger | gdb or lldb (native) | hxcpp-debugger in VS Code |
| After a reload | Breakpoints go stale once lines shift; debug the non-hot build instead | Breakpoints stay aligned |
| Cost | None: native stepping at native speed | Breakpoints only fire in interpreted cppia (`-debug`), the slowest mode |
| Needs | The standard toolchain | Changes to hxcpp and hxcpp-debugger that aren't upstream yet |

Nim's breakpoint behaviour is from its README, not retested here.

## Bugs found

hotreload-nim's enum, shared-ref and message bugs were fixed on 2026-09-29, with unit tests
in `tests/tmigrate.nim`, and scenarios S3–S7 and S10–S11 rerun.

| Library | Bug | Reproduce | Likely fix |
| --- | --- | --- | --- |
| hotreload-nim | **Fixed.** Enums were carried by ordinal, so inserting a member changed a stored value's meaning | `type Color = enum Red, Green, Blue`; `var c {.hot.} = Red`; set `c = Blue`; insert `Black` first: `c` read `Green` | `migrate.nim` writes an enum's member name and finds it by name (sets of enums too) |
| hotreload-nim | **Fixed.** Refs shared between two hot globals became separate copies after any reload | `var na {.hot.} = Node(); var nb {.hot.} = Node()`; `na.buddy = nb; nb.buddy = na`; any body edit: `na.buddy == nb` was false | One table of copies for every hot global a reload carries over, by `copy` or `load` |
| hotreload-nim | A ref-holding global moves to new storage on every reload, not only when its type changes, so an old callback's writes to it are lost | A callback from before a reload writes `bag.n = 1`; the next tick shows `bag.n=0 hotMoves=2` | Follows from the copy on every reload; `hotMoves()` does detect it |
| hotreload-nim | **Fixed.** Type-change messages always said "carried over what still fits", even when the value was reset | Change a global's type int → string | The message names what was dropped or reset, or says it started over |
| hotreload-nim | The default hot build (`-Og`) runs slower after the first reload | The speed loop B, before and after a reload: 170 → 258 ms | Build the library with the executable's flags; `-d:release` is unaffected |
| hotreload-hx | A restarted program runs the code it was built with, not what's on disk, until the first edit | Edit `src/` while it's stopped, then start it: the old code runs | Swap in the startup warm-up build when the sources are newer than the executable |
| hotreload-hx, JS | **Fixed.** From the second reload on, the main class kept running the first reload's code: each swap pointed the previous bundle's methods at the new code by copying them, so the first bundle, which the main class calls through, stayed pointed at the second | `tests/scale/run.py js --sizes 30`: the version line stops changing after the first reload | Each swap re-points the first bundle's classes at the new ones too |
| Haxe | The compilation server takes cubic time in the depth of a dependency chain to skip the modules on it (above) | `tests/scale/run.py hx-all js --sizes 1000`, the "deep" edits | **Fixed in [#13058](https://github.com/HaxeFoundation/haxe/pull/13058)**, for Haxe 5: format the skip reason only when it's printed, and in linear time |
| hotreload-hx | "Bad link", when new code needs native code the executable lacks, doesn't say why or that a restart fixes it | Call a new extern, or `sys.db.Sqlite`, in reloaded code | Catch it; name the class, and say to restart |

Minor, in hotreload-nim: old `lib*_N.so` files and Nim cache files pile up in the build
directory, and a refused library still uses up its version number.

## When to use which

| If the reloaded code is… | Use | Because |
| --- | --- | --- |
| Gameplay: state machines, AI, UI, tuning values | hotreload-hx | 0.35 s reloads, working breakpoints, state carried by name; the cppia slowdown rarely shows in this kind of code |
| Per-frame work at scale: physics, per-entity updates, tight loops | hotreload-nim | Reloaded code runs natively, the same as the shipped build in a release hot build |
| Engine-side, or calling C functions the executable doesn't already use | hotreload-nim | Reloaded Haxe code can only reach native code the executable already compiled |
| Something you want to step through in a debugger while editing it | hotreload-hx | Its breakpoints survive a reload; Nim's go stale |
| Game code that can run as a web guest (wgrender-hx's JS target) | hotreload-hx, JS | The fastest reloads, reloaded code at full speed, the most kinds of change, and nothing to mark |
