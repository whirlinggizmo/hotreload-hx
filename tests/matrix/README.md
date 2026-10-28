# The capability matrix

A hot program edited while it runs, showing what each reload did.

```bash
python3 tests/matrix/run.py           # from the repo's directory
```

It serves the program with hotreload.DevServer and runs it in node. It builds the program
from `v1/` (copied into `src/`, beside `Main.hx`), and installs `v2/`, which makes most
of the scenarios' changes at once. Its `report` line then shows each scenario's result.
It goes on with single edits to `src/Game.hx`: a hot static's type (S6), a signature
(S13), a compile error (S15) and a standard library module the first build didn't use
(S18), and saves an asset the DevServer serves. Edits are saved as an editor saves: a
temporary file, then a rename. The native scenarios (S16, the speed of reloaded code,
and S17, C calls) are on the `hxcpp` branch.

The output goes to the terminal and to `logs/`, and is read by hand: nothing here passes
or fails on its own. `drive.py` is what runs the program and waits for its lines.
