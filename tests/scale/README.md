# Reload time by the size of the program

How a reload's time grows with the program's size. `run.py` generates a program of N
classes, builds it hot, runs it in node through `hotreload.DevServer`, and times one-line
edits while it runs. Each edit rebuilds the whole bundle.

```bash
python3 tests/scale/run.py                       # at 100, 1000 and 3000 classes
python3 tests/scale/run.py --sizes 100,1000
```

Each class is about 60 lines: fields, an enum, a typedef, a map, a closure, a switch,
and references to one or two later classes, so that the deepest one, `C<N-1>`, is
something every class depends on. A hot `Game` class prints a line made from a literal in
its own code and one from `C<N-1>`, so each edit shows when it runs.

Each run makes one edit to `Game` first (the first reload, timed apart), three more, and
three to `C<N-1>`. For each it records the time from the save to the
new code's line ("save → running"), and from the reloader's `hotreload: build: started` to that
line ("build + swap"). Save → running includes the reloader's wait for the change to
settle: a check every 0.25 s, then one quiet one.

The programs are generated in `gen/`, and each is deleted once it's measured, since a
program and its build run to gigabytes at 3000 classes; `gen/` itself goes when the run
ends, even a failed or stopped one. `--keep` keeps them, to look into one, until the next
run without it. `gen/` is ignored by git. The logs and a table of the results go to
`logs/` (`scale.md`). The numbers are read by hand; nothing here passes or fails on its own.
