#!/usr/bin/env python3
"""The parity test: the same program and the same edits on hxcpp and on JS (node, through
hotreload.DevServer), with the same results expected of both. It checks the rules for
statics:

- a @:hot static is kept; a plain one of the reloaded code starts over from its (new)
  first value; a new one starts from its first value;
- a @:hot static whose type changed is kept when it's still the same kind of value
  (Int to Float), and starts over when not (Int to String), with the same message;
- the statics of a class outside the reloaded code, and of the main class, are kept;
- an edit outside the reloaded code is told as such;
- -D hotreload_paths makes a directory part of the reloaded code.

    python3 tests/parity/run.py            both targets, then the comparison
    python3 tests/parity/run.py cpp        one target (cpp or js), with its own checks

It exits with 1 when something differs from what's expected.
"""
import os, shutil, socket, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "matrix"))
from drive import Program, edit, install

LOGS = os.path.join(HERE, "logs")
OUTSIDE = os.path.join(HERE, "src", "Outside.hx")

# each round: the defines it builds with, and what's expected of both targets
ROUNDS = {
    # the reloaded code is game/ (State's directory): Outside and the main class aren't
    # part of it, so their statics are kept, and an edit to Outside is told as outside
    "default": {
        "defines": [],
        "v1": "report v1 kept=5 plain=5 widened=3 label=7 outside=5 main=5",
        "v2": "report v2 kept=5 plain=2 widened=3 label=seven added=42 outside=5 main=5",
        "outside": True,
    },
    # -D hotreload_paths=src: Outside is part of it too, so its plain static starts over,
    # and an edit to it reloads; the main class still isn't
    "paths": {
        "defines": ["-D", "hotreload_paths=src"],
        "v1": "report v1 kept=5 plain=5 widened=3 label=7 outside=5 main=5",
        "v2": "report v2 kept=5 plain=2 widened=3 label=seven added=42 outside=0 main=5",
        "outside": False,
    },
}
TYPES = [
    "hotreload: game.State.label's type changed (Int to String); started over from its first value",
    "hotreload: game.State.widened's type changed (Int to Float); carried over what still fits",
]


def fresh_sources():
    """src/game/ as v1 has it, and Outside.hx as it was"""
    shutil.rmtree(os.path.join(HERE, "src", "game"), ignore_errors=True)
    install(os.path.join(HERE, "v1"), os.path.join(HERE, "src"))
    if " // edited" in open(OUTSIDE).read():
        edit(OUTSIDE, " // edited", "")


def scenario(round, p, teller, logs):
    """the edits, the same for both targets: what the program said of each. `teller` is
    what tells an edit outside the reloaded code (the program natively, the DevServer on
    JS); `logs`, everything they wrote"""
    expected = ROUNDS[round]
    result = {}
    result["v1"] = p.wait(r"^report v1")
    install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
    result["v2"] = p.wait(r"^report v2", timeout=120)
    edit(OUTSIDE, "public static var count = 0;", "public static var count = 0; // edited")
    if expected["outside"]:
        result["outside"] = teller.wait(r"outside the reloaded code", timeout=120, show=False) is not None
    else:
        # it's reloaded code: the edit reloads, and the same report comes again
        p.wait(r"^report v2", timeout=120)
        result["outside"] = any("outside the reloaded code" in open(log).read() for log in logs)
    result["types"] = sorted(set(l.strip() for log in logs for l in open(log) if "type changed" in l))
    return result


def cpp(round):
    print(f"\n== cpp, {round}")
    fresh_sources()
    if subprocess.run(["haxe", "build.hxml"] + ROUNDS[round]["defines"], cwd=HERE, stdout=subprocess.DEVNULL).returncode != 0:
        sys.exit("the build failed")
    log = os.path.join(LOGS, f"cpp-{round}.log")
    p = Program(HERE, ["./out/hot/Main-debug"], log)
    try:
        return scenario(round, p, p, [log])
    finally:
        p.stop()
        fresh_sources()


def js(round):
    print(f"\n== js, {round}")
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server_log = os.path.join(LOGS, f"js-server-{round}.log")
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build-js.hxml"]
                     + ROUNDS[round]["defines"], server_log)
    p = None
    try:
        if not server.wait(r"hotreload: serving", timeout=120, show=False):
            sys.exit("the DevServer didn't start")
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        log = os.path.join(LOGS, f"js-{round}.log")
        p = Program(HERE, ["node", "out/js/main.js"], log, env=env)
        return scenario(round, p, server, [log, server_log])
    finally:
        if p:
            p.stop()
        server.stop()
        fresh_sources()


def check(name, round, result):
    """what one target did in a round, against what's expected"""
    expected = ROUNDS[round]
    failures = 0
    for key in ["v1", "v2", "outside"]:
        if result[key] != expected[key]:
            print(f"  FAILED {name}, {round}, {key}: {result[key]!r}, expected {expected[key]!r}")
            failures += 1
    if result["types"] != TYPES:
        print(f"  FAILED {name}, {round}, types: {result['types']!r}, expected {TYPES!r}")
        failures += 1
    if failures == 0:
        print(f"  ok: {name}, {round}, as expected")
    return failures


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    targets = sys.argv[1:] or ["cpp", "js"]
    results = {(t, r): {"cpp": cpp, "js": js}[t](r) for t in targets for r in ROUNDS}
    print("\n== results")
    failures = sum(check(t, r, result) for (t, r), result in results.items())
    if len(targets) == 2:
        for r in ROUNDS:
            if results[("cpp", r)] != results[("js", r)]:
                print(f"  FAILED: the targets differ in {r}")
                failures += 1
    print("\nall passed" if failures == 0 else f"\n{failures} failed")
    sys.exit(1 if failures else 0)
