#!/usr/bin/env python3
"""The behavior test: a program served with hotreload.DevServer and run in node, edited as
it runs, and its builds. It checks the rules for statics:

- every static is kept, whatever its class; one whose first value was edited resets to
  the new one, with a message; one marked @:resetOnHotReload resets on every reload, said
  nothing about; a new one starts from its first value;
- a static whose type changed and first value didn't is kept when it's still the same
  kind of value (Int to Float), and resets when not (Int to String), with a message;
- a (default, null) static with no first value, set by the main class, is kept;
- a computed static property, (get, never), builds and reads its getter (it has no value to keep);
- the main class's statics are kept;
- a completion made in the reloaded code before a reload (a lambda calling a function by
  name), held by the main class, reaches the new code after it;
- @:hot, deprecated, is warned about; a method passed as a value is not;
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
- the DevServer told to watch a directory outside the project (--watch), a library's,
  says so, and an edit there is built;
- a listener added before a reload as a bound method (addEventListener(CLICK, onClick))
  or a static function, where the reload's walk doesn't reach it, runs the new code after
  it, and the new code can remove it;
- an enum constant with no arguments is the same object across a reload, its index the new
  code's: one a closure holds still matches its case and equals the new code's constant,
  with constructors put before it; a moved constructor with arguments is said;
- an edit a reload cannot bring in is said: main, a closure, a constructor, a field
  initializer and a renamed field;
- built through a compilation server, from its cache, into an output directory that isn't
  there yet, the program builds without false warnings.

    python3 tests/behavior/run.py

It exits with 1 when something differs from what's expected.
"""
import json, os, shutil, socket, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "matrix"))
from drive import Program, edit, install, save

LOGS = os.path.join(HERE, "logs")
OUTSIDE = os.path.join(HERE, "src", "Outside.hx")

# outside=<count>,<tag>,<n>,<list.length>: the main class sets them to 5,t,5,1, and no
# reload edits them, so they're kept
EXPECTED = {
    "v1": "report v1 kept=5 doubled=10 tuned=5 widened=3 label=7 mode=5 cache=5 service=on outside=5,t,5,1 main=5 loaded=v1:7",
    "v2": "report v2 kept=5 doubled=10 tuned=2 widened=3 label=seven mode=null cache=1 added=42 service=on outside=5,t,5,1 main=5 loaded=v2:8",
    # the completion v2 made reaches v3's onLoaded
    "v3": "report v3 kept=5 doubled=10 tuned=2 widened=3 label=seven mode=null cache=1 added=42 service=on outside=5,t,5,1 main=5 loaded=v3:8",
    "statics": [
        'hotreload: static: game.State.label reset (initial value changed: 7 to "seven")',
        "hotreload: static: game.State.mode reset (type changed: Int to String)",
        "hotreload: static: game.State.tuned reset (initial value changed: 1 to 2)",
        "hotreload: static: game.State.widened kept (type changed: Int to Float)",
    ],
}


def fresh_sources():
    """src/game/ as v1 has it, and Outside.hx as it was"""
    shutil.rmtree(os.path.join(HERE, "src", "game"), ignore_errors=True)
    install(os.path.join(HERE, "v1"), os.path.join(HERE, "src"))
    if " // edited" in open(OUTSIDE).read():
        edit(OUTSIDE, " // edited", "")


def scenario(p, logs):
    """the edits: what the program said of each. `logs`: everything written (the
    program's, and the DevServer's)"""
    result = {}
    result["v1"] = p.wait(r"^report v1")
    install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
    result["v2"] = p.wait(r"^report v2", timeout=120)
    install(os.path.join(HERE, "v3"), os.path.join(HERE, "src"))
    result["v3"] = p.wait(r"^report v3", timeout=120)
    result["statics"] = sorted(set(l.strip() for log in logs for l in open(log) if "hotreload: static:" in l))
    return result


def program():
    print("\n== the program, edited as it runs")
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server_log = os.path.join(LOGS, "js-server.log")
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"], server_log)
    p = None
    try:
        if not server.wait(r"hotreload: ready", timeout=120, show=False):
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


def warnings():
    """the warn/ program's build: what the compiler warned about, one line per use of a
    method as a value"""
    print("\n== warnings")
    os.makedirs(os.path.join(HERE, "out", "warn"), exist_ok=True)
    output = ["--js", "out/warn/main.js"]
    r = subprocess.run(["haxe", "-cp", "warn", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload", "--no-output"] + output,
                       cwd=HERE, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("the warn/ build failed:\n" + r.stderr)
    lines = sorted(l.strip() for l in r.stderr.splitlines() if "Warning" in l and "hotreload:" in l)
    for l in lines:
        print("    | " + l)
    return lines


def order():
    """the order/ program's build: the errors it failed with, or none"""
    print("\n== build order")
    os.makedirs(os.path.join(HERE, "out", "order"), exist_ok=True)
    output = ["--js", "out/order/main.js"]
    r = subprocess.run(["haxe", "-cp", "order", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload", "--no-output"] + output,
                       cwd=HERE, capture_output=True, text=True)
    errors = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l] if r.returncode != 0 else []
    for l in errors:
        print("    | " + l)
    return errors


def own():
    """the order/ program built from the repository's root with -cp src, which makes
    hotreload-hx's src/ one of the project's class paths: the hotreload warnings about its
    own files (there should be none), or the errors it failed with"""
    print("\n== hotreload-hx's src/ as a project class path")
    root = os.path.normpath(os.path.join(HERE, "..", ".."))
    output = ["--js", "tests/behavior/out/own/main.js"]
    r = subprocess.run(["haxe", "-cp", "src", "-cp", "tests/behavior/order", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload",
                        "--no-output"] + output, cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        lines = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l]
    else:
        lines = [l.strip() for l in r.stderr.splitlines() if "hotreload:" in l and "src/hotreload/" in l]
    for l in lines:
        print("    | " + l)
    return lines


def local_repo():
    """localrepo/ built as a project with its own repository (.haxelib/, as haxelib newrepo
    makes it), hotreload-hx in it as haxelib dev puts it, and localrepo/lib/ installed in it
    as locallib: what's wrong, if anything (the library's directory among the project's,
    a hotreload warning, or the build failing)"""
    print("\n== a library in the project's own repository")
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
    output = ["--js", "out/main.js"]
    r = subprocess.run(["haxe", "-cp", "src", "-lib", "locallib", "-lib", "hotreload-hx", "--main", "Main", "-D", "hotreload",
                        "-D", f"hotreload_config={config}"] + output, cwd=work, capture_output=True, text=True)
    wrong = []
    if r.returncode != 0:
        wrong = [l.strip() for l in r.stderr.splitlines() if "Warning" not in l]
    else:
        wrong = [l.strip() for l in r.stderr.splitlines() if "hotreload:" in l]
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
                if "@:hot is deprecated" in l:
                    warned = True
            if any("hotreload: ready" in l for l in lines):
                return warned
            time.sleep(0.02)
        print("    !! timed out waiting for hotreload: ready")
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
        if not server.wait(r"hotreload: ready", timeout=120):
            return False
        edit(os.path.join(work, "common.hxml"), "-cp src", "-cp src\n-cp extra")
        if not server.wait(r"hotreload: build: (done|failed)", timeout=60):
            return False
        if "hotreload: watch: including src/, extra/" not in open(server.log).read():
            print("    !! extra/ isn't watched")
            return False
        edit(os.path.join(work, "src", "Use.hx"), '"v1"', 'Extra.hi()')
        return (server.wait(r"hotreload: build: (done|failed)", timeout=60) or "").startswith("hotreload: build: done")
    finally:
        server.stop()


def dev_watch():
    """a copy of watch/: the DevServer building app/, which uses ../lib, a library outside
    it, told to watch it too (--watch ../lib): whether it said so, and an edit to the
    library was built"""
    print("\n== a library's directory watched too, not the project's")
    work = os.path.join(HERE, "out", "watch")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "watch"), work)
    app = os.path.join(work, "app")
    lib = os.path.join(work, "lib")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(app, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "--watch", "../lib",
                           "build.hxml"], os.path.join(LOGS, "dev-watch.log"))
    try:
        if not server.wait(r"hotreload: ready", timeout=120):
            return False
        if "hotreload: watch: including src/, ../lib/" not in open(server.log).read():
            print("    !! ../lib/ isn't said to be watched")
            return False
        edit(os.path.join(lib, "Lib.hx"), '"v1"', '"v2"')
        return (server.wait(r"hotreload: build: (done|failed)", timeout=60) or "").startswith("hotreload: build: done")
    finally:
        server.stop()


def dev_bind():
    """a copy of bind/ served and run in node, listeners added before a reload as a bound
    method (OpenFL's addEventListener(CLICK, onClick)) and a static function: whether after
    each of two reloads they run the new code, and the new code removes them. Its lines, or None"""
    print("\n== a bound method passed as a value, across a reload (JS)")
    work = os.path.join(HERE, "out", "bind")
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "bind"), work)
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(work, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"],
                     os.path.join(LOGS, "dev-bind-server.log"))
    p = None
    try:
        if not server.wait(r"hotreload: ready", timeout=120, show=False):
            return None
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        p = Program(work, ["node", "out/main.js"], os.path.join(LOGS, "dev-bind.log"), env=env)
        if not p.wait(r"^click v1", timeout=30):
            return None
        # two reloads: the second's listener was added by the first reload's code
        for v in ["v2", "v3"]:
            was = {"v2": "v1", "v3": "v2"}[v]
            button = os.path.join(work, "src", "Button.hx")
            text = open(button).read()
            save(button, text.replace(f'"click {was}"', f'"click {v}"').replace(f'"tick {was}"', f'"tick {v}"'))
            if not p.wait(r"^removed=", timeout=60):
                return None
        # (lines can come together in one read: taken from the log)
        return [l for l in open(p.log).read().splitlines() if l.startswith(("click v", "tick v", "removed="))]
    finally:
        if p:
            p.stop()
        server.stop()


def served_edit(name, edit_to, wait_first, prefixes):
    """a copy of name/ served with hotreload.DevServer and run in node, until it says
    wait_first, then edit_to(src) edits its sources, once: its lines with the prefixes, from
    the start to the reload's end, or None"""
    work = os.path.join(HERE, "out", name)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, name), work)
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(work, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"],
                     os.path.join(LOGS, f"dev-{name}-server.log"))
    p = None
    try:
        if not server.wait(r"hotreload: ready", timeout=120, show=False):
            return None
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        p = Program(work, ["node", "out/main.js"], os.path.join(LOGS, f"dev-{name}.log"), env=env)
        if not p.wait(wait_first, timeout=30):
            return None
        edit_to(os.path.join(work, "src"))
        # (what the main class's afterReload says comes before reload: done)
        if not p.wait(r"^hotreload: reload: done", timeout=60):
            return None
        return [l for l in open(p.log).read().splitlines() if l.startswith(prefixes)]
    finally:
        if p:
            p.stop()
        server.stop()


def dev_enums():
    """enums/, edited once: a constructor put before the others, and a static's first value
    edited to an enum constant. Whether enum values a closure holds (which the reload
    doesn't walk to) still match their cases and compare equal to the new code's
    constants, as do the walked and the new ones. Its lines, or None"""
    print("\n== enum values across a reload that reorders their constructors (JS)")

    def edit_to(src):
        game = os.path.join(src, "Game.hx")
        text = open(game).read()
        save(game, text.replace("enum Mood {\n\tHappy;", "enum Mood {\n\tCalm;\n\tHappy;").replace("edited:Mood = Happy", "edited:Mood = Sad"))

    return served_edit("enums", edit_to, r"^enums ", ("enums ", "hotreload: enum:"))


def dev_code():
    """code/, edited once in what a reload cannot bring in: main, a closure main made, the
    constructor of an object made before, a field initializer, a field's type, and a field
    renamed. Its
    lines: the reload's messages, sorted, and what the program says, or None"""
    print("\n== what a reload cannot bring in, said (JS)")

    def edit_to(src):
        main = os.path.join(src, "Main.hx")
        text = open(main).read()
        for old, new in [("\t\tenemy = new Enemy();\n", "\t\tenemy = new Enemy();\n\t\tsay(\"main v2\");\n"),
                         ('"tick v1"', '"tick v2"'), ("hp = 3;", "hp = 4;"), ("var hp:Int;", "var hp:Float;"), ("shield = 10;", "shield = 20;"),
                         ("var mana = 5;", "var energy = 5;")]:
            assert old in text, old
            text = text.replace(old, new)
        save(main, text)

    lines = served_edit("code", edit_to, r"^code ", ("code ", "hotreload: main:", "hotreload: constructor:", "hotreload: field:", "hotreload: closure:"))
    if lines is None:
        return None
    return sorted(l for l in lines if l.startswith("hotreload:")) + [l for l in lines if not l.startswith("hotreload:")]


def server():
    """the program built through a compilation server, as the DevServer and an editor do:
    four builds, the later ones from the server's cache, into an output directory that
    isn't there yet. Each build's hotreload warnings: a build whose main class came from
    the cache says nothing about its calls"""
    print("\n== compilation server")
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
        output = ["--js", "out/server/main.js"]
        results = []
        for reload in [False, False, True, True]:
            extra = ["-D", "hotreload_reload"] if reload else []
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
    "warn/Warn.hx:6: characters 2-7 : Warning : hotreload: @:hot is deprecated: every static is kept now. Remove it, or use @:resetOnHotReload to reset a static on every reload.",
])


# the listener's lines: before the reloads, then after each one, the new code's, and removed by it
DEV_BIND = ["click v1", "tick v1", "click v2", "tick v2", "removed=true listeners=0",
            "click v3", "tick v3", "removed=true listeners=0"]

# the enum test's lines: before the reload, the moved constructor with arguments, and after.
# The captured Angry(3) matches Sad's case: a value with arguments the reload doesn't reach
# can't be kept, only said
DEV_ENUMS = ["enums held=sad captured=sad angry3 true edited=happy false",
             "hotreload: enum: Mood.Angry moved (index 2 to 3, unreached values match another case)",
             "enums held=sad captured=sad sad true edited=sad true"]

# the code-change test's lines: the reload's messages, sorted, then the program's, before and
# after. The program's are the same: none of the edits reaches what was already made
DEV_CODE = ["hotreload: closure: src/Main.hx:15 changed (in Main.main, ones made before the reload run the old body)",
            "hotreload: constructor: Enemy changed (existing objects not constructed again)",
            "hotreload: field: Enemy.hp type changed (Int to Float, existing objects keep their values)",
            "hotreload: field: Enemy.mana removed, Enemy.energy added (values not moved)",
            "hotreload: field: Enemy.shield initializer changed (existing objects keep their values)",
            "hotreload: main: Main.main changed (not run again); use an @:afterHotReload hook",
            "code tick v1 hp=3 shield=10", "code tick v1 hp=3 shield=10"]


def check(name, result):
    """what the test found, against what's expected"""
    failures = 0
    for key in EXPECTED:
        if result[key] != EXPECTED[key]:
            print(f"  FAILED {name}, {key}: {result[key]!r}, expected {EXPECTED[key]!r}")
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
    if "dev_bind" in result and result["dev_bind"] != DEV_BIND:
        print(f"  FAILED {name}, a bound method across reloads: {result['dev_bind']!r}, expected {DEV_BIND!r}")
        failures += 1
    if "dev_enums" in result and result["dev_enums"] != DEV_ENUMS:
        print(f"  FAILED {name}, enum values across a reload: {result['dev_enums']!r}, expected {DEV_ENUMS!r}")
        failures += 1
    if "dev_code" in result and result["dev_code"] != DEV_CODE:
        print(f"  FAILED {name}, what a reload cannot bring in: {result['dev_code']!r}, expected {DEV_CODE!r}")
        failures += 1
    if result.get("dev_watch") is False:
        print(f"  FAILED {name}: the DevServer didn't watch and build a directory it was told to watch")
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
    result = program()
    result["warnings"] = warnings()
    result["order"] = order()
    result["own"] = own()
    result["local_repo"] = local_repo()
    result["dev_output"] = dev_output()
    result["dev_relist"] = dev_relist()
    result["dev_watch"] = dev_watch()
    result["dev_bind"] = dev_bind()
    result["dev_enums"] = dev_enums()
    result["dev_code"] = dev_code()
    result["server"] = server()
    print("\n== results")
    failures = check("js", result)
    print("\nall passed" if failures == 0 else f"\n{failures} failed")
    sys.exit(1 if failures else 0)
