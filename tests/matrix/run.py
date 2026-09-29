#!/usr/bin/env python3
"""The capability matrix behind docs/comparison.md: runs a hot program, edits it while it
runs, and shows what each reload did. The output is read by hand; nothing here passes or
fails on its own.

    python3 tests/matrix/run.py            both parts
    python3 tests/matrix/run.py matrix     S1-S15, S17, S18: one program, edited in turn
    python3 tests/matrix/run.py perf       S16: the speed of reloaded code
    python3 tests/matrix/run.py js         the same scenarios for JS, in node, through
                                           hotreload.DevServer
"""
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from drive import Program, edit, install, save

LOGS = os.path.join(HERE, "logs")


def step(name):
    print("\n== " + name)


def build(cwd, args):
    print(f"building {' '.join(args)} in {os.path.relpath(cwd, HERE) or '.'}")
    if subprocess.run(["haxe"] + args, cwd=cwd, stdout=subprocess.DEVNULL).returncode != 0:
        sys.exit("the build failed")


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
    fresh_sources()
    build(HERE, ["build.hxml"])
    game = os.path.join(HERE, "src", "Game.hx")
    p = Program(HERE, ["./out/hot/Main-debug"], os.path.join(LOGS, "matrix.log"))
    try:
        step("v1, as built")
        p.wait(r"^report v1")

        step("v2: S1-S5, S7-S12, S14 at once (see v2/)")
        install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
        p.wait(r"^report v2|build failed")
        time.sleep(1.2)
        held = [l for l in open(os.path.join(LOGS, "matrix.log")) if l.startswith("main:")]
        print("    | " + held[-1].strip() + "   (S10, S14: kept by the main class)")

        step("S6: a hot static's type, Int -> String")
        edit(game, "@:hot static var label = 7;", '@:hot static var label = "seven";')
        p.wait(r"^report v2|build failed")

        step("S13: a @:hot function's signature, then back")
        edit(game, "@:hot public static function tick()", "@:hot public static function tick(n:Int = 1)")
        p.wait(r"signature changed|reloaded|build failed")
        edit(game, "@:hot public static function tick(n:Int = 1)", "@:hot public static function tick()")
        p.wait(r"^report v2|build failed")

        step("S15: a compile error, then the fix")
        edit(game, "static function report() {", "static function report() { oops")
        p.wait(r"build failed|reloaded")
        edit(game, "static function report() { oops", "static function report() {")
        p.wait(r"^report v2|build failed")

        step("S17: a C call through untyped __cpp__")
        line = "\n\t\tSys.println('S17=' + untyped __cpp__('abs(-3)'));"
        edit(game, "static function report() {", "static function report() {" + line)
        p.wait(r"^report v2|build failed|can't load|failed as it started")
        edit(game, line, "")
        p.wait(r"^report v2|build failed")

        step("S17b: a C function through an extern the executable never used")
        save(os.path.join(HERE, "src", "game", "CMath.hx"),
             'package game;\n\n@:include("stdlib.h")\nextern class CMath {\n\t@:native("abs") static function abs(x:Int):Int;\n}\n')
        line = "\n\t\tSys.println('S17b=' + game.CMath.abs(-3));"
        edit(game, "static function report() {", "static function report() {" + line)
        p.wait(r"^report v2|build failed|can't load|failed as it started")
        edit(game, line, "")
        p.wait(r"^report v2|build failed")

        step("S18: haxe.Json (pure Haxe), which the executable never used")
        line = "\n\t\tSys.println('S18=' + haxe.Json.parse('{\"a\":[1,2]}').a[1]);"
        edit(game, "static function report() {", "static function report() {" + line)
        p.wait(r"^S18=|build failed|can't load|failed as it started")

        step("S18b: sys.db.Sqlite (native), which the executable never used")
        edit(game, line, "\n\t\tSys.println('S18b=' + sys.db.Sqlite.open(':memory:').request('select 6*7 as x').getIntResult(0));")
        p.wait(r"^S18b=|build failed|can't load|failed as it started")
    finally:
        p.stop()
        fresh_sources()


def perf():
    perf_dir = os.path.join(HERE, "perf")
    bench = os.path.join(perf_dir, "src", "Bench.hx")
    for out, exe, flags, name in [("out/hotdebug", "Main-debug", ["-debug"], "-debug (cppia interpreted)"),
                                  ("out/hotrelease", "Main", [], "no -debug (cppia JIT)")]:
        step("S16: " + name)
        build(perf_dir, ["common.hxml"] + flags + ["--cpp", out])
        p = Program(perf_dir, [f"./{out}/{exe}"], os.path.join(LOGS, "perf.log"))
        try:
            p.wait(r"^bench native", timeout=120)
            for _ in range(2):
                edit(bench, "@:hot static var dummy = 0;", "@:hot static var dummy = 0; ")
                p.wait(r"^bench reloaded|build failed", timeout=300)
        finally:
            p.stop()
            edit(bench, "@:hot static var dummy = 0;  ", "@:hot static var dummy = 0;")


def js():
    """the matrix for JS: the DevServer builds and serves it, node runs it"""
    import socket
    fresh_sources()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = Program(HERE, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build-js.hxml"],
                     os.path.join(LOGS, "js-server.log"))
    game = os.path.join(HERE, "src", "Game.hx")
    p = None
    try:
        if not server.wait(r"hotreload: serving", timeout=120, show=False):
            sys.exit("the DevServer didn't start")
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        p = Program(HERE, ["node", "out/js/main.js"], os.path.join(LOGS, "js.log"), env=env)
        step("v1, as built")
        p.wait(r"^report v1")

        step("v2: S1-S5, S7-S12, S14 at once (see v2/)")
        install(os.path.join(HERE, "v2"), os.path.join(HERE, "src"))
        p.wait(r"^report v2")
        time.sleep(1.2)
        held = [l for l in open(os.path.join(LOGS, "js.log")) if l.startswith("main:")]
        print("    | " + held[-1].strip() + "   (S10, S14: kept by the main class)")

        step("S6: a hot static's type, Int -> String")
        edit(game, "@:hot static var label = 7;", '@:hot static var label = "seven";')
        p.wait(r"^report v2")

        step("S13: a @:hot function's signature")
        edit(game, "@:hot public static function tick()", "@:hot public static function tick(n:Int = 1)")
        p.wait(r"^report v2|reloaded")

        step("S15: a compile error, then the fix (the terminal has the error)")
        edit(game, "static function report() {", "static function report() { oops")
        server.wait(r"build failed", timeout=30)
        edit(game, "static function report() { oops", "static function report() {")
        p.wait(r"^report v2")

        step("S18: haxe.Json, which the first build didn't use")
        line = "\n\t\tSys.println('S18=' + haxe.Json.parse('{\"a\":[1,2]}').a[1]);"
        edit(game, "static function report() {", "static function report() {" + line)
        p.wait(r"^S18=")
    finally:
        if p:
            p.stop()
        server.stop()
        fresh_sources()


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    what = sys.argv[1:] or ["matrix", "perf", "js"]
    if "matrix" in what:
        matrix()
    if "perf" in what:
        perf()
    if "js" in what:
        js()
