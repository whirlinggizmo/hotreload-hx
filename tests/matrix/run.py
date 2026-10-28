#!/usr/bin/env python3
"""The capability matrix: a hot program, served with hotreload.DevServer and run in node,
edited while it runs, showing what each reload did. The output is read by hand. Nothing
here passes or fails on its own.

    python3 tests/matrix/run.py
"""
import os, shutil, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from drive import Program, edit, install, save

LOGS = os.path.join(HERE, "logs")


def step(name):
    print("\n== " + name)


def fresh_sources():
    """src/ as v1 has it, beside Main.hx"""
    for name in ["Game.hx", "game"]:
        path = os.path.join(HERE, "src", name)
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)
    install(os.path.join(HERE, "v1"), os.path.join(HERE, "src"))


def matrix():
    """the DevServer builds and serves it, node runs it"""
    import socket
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"],
                     os.path.join(LOGS, "server.log"))
    game = os.path.join(HERE, "src", "Game.hx")
    p = None
    try:
        if not server.wait(r"hotreload: ready", timeout=120, show=False):
            sys.exit("the DevServer didn't start")
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        p = Program(HERE, ["node", "out/js/main.js"], os.path.join(LOGS, "matrix.log"), env=env)
        step("v1, as built")
        p.wait(r"^report v1")

        step("v2: S1-S5, S7-S12, S14 at once (see v2/)")
        install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
        p.wait(r"^report v2")
        time.sleep(1.2)
        held = [l for l in open(os.path.join(LOGS, "matrix.log")) if l.startswith("main:")]
        print("    | " + held[-1].strip() + "   (S10, S14: kept by the main class)")

        step("S6: a static's first value and type, 7 -> \"seven\"")
        edit(game, "static var label = 7;", 'static var label = "seven";')
        p.wait(r"^report v2")

        step("S13: a function's signature")
        edit(game, "public static function tick()", "public static function tick(n:Int = 1)")
        p.wait(r"^report v2|reload: done")

        step("S15: a compile error, then the fix (the terminal has the error)")
        edit(game, "static function report() {", "static function report() { oops")
        server.wait(r"build: failed", timeout=30)
        edit(game, "static function report() { oops", "static function report() {")
        p.wait(r"^report v2")

        step("S18: haxe.Json, which the first build didn't use")
        line = "\n\t\tSys.println('S18=' + haxe.Json.parse('{\"a\":[1,2]}').a[1]);"
        edit(game, "static function report() {", "static function report() {" + line)
        p.wait(r"^S18=")

        step("an asset the DevServer serves, saved: told to assetsChanged by its URL, once")
        save(os.path.join(HERE, "out", "js", "note.txt"), "one")
        p.wait(r"^main: assetsChanged /note\.txt$")
    finally:
        if p:
            p.stop()
        server.stop()
        fresh_sources()
        note = os.path.join(HERE, "out", "js", "note.txt")
        if os.path.exists(note):
            os.remove(note)


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    matrix()
