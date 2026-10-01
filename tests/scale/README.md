# Reload time by the size of the program

How a reload's time grows with the program's size, behind
[docs/comparison.md](../../docs/comparison.md)'s "Reload time by program size". `run.py`
generates a program of N classes (Nim modules, for hotreload-nim), builds it hot, runs
it, and times one-line edits while it runs.

```bash
python3 tests/scale/run.py                                  # every kind, at 100, 1000 and 3000
python3 tests/scale/run.py hx-all js --sizes 100,1000       # some of them
python3 tests/scale/run.py nim --nim ../hotreload-nim       # where hotreload-nim is
```

Each class is about 60 lines: fields, an enum, a typedef, a map, a closure, a switch,
and references to one or two later classes, so that the deepest one, `C<N-1>`, is
something every class depends on. A hot `Game` class prints a line made from a literal in
its own code and one from `C<N-1>`, so each edit shows when it runs.

| Kind | What's reloaded |
| --- | --- |
| `hx-all` | hxcpp: every class is under `src/game/`, with `Game`, so all of them are reloaded |
| `hx-small` | hxcpp: the classes are in `src/lib/`, compiled into the executable; only `Game` is reloaded |
| `js` | JS in node, through `hotreload.DevServer`: the whole bundle, always |
| `nim` | hotreload-nim: `game.nim` and everything it imports, which is every module |

Each run makes one edit to `Game` first (the first reload, timed apart), three more, and,
but in `hx-small`, three to `C<N-1>`. For each it records the time from the save to the
new code's line ("save → running"), and from the reloader's `hotreload: building` to that
line ("build + swap"). Save → running includes the reloader's wait for the change to
settle: a check every 0.25 s, then one quiet one.

The programs go to `gen/`, the logs and a table of the results to `logs/` (`scale.md`).
The numbers are read by hand; nothing here passes or fails on its own.
