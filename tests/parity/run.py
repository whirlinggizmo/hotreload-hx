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
- hotreload-hx's own classes are never the project's, even with its src/ among the
  project's class paths: not warned about;
- the DevServer shows a build's warnings as the build finishes, not when it stops;
- a library in the project's own repository (.haxelib/, haxelib newrepo), inside its
  directory, isn't the project's: its code isn't warned about, nor its directory watched;
- the DevServer builds from its hxml as it is now: a class path added to an hxml the
  build names (or one it names) while it runs is built with, and watched;
- built through a compilation server, from its cache, into an output directory that isn't
  there yet, the program builds without false warnings.

    python3 tests/parity/run.py            both targets, then the comparison
    python3 tests/parity/run.py cpp        one target (cpp or js), with its own checks

It exits with 1 when something differs from what's expected.
"""
import json, os, shutil, socket, subprocess, sys

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


def own(target):
    """the order/ program built from the repository's root with -cp src, which makes
    hotreload-hx's src/ one of the project's class paths: the hotreload warnings about its
    own files (there should be none), or the errors it failed with"""
    print(f"\n== hotreload-hx's src/ as a project class path, {target}")
    root = os.path.normpath(os.path.join(HERE, "..", ".."))
    output = {"cpp": ["--cpp", "tests/parity/out/own/cpp"], "js": ["--js", "tests/parity/out/own/main.js"]}[target]
    r = subprocess.run(["haxe", "-cp", "src", "-cp", "tests/parity/order", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload",
                        "--no-output"] + output, cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        lines = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l]
    else:
        lines = [l.strip() for l in r.stderr.splitlines() if "hotreload:" in l and "src/hotreload/" in l]
    for l in lines:
        print("    | " + l)
    return lines


def local_repo(target):
    """localrepo/ built as a project with its own repository (.haxelib/, as haxelib newrepo
    makes it), hotreload-hx in it as haxelib dev puts it, and localrepo/lib/ installed in it
    as locallib: what's wrong, if anything (the library's directory among the project's,
    its method passed as a value warned about, or the build failing)"""
    print(f"\n== a library in the project's own repository, {target}")
    work = os.path.join(HERE, "out", "localrepo")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "localrepo", "src"), os.path.join(work, "src"))
    repo = os.path.join(work, ".haxelib")
    os.makedirs(os.path.join(repo, "hotreload-hx"))
    with open(os.path.join(repo, "hotreload-hx", ".dev"), "w") as f:
        f.write(os.path.normpath(os.path.join(HERE, "..", "..")))
    shutil.copytree(os.path.join(HERE, "localrepo", "lib"), os.path.join(repo, "locallib", "1,0,0"))
    with open(os.path.join(repo, "locallib", ".current"), "w") as f:
        f.write("1.0.0")
    config = os.path.join(work, "config.json")
    output = {"cpp": ["--cpp", "out/cpp", "--no-output"], "js": ["--js", "out/main.js"]}[target]
    r = subprocess.run(["haxe", "-cp", "src", "-lib", "locallib", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload",
                        "-D", f"hotreload_config={config}"] + output, cwd=work, capture_output=True, text=True)
    wrong = []
    if r.returncode != 0:
        wrong = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l]
    else:
        wrong = [l.strip() for l in r.stderr.splitlines() if "passed as a value" in l]
        if target == "js":
            dirs = json.load(open(config))["dirs"]
            print("    | the project's directories: " + ", ".join(os.path.relpath(d, work) for d in dirs))
            wrong += [f"{d} is among the project's directories" for d in dirs if ".haxelib" in d]
    for l in wrong:
        print("    | " + l)
    return wrong


def dev_output():
    """the DevServer building warn/: whether the build's warnings came before it said it
    was serving (they're the build's), not after it stopped"""
    print("\n== the DevServer's build output, as it builds")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    log = os.path.join(LOGS, "dev-output.log")
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port),
                            "-cp", "warn", "--main", "Main", "--js", "out/warn/dev/main.js"], log)
    warned = False
    try:
        import time
        deadline = time.time() + 120
        while time.time() < deadline:
            lines = server.lines()
            for l in lines:
                print("    | " + l)
                if "passed as a value" in l:
                    warned = True
            if any("hotreload: serving" in l for l in lines):
                return warned
            time.sleep(0.02)
        print("    !! timed out waiting for hotreload: serving")
        return False
    finally:
        server.stop()


def dev_relist():
    """the DevServer building a copy of relist/, while a class path is added to its
    common.hxml and then used: whether that build worked, and the new path is watched"""
    print("\n== the DevServer's build, with an hxml edited as it runs")
    work = os.path.join(HERE, "out", "relist")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "relist"), work)
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(work, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"],
                     os.path.join(LOGS, "dev-relist.log"))
    try:
        if not server.wait(r"hotreload: watching", timeout=120):
            return False
        edit(os.path.join(work, "common.hxml"), "-cp src", "-cp src\n-cp extra")
        if not server.wait(r"hotreload: built|build failed", timeout=60):
            return False
        if "hotreload: watching src/, extra/" not in open(server.log).read():
            print("    !! extra/ isn't watched")
            return False
        edit(os.path.join(work, "src", "Use.hx"), '"v1"', 'Extra.hi()')
        return (server.wait(r"hotreload: built|build failed", timeout=60) or "").startswith("hotreload: built")
    finally:
        server.stop()


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
    if result["own"]:
        print(f"  FAILED {name}, hotreload-hx's src/ as a project class path: {result['own']!r}")
        failures += 1
    if result.get("local_repo"):
        print(f"  FAILED {name}, a library in the project's own repository: {result['local_repo']!r}")
        failures += 1
    if result.get("dev_relist") is False:
        print(f"  FAILED {name}: the DevServer didn't build with a class path added to its hxml as it ran")
        failures += 1
    if result.get("dev_output") is False:
        print(f"  FAILED {name}: the DevServer's build warnings didn't come before it served")
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
        results[t]["own"] = own(t)
        results[t]["local_repo"] = local_repo(t)
        if t == "js":
            results[t]["dev_output"] = dev_output()
            results[t]["dev_relist"] = dev_relist()
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
