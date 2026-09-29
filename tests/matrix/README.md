# The capability matrix

The programs behind [docs/comparison.md](../../docs/comparison.md): a hot program edited
while it runs, showing what each reload did. hotreload-nim has the same scenarios in its
`tests/matrix/`.

```bash
python3 tests/matrix/run.py           # both parts, from the repo's directory
python3 tests/matrix/run.py matrix    # S1-S15, S17, S18
python3 tests/matrix/run.py perf      # S16: the speed of reloaded code
```

`matrix` builds the program from `v1/` (copied into `src/`, beside `Main.hx`), runs it,
and installs `v2/`, which makes most of the scenarios' changes at once. Its `report`
line then shows each scenario's result. It goes on with single edits to `src/Game.hx`: a
hot static's type (S6), a signature (S13), a compile error (S15), a C call (S17) and
standard library modules the executable never used (S18). Edits are saved as an editor
saves: a temporary file, then a rename.

`perf` times two loops in a `@:hot` function, natively before any reload and in cppia
after each of two reloads. It does it twice: in a `-debug` hot build, where cppia is
interpreted, and in one without `-debug`, where cppia's JIT is on.

The output goes to the terminal and to `logs/`, and is read by hand: nothing here passes
or fails on its own. `drive.py` is what runs the program and waits for its lines.
