#!/usr/bin/env python3
"""The parity test: the same program and the same edits on hxcpp and on JS (node, through
hotreload.DevServer), with the same results expected of both. It checks the rules for
statics:

- a @:hot static is kept, wherever it is; a plain static of the project's starts over from
  its (new) first value, or its type's default, whether or not its class is in the native
  build's cppia module; a new one starts from its first value;
- a @:hot static whose type changed is kept when it's still the same kind of value
  (Int to Float), and starts over when not (Int to String), with the same message;
- a @:hot (default, null) static with no first value, set by the main class, is kept;
- a computed static property, (get, never), builds and reads its getter (it has no value to keep);
- the main class's statics are kept;
- a completion made in the reloaded code before a reload (a lambda calling a @:hot function
  by name), held by the main class, reaches the new code after it;
- a method of your code passed as a value is warned about, by both builds alike;
- the static functions the main class calls are @:hot without being marked, and a call the
  build can't see (through an alias) is warned about, by both builds alike;
- a class whose statics have no type written builds before the classes it uses, as
  without hotreload: another class's build macro that needs its own to have run first
  isn't run early;
- built through a compilation server, from its cache, into an output directory that isn't
  there yet, the program builds without false warnings.

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

# outside=<count>,<tag>,<n>,<list.length>: the main class sets them to 5,t,5,1; a reload
# starts them over, though Outside isn't in the native build's module
EXPECTED = {
    "v1": "report v1 kept=5 doubled=10 plain=5 widened=3 label=7 service=on outside=5,t,5,1 main=5 loaded=v1:7",
    "v2": "report v2 kept=5 doubled=10 plain=2 widened=3 label=seven added=42 service=on outside=0,null,0,0 main=5 loaded=v2:8",
    # the completion v2 made (by a module, natively) reaches v3's onLoaded
    "v3": "report v3 kept=5 doubled=10 plain=2 widened=3 label=seven added=42 service=on outside=0,null,0,0 main=5 loaded=v3:8",
    "types": [
        "hotreload: game.State.label's type changed (Int to String); started over from its first value",
        "hotreload: game.State.widened's type changed (Int to Float); carried over what still fits",
    ],
}


def fresh_sources():
    """src/game/ as v1 has it, and Outside.hx as it was"""
    shutil.rmtree(os.path.join(HERE, "src", "game"), ignore_errors=True)
    install(os.path.join(HERE, "v1"), os.path.join(HERE, "src"))
    if " // edited" in open(OUTSIDE).read():
        edit(OUTSIDE, " // edited", "")


def scenario(p, logs):
    """the edits, the same for both targets: what the program said of each. `logs`:
    everything written (the program's, and the DevServer's on JS)"""
    result = {}
    result["v1"] = p.wait(r"^report v1")
    install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
    result["v2"] = p.wait(r"^report v2", timeout=120)
    install(os.path.join(HERE, "v3"), os.path.join(HERE, "src"))
    result["v3"] = p.wait(r"^report v3", timeout=120)
    result["types"] = sorted(set(l.strip() for log in logs for l in open(log) if "type changed" in l))
    return result


def cpp():
    print("\n== cpp")
    fresh_sources()
    if subprocess.run(["haxe", "build.hxml"], cwd=HERE, stdout=subprocess.DEVNULL).returncode != 0:
        sys.exit("the build failed")
    log = os.path.join(LOGS, "cpp.log")
    p = Program(HERE, ["./out/hot/Main-debug"], log)
    try:
        result = scenario(p, [log])
        # native only: an edit outside the reloaded code (Outside isn't in the module) is told, and needs a restart
        edit(OUTSIDE, "public static var count = 0;", "public static var count = 0; // edited")
        result["restart"] = p.wait(r"outside the reloaded code: restart", timeout=60, show=False) is not None
        return result
    finally:
        p.stop()
        fresh_sources()


def js():
    print("\n== js")
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server_log = os.path.join(LOGS, "js-server.log")
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build-js.hxml"], server_log)
    p = None
    try:
        if not server.wait(r"hotreload: serving", timeout=120, show=False):
            sys.exit("the DevServer didn't start")
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        log = os.path.join(LOGS, "js.log")
        p = Program(HERE, ["node", "out/js/main.js"], log, env=env)
        return scenario(p, [log, server_log])
    finally:
        if p:
            p.stop()
        server.stop()
        fresh_sources()


def warnings(target):
    """the warn/ program's build: what the compiler warned about, one line per use of a
    method as a value (the same on both targets)"""
    print(f"\n== warnings, {target}")
    os.makedirs(os.path.join(HERE, "out", "warn"), exist_ok=True)
    output = {"cpp": ["--cpp", "out/warn/cpp"], "js": ["--js", "out/warn/main.js"]}[target]
    r = subprocess.run(["haxe", "-cp", "warn", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload", "--no-output"] + output,
                       cwd=HERE, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("the warn/ build failed:\n" + r.stderr)
    lines = sorted(l.strip() for l in r.stderr.splitlines() if "Warning" in l and "hotreload:" in l)
    for l in lines:
        print("    | " + l)
    return lines


def order(target):
    """the order/ program's build: the errors it failed with, or none"""
    print(f"\n== build order, {target}")
    os.makedirs(os.path.join(HERE, "out", "order"), exist_ok=True)
    output = {"cpp": ["--cpp", "out/order/cpp"], "js": ["--js", "out/order/main.js"]}[target]
    r = subprocess.run(["haxe", "-cp", "order", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload", "--no-output"] + output,
                       cwd=HERE, capture_output=True, text=True)
    errors = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l] if r.returncode != 0 else []
    for l in errors:
        print("    | " + l)
    return errors


def server(target):
    """the program built through a compilation server, as the DevServer and an editor do:
    four builds, the later ones from the server's cache, into an output directory that
    isn't there yet. Each build's hotreload warnings: a build whose main class came from
    the cache says nothing about its calls"""
    print(f"\n== compilation server, {target}")
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    out = os.path.join(HERE, "out", "server")
    shutil.rmtree(out, ignore_errors=True)
    srv = subprocess.Popen(["haxe", "--wait", str(port)], cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import time
        time.sleep(1)
        output = {"cpp": ["--cpp", "out/server/cpp", "--no-output"], "js": ["--js", "out/server/main.js"]}[target]
        results = []
        for reload in [False, False, True, True]:
            extra = ["-D", "hotreload_reload"] if reload and target == "js" else []
            r = subprocess.run(["haxe", "--connect", str(port), "-cp", "src", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload"]
                               + extra + output, cwd=HERE, capture_output=True, text=True)
            lines = sorted(l.strip() for l in r.stderr.splitlines() if "hotreload:" in l)
            print(f"    | build {len(results) + 1}: exit {r.returncode}, {len(lines)} hotreload warnings")
            for l in lines:
                print("    |   " + l)
            results.append({"code": r.returncode, "warnings": lines})
        return results
    finally:
        srv.kill()
        srv.wait()


WARNINGS = sorted([
    "warn/Main.hx:11: characters 3-12 : Warning : hotreload: the main class calls Warn.later in a way the build can't see (through an alias?), so it isn't @:hot: mark it yourself, or a native reload won't reach it",
    "warn/Main.hx:12: characters 14-24 : Warning : hotreload: later passed as a value keeps its old code after a reload; call it from a lambda, x -> later(x)",
    "warn/Warn.hx:14: characters 8-15 : Warning : hotreload: place passed as a value keeps its old code after a reload; call it from a lambda, x -> place(x)",
    "warn/Warn.hx:15: characters 8-16 : Warning : hotreload: placeAll passed as a value keeps its old code after a reload; call it from a lambda, x -> placeAll(x)",
])


def check(name, result):
    """what one target did, against what's expected"""
    failures = 0
    for key in EXPECTED:
        if result[key] != EXPECTED[key]:
            print(f"  FAILED {name}, {key}: {result[key]!r}, expected {EXPECTED[key]!r}")
            failures += 1
    if "restart" in result and not result["restart"]:
        print(f"  FAILED {name}: the edit outside the reloaded code wasn't told")
        failures += 1
    for i, b in enumerate(result.get("server", [])):
        if b["code"] != 0 or b["warnings"] != []:
            print(f"  FAILED {name}, compilation server build {i + 1}: exit {b['code']}, warnings {b['warnings']!r}")
            failures += 1
    if result["order"]:
        print(f"  FAILED {name}, the order/ build: {result['order']!r}")
        failures += 1
    if result["warnings"] != WARNINGS:
        print(f"  FAILED {name}, warnings: {result['warnings']!r}, expected {WARNINGS!r}")
        failures += 1
    if failures == 0:
        print(f"  ok: {name}, as expected")
    return failures


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    targets = sys.argv[1:] or ["cpp", "js"]
    results = {t: {"cpp": cpp, "js": js}[t]() for t in targets}
    for t in targets:
        results[t]["warnings"] = warnings(t)
        results[t]["order"] = order(t)
        results[t]["server"] = server(t)
    print("\n== results")
    failures = sum(check(t, r) for t, r in results.items())
    if len(targets) == 2:
        shared = {t: {k: v for k, v in r.items() if k in EXPECTED} for t, r in results.items()}
        if shared["cpp"] != shared["js"]:
            print("  FAILED: the targets differ")
            failures += 1
    print("\nall passed" if failures == 0 else f"\n{failures} failed")
    sys.exit(1 if failures else 0)
