# hotreload-hx

Hot reload for Haxe applications. When you save a change, hotreload rebuilds the code in
the background and swaps it into the running application, keeping its state. It's for
applications with a loop, such as a game or a windowed tool, where a restart would cost you
the window, the loaded assets and where you were. Debug, release and web builds compile the
same code with no reloading and no cost.

It's the Haxe side of [hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim). On
hxcpp, the reloaded code is built as a cppia module and run by the executable's cppia host.
On JS, the whole bundle is rebuilt and the running page takes on its classes (see
[JavaScript](#javascript)).

## Requirements

- Haxe 4.3+
- hxcpp (stock works, 4.3.2 or later) and a C++ toolchain (gcc or clang; MSVC or MinGW on
  Windows)
- `haxe` on the `PATH` while the application runs, since it builds each reload
- To debug reloaded hxcpp code: forks of hxcpp and hxcpp-debugger (see [Debugging](#debugging))

Only Linux is tested so far.

## Install

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

or, from a clone, `haxelib dev hotreload-hx <clone>`.

## Quick start

An application has a main class, compiled into the executable and never reloaded, and the
classes it calls into, which are reloaded. The main class calls `reloader.update()` in its
loop:

```haxe
// src/Main.hx
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		Game.init();
		while (true) {
			reloader.update(); // watches, builds and swaps
			Game.tick();
		}
	}
}
```

The reloaded classes mark what a reload needs to know: a `@:hot` static var keeps its value,
and a `@:hot` static function is one the main class calls, so its calls reach the new code:

```haxe
// src/Game.hx
class Game {
	@:hot static var score = 0;

	public static function init() { ... }
	@:hot public static function tick() { ... }
}
```

A hot build is an ordinary hxcpp build with `-D hotreload`:

```hxml
# hot.hxml
-cp src
-lib hotreload-hx
--main Main
-D hotreload
--cpp out/hot
```

While it runs, each save to `src/Game.hx` (or anything beside it) is built in the
background and swapped in at the next `update()`. `score` keeps its value, and `Game.tick()`
calls the new `tick`.

The reloaded code is every class with a `@:hot` static or a reload hook, plus every class in
the same directories and below, except the main class. Code from elsewhere (a library, an
engine) is compiled into the executable; changing it, or the main class, needs a restart.

## Trying it

`examples/hello` is a small console application:

```bash
cd examples/hello
haxe hot.hxml
```

It prints a greeting a few times a second. Change the greeting in `src/Hello.hx` and save:

```
Hello, world! (ticks: 12, since the last reload: 12)
hotreload: building (src/Hello.hx changed)
hello: reloaded
hotreload: reloaded (main_1.cppia)
Howdy, world! (ticks: 16, since the last reload: 1)
```

`ticks` is a hot static, so it keeps counting; `sinceReload` is a plain static, so it starts
over. The greeting's first word comes from `assets/greeting.txt`; edit it and the next
greeting uses it, with nothing rebuilt:

```
hotreload: assets/greeting.txt changed
hello: the greeting is now "Howdy"
```

It also has debug and release builds, with VS Code tasks and launch configurations. For a
larger program, [HeliX](https://github.com/whirlinggizmo/helix), a Haxe game framework,
develops with hotreload-hx.

## Usage

### State

A `@:hot` static var keeps its value across reloads; a plain static starts over:

```haxe
@:hot static var score = 0;
@:hot static var enemies:Array<Enemy> = [];
static var frameCount = 0; // starts over
```

The initial value is only used when the static is first created, so editing it changes
nothing while the application runs. To change a kept value, assign it, for example in an
`@:afterHotReload` hook. If a reload changes a hot static's type, its value is kept when
it's still the same kind (number, bool, string, object), and reset otherwise.

### Objects

On each reload, objects of the reloaded classes reachable from the hot statics are moved to
the new classes, field by field by name. A removed field is dropped, and a new one starts
from its initializer:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // new: starts at 10
}
```

hotreload walks arrays, maps, anonymous structures, reloaded classes' fields and reloaded
enums' values (matched by constructor name). Shared objects stay shared and cycles stay
cycles. It doesn't walk into the executable's own classes (an engine's scene, say), and an
object held only from elsewhere, such as the main class, keeps its old code.

### Functions the main class calls

The main class is compiled once, so its calls reach the code it was built with. A `@:hot`
static function is called through the reloader instead, so the main class reaches the
newest version. Only functions the main class calls after a reload can have happened need
it; `init`, or anything only reloaded code calls, is an ordinary function.

A `@:hot` function's signature can't change while the application runs: such a reload is
refused with a message, and the old code keeps running until a restart. The same goes for
adding or renaming one. Its types must be written out (or come from a default value); with
neither, a function that returns nothing is `Void`.

### Reload hooks

A reloaded class can run code just before a reload (on the old code) and just after (on the
new):

```haxe
@:beforeHotReload static function saveScratch() { ... }
@:afterHotReload static function rebuildCaches() { ... }
```

The main class uses the reloader's callbacks instead:

```haxe
reloader.beforeReload = () -> trace("reloading");
reloader.afterReload = () -> trace("reloaded");
```

The order is: old `@:beforeHotReload` hooks, `beforeReload`, the swap, new
`@:afterHotReload` hooks, `afterReload`.

A replaced module stays loaded, so a callback handed out before a reload (to an asset
loader, say) still works when it fires. It runs its old code, but on the same hot statics.

### Assets

The reloader can also watch asset directories and tell the program what changed, so it can
load it again:

```haxe
reloader.watchAssets("assets");
reloader.assetsChanged = paths -> Game.onAssetsChanged(paths);
```

Paths start with the directory as given (`assets/sounds/fire.ogg`). Nothing is rebuilt;
reloading the asset is up to the program. Deleted files are reported too; hidden files and
an editor's temporary save files aren't. The callback runs in `update()`. It belongs to the
main class, so call reloaded code through its class, as above, to reach the new version.
On JS the dev server reports URLs instead (see [JavaScript](#javascript)).

### Building

`-D hotreload` turns hot reloading on for the cpp target and sets what cppia needs:
`-D scriptable`, `-dce no` and `-D dll_export`. Without it, the same sources build an
ordinary program, which is your debug, release and web build:

```bash
haxe hot.hxml       # hot: builds out/hot and runs it
haxe debug.hxml     # debug, no hot reload
haxe release.hxml   # release
```

Each module is built by its own `haxe`, with the hot build's command line except for the
target, main class and `--cmd`, plus `-D hotreload_library`. So a hot build must be a
single build: `--next` and `--each` are refused. Modules go to `hotreload/` in the hot
build's `--cpp` directory.

### Native bindings

cppia can't run an extern call or `__cpp__`, which is what a C binding is made of. So a
module build doesn't inline library code: every `inline` function outside the reloaded
directories and the standard library becomes a call to the executable's compiled copy, where
the C++ runs. This is automatic. A binding needs two things for it to work:

- **C types only in private classes.** `-D scriptable` makes a cppia wrapper for every
  static of a public class, and a wrapper for a C pointer, struct, enum or function pointer
  doesn't compile. hotreload makes such `inline` functions `extern inline` (no wrapper); a
  non-inline one, such as a C callback, must be in a private class.
- **Compiled copies of what the reloaded code calls.** An `extern inline` function has no
  compiled copy, so if its body is C, the module fails to load with
  `Unknown static call to ...`. Haxe requires `overload` functions to be `extern inline`, so
  an overload should call a plain `inline` function that makes the C call:

  ```haxe
  public static overload extern inline function setPosition(m:Model, v:Vec3):Bool
  	return setPosition3(m, v.x, v.y, v.z);
  public static overload extern inline function setPosition(m:Model, x:Float, y:Float, z:Float):Bool
  	return setPosition3(m, x, y, z);
  static inline function setPosition3(m:Model, x:Float, y:Float, z:Float):Bool
  	return Native.model_set_position(m, x, y, z);
  ```

A binding written as inline wrappers over externs reloads at full speed.

### The compilation server

The reloader starts a Haxe compilation server (`haxe --wait` on a free local port) and
builds each module through it, so a reload only retypes what changed. The first build runs
at startup and isn't swapped in, so the first reload is quick too. In `examples/hello` a
module builds in about 0.1 s with the server and 0.3 s without.

To use your own server (your editor's, say), pass `-D hotreload_compilation_server=<port>`
or `host:port`; to build without one, `-D hotreload_no_compilation_server`. The server
stops when the application does.

## How an hxcpp reload works

Everything happens in `reloader.update()`. A few times a second it checks the reloaded
code's sources. Once a change has settled, it builds the module in the background while the
old code keeps running; compiler errors go to the terminal. The first `update()` after the
build checks the hot functions' signatures, runs the hooks, starts the module, carries the
hot statics over and points the main class's calls at the new code. So a swap never happens
in the middle of a frame.

Each reload is a new module (`main_1.cppia`, `main_2.cppia`, ...). The executable's own
copies of the reloaded classes run until the first reload, renamed (`_hot.Game`) so they
don't collide. Module files are deleted as soon as they're loaded, so none are left behind,
even after Ctrl-C.

## JavaScript

On JS, hotreload's dev server serves the hot build and rebuilds the bundle when a source
changes. The page (or node program) loads the new bundle beside the running one and takes on
its classes between two frames. The page keeps everything it made: a wasm engine, GPU state,
loaded assets, open connections.

```bash
haxe -lib hotreload-hx --run hotreload.DevServer [--port 8080] [--mount /url=dir] build.web.hxml
```

The dev server adds `-lib hotreload-hx` and `-D hotreload` to the build, serves its output
directory at `http://localhost:8080/`, and watches its class paths. `--mount /assets=../assets`
serves another directory, with Range requests. A node program connects to `HOTRELOAD_URL`
(`http://localhost:8080/__hotreload` by default). `/__hotreload_stop`, from the same
machine, stops the dev server and its compilation server.

A hot JS build must be ES6 or later (`-D js-es=6`); `-lib hotreload-hx` sets it, and a hot
build set lower stops with a message. To ask for a later version, define it after
`-lib hotreload-hx`.

There's nothing to call or mark: every class reloads, including the main class, and `@:hot`
is ignored. On a reload:

- statics keep their values on the new class; one whose declared type changed is reset, with
  a message;
- objects the statics hold get the new classes in place, so every reference stays good; new
  fields start from their initializers, and enum values are rebuilt by constructor name;
- old classes forward to the new ones, so leftover old code runs the new code on the same
  state;
- a method reference in a static (`onFrame = Guest.frame`) points to the new code;
- `@:beforeHotReload` and `@:afterHotReload` run as on hxcpp.

Signature changes need no restart, since every caller reloads too. A closure or bound method
(`obj.method`) made before a reload keeps its old code.

The dev server also watches the files it serves (except the bundle) and reports saved assets
by URL to the reloader's `assetsChanged`. `watchAssets` does nothing on JS, so one main
class works for both targets:

```haxe
var reloader = new hotreload.Reloader();
reloader.watchAssets("assets"); // hxcpp; on JS, the dev server watches what it serves
reloader.assetsChanged = urls -> for (url in urls) assets.reload(url);
```

`--reload-define <name[=value]>` adds a define to reload builds only, for something the
first build makes and reloads don't need (a native host the page loads once, say).

## Debugging

### JS

Debug on JS when you can. Reloaded JS code runs at full speed, and the browser's DevTools or
VS Code's JavaScript debugger work as they do for any Haxe JS build. Build with `-debug` for
source maps and set breakpoints in the `.hx` files. Each reloaded bundle has its own source
map, so a breakpoint also hits in the new code after a reload.

### hxcpp

Reloading works with stock hxcpp (tested with haxelib's 4.3.2), but breakpoints in the
reloaded code don't: hxcpp 4.x doesn't tell the debugger when a cppia module loads, so
breakpoints never bind, and inspecting variables crashes in functions with arguments.
Forks of hxcpp and hxcpp-debugger fix this; the hxcpp fork is upstream's git master
(v4.3.171) plus the fixes. With them, breakpoints hit in reloaded code and stay on their
lines after a reload. It's much slower than JS, though: breakpoints only fire in
interpreted cppia.

```bash
haxelib git hxcpp https://github.com/robknopf/hxcpp
haxelib git hxcpp-debug-server https://github.com/robknopf/hxcpp-debugger master hxcpp-debug-server
code --install-extension hxcpp-debugger-<version>.vsix   # from the root of robknopf/hxcpp-debugger
```

If the git hxcpp doesn't build its build tool on first use, run `haxe compile.hxml` in its
`tools/hxcpp/`.

A hot build to debug adds `-debug` and `-lib hxcpp-debug-server`, as `examples/hello`'s
`build hot` tasks and `Hot (hxcpp)` launch configurations do. In a `-debug` build, modules
run interpreted rather than through cppia's JIT (up to 56× slower than native). The
extension uses port 6972, so a program left running from an earlier session can stop a new
one from starting.

## Limits

- Only hxcpp (through cppia) and JS (through the dev server) reload. Other targets build
  without it, with a warning.
- A hot hxcpp build is bigger and slower to build: `-D scriptable` and `-dce no` keep every
  class whole.
- Reloaded hxcpp code runs in cppia: 5–13× slower than native through its JIT, and up to
  56× slower interpreted in a `-debug` build. Debug and release builds have no such cost.
- New reloaded code that uses an extern class the executable wasn't built with fails to load
  ("Bad link"). Restart to build it in.
- A restarted program runs the code it was built with until the next change reloads.
  Rebuild after editing a stopped program.
- Old modules aren't freed, since old code may still run, so memory grows a little with each
  reload until a restart.
- Changing the main class or a `@:hot` function's signature needs a restart.
- A reloaded class with its own `@:native` can't be reloaded.
- On JS, a renamed or removed field is `undefined` on carried objects.

[docs/comparison.md](docs/comparison.md) compares hotreload-hx with hotreload-nim: reload
times, reloaded code's speed, and what each can do.

## The repo

```
haxelib.json             the package: classPath src
extraParams.hxml         --macro hotreload.Builder.init(), added by -lib hotreload-hx
src/hotreload/
  Builder.hx             the hot build: @:hot, reload hooks, the module build's config
  Reloader.hx            watching, rebuilding, swapping, and asset changes
  FileWatch.hx           file watching, shared by the reloader and the dev server
  Slot.hx, Slots.hx      hot statics' storage, kept by the executable
  Hooks.hx               reload hooks and @:hot functions
  Migrate.hx             moving objects to the new classes
  Reloader.js.hx         the JS reloader
  JsSwap.hx              JS: loading a new bundle and taking on its classes
  DevServer.hx           JS: building, serving and rebuilding
docs/comparison.md       hotreload-nim and hotreload-hx side by side
tests/                   `haxe tests/run.hxml`: builds tests/reload/ hot and edits it while it runs
tests/matrix/            the capability matrix behind docs/comparison.md
tests/scale/             reload time by program size, for hxcpp, JS and Nim
examples/hello/          a console application with a reloaded class and an asset
```

## License

MIT. See [LICENSE](LICENSE).
