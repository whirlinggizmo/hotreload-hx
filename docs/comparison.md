# hotreload-nim vs hotreload-hx

Measured 2026-09-29, on Linux, with Nim 2.2.12, Haxe 4.3.6 and hxcpp (a fork, for the
debugger). The same file is in both repos:
[hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim/blob/main/docs/comparison.md)
and [hotreload-hx](https://github.com/whirlinggizmo/hotreload-hx/blob/main/docs/comparison.md).

## Summary

hotreload-hx wins the day-to-day loop; hotreload-nim wins wherever the reloaded code has to
run fast or call C. Pick by what you're reloading, not by language.

- **hotreload-hx** reloads in 0.35–0.55 s, against 1.6–1.8 s. With the forked hxcpp and
  hxcpp-debugger, its breakpoints stay aligned after a reload. It carries state by name,
  and each hot static has one storage for the whole run.
- **hotreload-nim** runs reloaded code natively: a release hot build runs the same after a
  reload as before. Reloaded Haxe code runs 5–13× slower under cppia's JIT, and up to 56×
  slower interpreted. Nim's reloaded code can also call any C function; Haxe's only
  reaches native code the executable already compiled.
- **Both have bugs** (below). Two of hotreload-nim's silently corrupt state across a reload;
  hotreload-hx runs stale code after a restart until the first edit.

## How it was measured

Every result here comes from running the libraries, not from their READMEs. Each ran in a
git worktree in a scratch directory. Edits were saved as editors save them: a temporary
file, then a rename.

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
| S6 | Hot global's own type int → string | Reset; the message wrongly says "carried over what still fits" | Reset; the message says it started over |
| S7 | Insert an enum member at the front | **Wrong:** keeps the ordinal, so `Blue` becomes `Green` | Works: by name, `Happy(1)` stays `Happy(1)` |
| S8 | Hot state holding a subclass object | Refused when the executable compiles | Works: runs the new override |
| S9 | A closure stored in hot state | Refused when the executable compiles | Accepted; the closure runs old code |
| S10 | A callback made before a reload, called after | Old code; **writes to ref-holding globals are lost on every reload** | Old code; its writes land (one storage for the whole run) |
| S11 | Shared refs and cycles in hot state | Works inside one global; **refs shared between two globals split after the first reload** | Works (one identity map for all hot statics; tested within one) |
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

None are fixed yet.

| Library | Bug | Reproduce | Likely fix |
| --- | --- | --- | --- |
| hotreload-nim | Enums are carried by ordinal, so inserting a member changes a stored value's meaning | `type Color = enum Red, Green, Blue`; `var c {.hot.} = Red`; set `c = Blue`; insert `Black` first: `c` reads `Green` | `migrate.nim`: write enums by name, match by name on load |
| hotreload-nim | Refs shared between two hot globals become separate copies after any reload | `var na {.hot.} = Node(); var nb {.hot.} = Node()`; `na.buddy = nb; nb.buddy = na`; any body edit: `na.buddy == nb` is false, and one copy goes stale | Copy all hot globals in one pass, with one identity table |
| hotreload-nim | A ref-holding global moves to new storage on every reload, not only when its type changes, so an old callback's writes to it are lost | A callback from before a reload writes `bag.n = 1`; the next tick shows `bag.n=0 hotMoves=2` | Follows from the copy on every reload; `hotMoves()` does detect it |
| hotreload-nim | Type-change messages always say "carried over what still fits", even when the value was reset | Change a global's type int → string: the message says carried, the value is the new first value | Say which values were reset |
| hotreload-nim | The default hot build (`-Og`) runs slower after the first reload | The speed loop B, before and after a reload: 170 → 258 ms | Build the library with the executable's flags; `-d:release` is unaffected |
| hotreload-hx | A restarted program runs the code it was built with, not what's on disk, until the first edit | Edit `src/` while it's stopped, then start it: the old code runs | Swap in the startup warm-up build when the sources are newer than the executable |
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
