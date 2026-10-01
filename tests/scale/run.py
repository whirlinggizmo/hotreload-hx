#!/usr/bin/env python3
"""How reload time grows with the size of the application: generates a program of N
classes (or Nim modules), builds it hot, runs it, and times a one-line edit to the hot
code and one to the deepest class, which everything depends on. The output is read by
hand; nothing here passes or fails on its own.

    python3 tests/scale/run.py                       every kind, at 100, 1000 and 3000
    python3 tests/scale/run.py hx-all hx-small --sizes 100,1000
    python3 tests/scale/run.py nim --nim ../hotreload-nim

The kinds:
    hx-all    hxcpp, every class in the reloaded code (src/game/)
    hx-small  hxcpp, the classes in src/lib/, compiled into the executable; only Game in
              the reloaded code
    js        JS in node, through hotreload.DevServer (the whole bundle is rebuilt)
    nim       hotreload-nim, the modules imported by game.nim, which are all reloaded
"""
import argparse, os, re, shutil, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "matrix"))
from drive import save

GEN = os.path.join(HERE, "gen")
LOGS = os.path.join(HERE, "logs")
EDITS = 3


def deps(i, n):
    """the classes C<i> refers to: always later ones, so Nim's imports have no cycle"""
    return sorted({j for j in (i + 1, i + 2 + (i * 7) % 11) if j < n})


# --- Haxe ----------------------------------------------------------------------------

def hx_class(pkg, i, n):
    d = deps(i, n)
    imports = "".join(f"import {pkg}.C{j};\n" for j in d)
    fields = "".join(f"\tvar link{j}:C{j};\n" for j in d)
    links = "".join(f"\t\tlink{j} = new C{j}();\n" for j in d)
    return f"""package {pkg};

{imports}
typedef C{i}Point = {{x:Float, y:Float}};

enum C{i}Kind {{
	Small;
	Big(size:Int);
	Named(name:String, weight:Float);
}}

class C{i} {{
	public var x:Float;
	public var items:Array<Int>;
	public var name:String;
	public var kind:C{i}Kind;
	var points:Array<C{i}Point>;
	var lookup:Map<String, Int>;
{fields}
	public function new() {{
		x = {i};
		items = [for (k in 0...4) k * {i % 13 + 1}];
		name = "c{i}";
		kind = {i} % 2 == 0 ? Big({i}) : Named(name, 0.5);
		points = [{{x: 1, y: 2}}, {{x: 3, y: 4}}];
		lookup = ["a" => 1, "b" => 2];
	}}

	public function link() {{
{links}	}}

	public function step(dt:Float):Float {{
		var s = x;
		for (v in items)
			s += v * dt;
		for (p in points)
			s += p.x * p.y;
		s += switch kind {{
			case Small: 1;
			case Big(size): size * 0.5;
			case Named(_, weight): weight;
		}}
		x = s % 1000;
		return x;
	}}

	public function describe():String {{
		var parts = [for (k => v in lookup) k + "=" + v];
		parts.sort(Reflect.compare);
		return name + "(" + parts.join(",") + ")";
	}}

	public static function mix(a:Int, b:Int):Int {{
		var h = a * 31 + b;
		for (k in 0...3)
			h = (h ^ (h >> 3)) + k;
		var f = (v:Int) -> v & 0xffff;
		return f(h);
	}}

	public static function tag():String {{
		return "d0";
	}}
}}
"""


def hx_game(pkg, n):
    return f"""package game;

import {pkg}.C0;
import {pkg}.C{n - 1};

class Game {{
	@:hot static var seen = "";
	@:hot static var total = 0;

	@:hot public static function tick() {{
		var v = "version v0 " + C{n - 1}.tag();
		if (v != seen) {{
			seen = v;
			Sys.println(v);
		}}
		total += C0.mix(3, 4);
	}}
}}
"""


HX_MAIN = """class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		while (true) {
			reloader.update();
			game.Game.tick();
			Sys.sleep(0.02);
		}
	}
}
"""

JS_MAIN = """class Main {
	static function main() {
		new hotreload.Reloader();
		js.Syntax.code("setInterval({0}, 20)", () -> game.Game.tick());
	}
}
"""

JS_SYS = """class Sys {
	public static function println(v:Dynamic)
		js.Syntax.code("console.log({0})", Std.string(v));
}
"""


def gen_hx(kind, n):
    """the program's directory: src/Main.hx, src/game/Game.hx, and the classes"""
    root = os.path.join(GEN, f"{kind}-{n}")
    if os.path.isdir(root):
        shutil.rmtree(root)
    pkg = "lib" if kind == "hx-small" else "game"
    os.makedirs(os.path.join(root, "src", pkg), exist_ok=True)
    os.makedirs(os.path.join(root, "src", "game"), exist_ok=True)
    for i in range(n):
        save(os.path.join(root, "src", pkg, f"C{i}.hx"), hx_class(pkg, i, n))
    save(os.path.join(root, "src", "game", "Game.hx"), hx_game(pkg, n))
    if kind == "js":
        os.makedirs(os.path.join(root, "js"))
        save(os.path.join(root, "js", "Main.hx"), JS_MAIN)
        save(os.path.join(root, "js", "Sys.hx"), JS_SYS)
        save(os.path.join(root, "build.hxml"),
             "-cp src\n-cp js\n-lib hotreload-hx\n--main Main\n--js out/js/main.js\n-D js-es=6\n")
    else:
        save(os.path.join(root, "src", "Main.hx"), HX_MAIN)
        save(os.path.join(root, "build.hxml"),
             "-cp src\n-lib hotreload-hx\n--main Main\n-D hotreload\n-debug\n--cpp out/hot\n")
    return root, os.path.join(root, "src", "game", "Game.hx"), os.path.join(root, "src", pkg, f"C{n - 1}.hx")


# --- Nim -----------------------------------------------------------------------------

def nim_module(i, n):
    d = deps(i, n)
    imports = "import std/[tables, algorithm, strutils, math]\n" + "".join(f"import ./c{j}\n" for j in d)
    fields = "".join(f"    link{j}*: C{j}\n" for j in d)
    links = "".join(f"  c.link{j} = newC{j}()\n" for j in d) or "  discard\n"
    return f"""{imports}
type
  C{i}Point* = object
    x*, y*: float
  C{i}KindTag* = enum c{i}Small, c{i}Big, c{i}Named
  C{i}Kind* = object
    case tag*: C{i}KindTag
    of c{i}Small: discard
    of c{i}Big: size*: int
    of c{i}Named:
      name*: string
      weight*: float
  C{i}* = ref object
    x*: float
    items*: seq[int]
    name*: string
    kind*: C{i}Kind
    points: seq[C{i}Point]
    lookup: Table[string, int]
{fields}
proc newC{i}*(): C{i} =
  result = C{i}(x: {i}.0, name: "c{i}", points: @[C{i}Point(x: 1, y: 2), C{i}Point(x: 3, y: 4)],
              lookup: {{"a": 1, "b": 2}}.toTable)
  for k in 0 ..< 4: result.items.add k * {i % 13 + 1}
  result.kind = if {i} mod 2 == 0: C{i}Kind(tag: c{i}Big, size: {i}) else: C{i}Kind(tag: c{i}Named, name: result.name, weight: 0.5)

proc link*(c: C{i}) =
{links}
proc step*(c: C{i}, dt: float): float =
  var s = c.x
  for v in c.items: s += v.float * dt
  for p in c.points: s += p.x * p.y
  s += (case c.kind.tag
        of c{i}Small: 1.0
        of c{i}Big: c.kind.size.float * 0.5
        of c{i}Named: c.kind.weight)
  c.x = s mod 1000
  c.x

proc describe*(c: C{i}): string =
  var parts: seq[string]
  for k, v in c.lookup: parts.add k & "=" & $v
  parts.sort()
  c.name & "(" & parts.join(",") & ")"

proc mixC{i}*(a, b: int): int =
  var h = a * 31 + b
  for k in 0 ..< 3: h = (h xor (h shr 3)) + k
  let f = proc (v: int): int = v and 0xffff
  f(h)

proc tagC{i}*(): string = "d0"
"""


def nim_game(n):
    return f"""import hotreload
import ./c0, ./c{n - 1}

var seen {{.hot.}} = ""
var total {{.hot.}} = 0

proc tick*() {{.hot.}} =
  let v = "version v0 " & tagC{n - 1}()
  if v != seen:
    seen = v
    echo v
  total += mixC0(3, 4)
"""


NIM_MAIN = """import std/os
import hotreload
import ./game

let reloader = newReloader()
while true:
  reloader.update()
  tick()
  sleep(20)
"""


def gen_nim(n, hotreload_nim):
    root = os.path.join(GEN, f"nim-{n}")
    if os.path.isdir(root):
        shutil.rmtree(root)
    src = os.path.join(root, "src")
    os.makedirs(src)
    for i in range(n):
        save(os.path.join(src, f"c{i}.nim"), nim_module(i, n))
    save(os.path.join(src, "game.nim"), nim_game(n))
    save(os.path.join(src, "main.nim"), NIM_MAIN)
    save(os.path.join(root, "config.nims"), f'switch("path", "{os.path.join(hotreload_nim, 'src')}")\n')
    return root, os.path.join(src, "game.nim"), os.path.join(src, f"c{n - 1}.nim")


# --- running -------------------------------------------------------------------------

class Log:
    """a program's output, each line with the time it was seen"""
    def __init__(self, cwd, argv, path, env=None):
        self.path = path
        self.out = open(path, "w")
        self.p = subprocess.Popen(argv, cwd=cwd, stdout=self.out, stderr=subprocess.STDOUT, env=env)
        self.pos = 0
        self.buf = ""

    def wait(self, pattern, timeout):
        """the time of the first new line matching, or None"""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while time.time() < deadline:
            with open(self.path, "rb") as f:
                f.seek(self.pos)
                data = f.read()
            self.pos += len(data)
            self.buf += data.decode(errors="replace")
            now = time.time()
            *lines, self.buf = self.buf.split("\n")
            for i, l in enumerate(lines):
                if rx.search(l):
                    self.buf = "\n".join(lines[i + 1:] + [self.buf])
                    return now, l
            if self.p.poll() is not None:
                print(f"    !! the program stopped ({self.path})")
                return None, None
            time.sleep(0.01)
        print(f"    !! timed out waiting for {pattern} ({self.path})")
        return None, None

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(5)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self.out.close()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def timed(argv, cwd, log):
    t = time.time()
    with open(log, "w") as f:
        code = subprocess.run(argv, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).returncode
    if code != 0:
        sys.exit(f"the build failed: see {log}")
    return time.time() - t


def edit_and_wait(prog, builder, path, old, new, expect, timeout):
    """saves the edit; returns (save to new code running, build start to new code running)"""
    text = open(path).read()
    assert old in text, f"{path} has no {old!r}"
    t0 = time.time()
    save(path, text.replace(old, new))
    tb, _ = builder.wait(r"hotreload: building", timeout)
    tr, _ = prog.wait(re.escape(expect), timeout)
    if tb is None or tr is None:
        return None
    return tr - t0, tr - tb


def measure(kind, n, args):
    tag = f"{kind}-{n}"
    print(f"\n== {tag}: generating")
    if kind == "nim":
        root, game, deep = gen_nim(n, args.nim)
    else:
        root, game, deep = gen_hx(kind, n)
    print(f"   building")
    blog = os.path.join(LOGS, f"{tag}-build.log")
    server = None
    if kind == "nim":
        exe = os.path.join(root, "out", "main")
        full = timed(["nim", "c", "-d:hotReload", "-d:useMalloc", "--debugger:native", "--hints:off",
                      f"--out:{exe}", os.path.join(root, "src", "main.nim")], root, blog)
    elif kind == "js":
        full = timed(["haxe", "build.hxml"], root, blog)  # the dev server builds it again; this times one build
    else:
        full = timed(["haxe", "build.hxml"], root, blog)
    print(f"   full build {full:.1f} s; running")

    if kind == "js":
        port = free_port()
        server = Log(root, ["haxe", "-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", str(port), "build.hxml"],
                     os.path.join(LOGS, f"{tag}-server.log"))
        if server.wait(r"hotreload: serving", args.timeout)[0] is None:
            sys.exit("the DevServer didn't start")
        env = dict(os.environ, HOTRELOAD_URL=f"http://127.0.0.1:{port}/__hotreload")
        prog = Log(root, ["node", "out/js/main.js"], os.path.join(LOGS, f"{tag}.log"), env=env)
        builder = server
    else:
        exe = os.path.join(root, "out", "main") if kind == "nim" else os.path.join(root, "out", "hot", "Main-debug")
        prog = Log(root, [exe], os.path.join(LOGS, f"{tag}.log"))
        builder = prog

    result = {"kind": kind, "n": n, "full": full, "first": None, "game": [], "deep": []}
    try:
        if prog.wait(r"version v0 d0", args.timeout)[0] is None:
            return result
        time.sleep(1.5)
        v, d = 0, 0
        plan = [("first", game)] + [("game", game)] * EDITS + ([("deep", deep)] * EDITS if kind != "hx-small" else [])
        for what, path in plan:
            if path == game:
                old, v = f'"version v{v} ', v + 1
                new = f'"version v{v} '
            else:
                old, d = f'"d{d}"', d + 1
                new = f'"d{d}"'
            r = edit_and_wait(prog, builder, path, old, new, f"version v{v} d{d}", args.timeout)
            if r is None:
                print(f"   {what}: no reload")
                break
            print(f"   {what}: save to running {r[0]:.2f} s, build + swap {r[1]:.2f} s")
            if what == "first":
                result["first"] = r
            else:
                result[what].append(r)
            time.sleep(1.5)
    finally:
        prog.stop()
        if server:
            server.stop()
    return result


def span(rs, k):
    if not rs:
        return "-"
    xs = [r[k] for r in rs]
    lo, hi = min(xs), max(xs)
    return f"{lo:.2f}" if f"{lo:.2f}" == f"{hi:.2f}" else f"{lo:.2f}–{hi:.2f}"


def table(results):
    lines = ["| Kind | Classes | Full build | First reload (save → running) | Edit Game: build + swap | Edit Game: save → running | Edit the deepest class: build + swap | Edit the deepest class: save → running |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for r in results:
        first = f"{r['first'][0]:.2f} s" if r["first"] else "-"
        lines.append(f"| {r['kind']} | {r['n']} | {r['full']:.1f} s | {first} | {span(r['game'], 1)} s | {span(r['game'], 0)} s"
                     f" | {span(r['deep'], 1)} s | {span(r['deep'], 0)} s |")
    return "\n".join(lines)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("kinds", nargs="*", default=["hx-all", "hx-small", "js", "nim"])
    ap.add_argument("--sizes", default="100,1000,3000")
    ap.add_argument("--nim", default=os.path.join(HERE, "..", "..", "..", "hotreload-nim"),
                    help="a checkout of hotreload-nim")
    ap.add_argument("--timeout", type=float, default=900)
    args = ap.parse_args()
    args.nim = os.path.abspath(args.nim)
    os.makedirs(LOGS, exist_ok=True)
    results = []
    for n in [int(s) for s in args.sizes.split(",")]:
        for kind in args.kinds:
            results.append(measure(kind, n, args))
    out = table(results)
    print("\n" + out)
    save(os.path.join(LOGS, "scale.md"), out + "\n")
