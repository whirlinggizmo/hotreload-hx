# hotreload-hx

Hot reload for Haxe applications. hotreload rebuilds a running application's code when
you save a change, in the background, and swaps the new code in without stopping the
application and without losing its state. It is for applications with a loop, such as a
game or a tool with a window, where a restart would cost you the window, the loaded
assets and where you were. Debug, release and web builds compile the same code in, with
no reloading and no cost.

It's the Haxe side of [hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim), and
works the same way. On hxcpp, the reloaded code is built as a cppia module and run by the
executable's cppia host.

## Requirements

- **Haxe 4.3+**
- **hxcpp**, and what it needs to build (gcc or clang on Linux and macOS, MSVC or MinGW on
  Windows)
- `haxe` on the `PATH` while the application runs: it builds each reload
- To debug the reloaded code: forks of hxcpp and hxcpp-debugger (see Debugging)

Note that only Linux is tested so far.

## Install

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

or, from a clone, `haxelib dev hotreload-hx <the clone's directory>`.

## An application that hot reloads

An application that hot reloads has two parts: a main class, which is compiled into the
executable and never reloaded, and the classes it calls into, which are reloaded.

The main class creates the reloader and calls `reloader.update()` in its loop:

```haxe
// src/Main.hx
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		Game.init();
		while (true) {
			reloader.update(); // pumps the file watcher, module builder, and reloader
			Game.tick();
		}
	}
}
```

The reloaded classes mark what a reload has to know about. A `@:hot` static var is kept
across reloads, and a `@:hot` static function is one the main class calls, so that its
calls reach the new code:

```haxe
// src/Game.hx
class Game {
	@:hot static var score = 0;

	public static function init() { ... }
	@:hot public static function tick() { ... }
}
```

A hot build is an ordinary hxcpp build with hotreload and `-D hotreload`:

```hxml
# hot.hxml
-cp src
-lib hotreload-hx
--main Main
-D hotreload
--cpp out/hot
```

While it runs, every change you save to `src/Game.hx`, or to anything beside it, is built
as a cppia module in the background and swapped in at the next `update()`. `score` keeps
its value, and the main class's `Game.tick()` calls the new `tick`.

The reloaded code is found from the metadata: every class with a `@:hot` static or a reload
hook in it, and every class in the same directories as those, and below them, except the
main class. Note that a class from somewhere else (a library, an engine) is compiled into
the executable, and a change to it requires a restart, as a change to the main class does.

## Trying it

`examples/hello` is a small console application that hot reloads. From a clone of this
repo:

```bash
cd examples/hello
haxe hot.hxml
```

It prints a greeting a few times a second. Open `src/Hello.hx`, change the greeting and
save, and the next greeting is the new one:

```
Hello, world! (ticks: 12, since the last reload: 12)
hotreload: building (src/Hello.hx changed)
hello: reloaded
hotreload: reloaded (main_1.cppia)
Howdy, world! (ticks: 16, since the last reload: 1)
```

`ticks` is a hot static, so it keeps counting through the reload. `sinceReload` is a
plain static, so it starts over.

`examples/simple` is the same thing with a window: [wgrender-hx](https://github.com/whirlinggizmo/wgrender-hx)'s
simple example (an animated model, a sprite, music, text), with its scene, timers and
loaded assets kept across reloads. It needs wgrender-hx installed and a link to its
assets, which `src/Main.hx` explains; then `haxe hot.hxml`, and edit `src/Simple.hx`.
Each example has a debug and a release build too, and `.vscode/` tasks and launch
configurations for them.

## Usage

### State

A `@:hot` static var keeps its value across reloads. A plain static starts over with each
reload:

```haxe
@:hot static var score = 0;
@:hot static var enemies:Array<Enemy> = [];
static var frameCount = 0; // starts over
```

The first value (`= 0` above) is only used once, when the static is created. As such, an
edit to the first value changes nothing while the application runs. A kept value is
changed by assigning it, in an `@:afterHotReload` hook, say:

```haxe
@:afterHotReload static function reset() {
	score = 0;
}
```

When a reload changes a hot static's type, its value is carried over when it's still the
same kind of value (a number, a bool, a string, an object), and started over from the
first value when not.

### Objects

An object keeps the class it was made with, and that class's methods. So on each reload,
the objects of the reloaded classes that the hot statics hold are copied into the new
code's classes: field by field, by name. A field that's gone is dropped, and a new one
starts from its initializer, as it would in a new object:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // new: starts at 10
	...
}
```

hotreload walks from the hot statics through arrays, maps, anonymous structures, the
reloaded classes' fields and the reloaded enums' values (matched by constructor name).
The objects are copied as a graph, so shared objects stay shared and cycles stay cycles,
and arrays, maps and structures are updated in place. Note that it doesn't walk into the
executable's own classes' objects (an engine's scene, say), and that an object held
anywhere else, such as by the main class, keeps running the code it was made with.

### Functions the main class calls

The main class is compiled once, so a call from it reaches the version of the function it
was built with, forever. A `@:hot` static function is called through the reloader
instead, so a call from the main class reaches the newest code:

```haxe
// src/Game.hx
@:hot public static function tick() { ... }

// src/Main.hx
Game.tick(); // after a reload, this calls the new tick
```

Only the functions the main class calls after a reload could have happened need it. A
function the main class only calls at the start (like `init`), or a function only the
reloaded classes call, is an ordinary function.

Note that a `@:hot` function's parameters and result can't change while the application
runs. A reload that changes them is refused with a message, and the old code keeps
running until you restart. The same goes for adding a `@:hot` function or renaming one.
Its parameter and return types are written out, or come from a default value; with
neither, a function that returns nothing is `Void`.

### Doing something around a reload

A reloaded class can run something just before a reload, on the old code, and just after,
on the new code:

```haxe
@:beforeHotReload static function saveScratch() { ... }
@:afterHotReload static function rebuildCaches() { ... }
```

These hooks are optional. They're static functions with no parameters.

The main class is told about reloads through the reloader's two callbacks, since the
metadata is for the reloaded classes only:

```haxe
reloader.beforeReload = () -> trace("reloading");
reloader.afterReload = () -> trace("reloaded");
```

A reload runs these in order: the old code's `@:beforeHotReload` hooks, the main class's
`beforeReload`, the swap (the new code's statics are made, and the hot statics carried
over), the new code's `@:afterHotReload` hooks, and the main class's `afterReload`.

### Callbacks that outlive a reload

A replaced module stays loaded, so a callback that its code handed out before a reload
(to an asset loader, say) still works when it fires. Note that it runs the code it came
from, not the new code. It reads and writes the same hot statics as the new code, since
each hot static has one storage the executable keeps.

### Building

`-D hotreload` turns hot reloading on, on a cpp target. hotreload sets what the build
needs for cppia: `-D scriptable`, `-dce no` and `-D dll_export`. Everything else, the
command line of each module's build, is taken from the hot build's own.

Without `-D hotreload`, the same sources build one ordinary program with no reloading,
which is your debug, release and web build. `examples/hello` has one of each:

```bash
haxe hot.hxml       # hot: builds out/hot, and runs it
haxe debug.hxml     # debug, no hot reload
haxe release.hxml   # release
```

Each module is built with its own `haxe`, from the hot build's directory, with the hot
build's command line, but its target, main class and `--cmd`. As such a hot build is one
build: an hxml with `--next` or `--each` is refused. A module's build has
`-D hotreload_library`, for a define only it needs.

The modules go to a `hotreload/` directory in the hot build's `--cpp` directory
(`out/hot/hotreload/` above), with the list of the executable's classes the modules are
compiled against.

### Native bindings

cppia can't run an extern call or `__cpp__`, and a binding of a C library is made of
those. So **a reload's build doesn't inline library code**: every `inline` function
outside the reloaded directories (and outside the standard library) is compiled as a
call to the executable's copy of it, and the C++ runs there. hotreload does this
itself, in every module build, with nothing to turn on; what stays inline is what has
to (an `extern inline` function, an abstract's constructor, a function that assigns an
abstract's `this`). A library needs two things for it to work:

- **C types only in private classes.** `-D scriptable` makes a cppia wrapper for every
  static of a public class, including its private ones, and a wrapper for a C pointer,
  struct, enum or function pointer doesn't compile. hotreload makes such an `inline`
  function `extern inline`, which has no wrapper (cppia could never have called it);
  a non-inline one (a C callback, say) has to be in a private class, which gets none.
- **Compiled copies of what the reloaded code calls.** An `extern inline` function has
  none, so its body is inlined into the module, and if that's C, the reload fails to
  load with `Unknown static call to ...`. Haxe requires `overload` functions to be
  `extern inline`, so an overload can't make the C call itself: it calls a plain
  `inline` function that does (which the native build inlines all the same):

  ```haxe
  public static overload extern inline function setPosition(m:Model, v:Vec3):Bool
  	return setPosition3(m, v.x, v.y, v.z);
  public static overload extern inline function setPosition(m:Model, x:Float, y:Float, z:Float):Bool
  	return setPosition3(m, x, y, z);
  static inline function setPosition3(m:Model, x:Float, y:Float, z:Float):Bool
  	return Raw.wgr_model_set_position(m, x, y, z);
  ```

`examples/simple` is wgrender-hx, which is all inline wrappers over externs, reloading
at full speed through this.

### The compilation server

The reloader starts a Haxe compilation server (`haxe --wait`, on a free local port) when
it's made, and builds each module through it (`--connect`). The server keeps what it has
parsed and typed between builds, so a reload rebuilds only the files that changed and
what depends on them; a library's code, or the standard library's, is typed once. The
first build runs as the application starts, and isn't swapped in, so that the first
reload is quick too. In `examples/hello`, a module builds in about 0.1 s through the
server, and 0.3 s without it.

The server stops when the application does. To use a compilation server of your own
instead (one your editor runs, say), name its port with
`-D hotreload_compilation_server=<port>`, or `host:port`. To build without one,
`-D hotreload_no_compilation_server`.

Note that a compilation server notices a changed file by its time, in whole seconds, so on
its own it would miss a second save in the same second as the last build's. The reloader
tells it which files changed since the last build started.

### Debugging

Breakpoints in the reloaded code, which runs in cppia, need forks of hxcpp and of
hxcpp-debugger, the VS Code extension: their fixes for debugging cppia aren't upstream
yet. With them, breakpoints hit in the reloaded code and stay on their lines after a
reload.

- [robknopf/hxcpp](https://github.com/robknopf/hxcpp): `haxelib dev hxcpp <its clone>`
- [robknopf/hxcpp-debugger](https://github.com/robknopf/hxcpp-debugger): the extension,
  installed from the `.vsix` in its repo (`code --install-extension <the .vsix>`), and the
  debug server the program links, `haxelib dev hxcpp-debug-server <its clone>/hxcpp-debug-server`

A hot build to debug has `-debug` and `-lib hxcpp-debug-server`, as the examples' `build
hot` tasks and `Hot (hxcpp)` launch configurations do. In a `-debug` build the modules run
interpreted, not through cppia's JIT, since breakpoints only fire there. As such it's the
slowest way to run reloaded code. The extension talks to the program on port 6972, so a
program left running from an earlier session can make a new debugging session fail to
start; the extension says so.

## What happens on a reload

Everything happens in `reloader.update()`. A few times a second, `update()` checks the
sources in the reloaded code's directories, and below them (except the main class's), for
changes. Once they've changed and then stopped changing, it starts a build of the reloaded
code as one cppia module, in the background, and returns. The old code keeps running in
the meantime, and any compiler errors go to the terminal. A change during a build starts
another build when that one is done.

The first `update()` after the build finishes swaps the new module in. It checks the hot
functions' signatures, runs the hooks, starts the module, carries the hot statics over,
and points the main class's calls at the new code. As such, a swap only ever happens where
the main class calls `update()`, never in the middle of a frame.

Each reload is a new module (`main_1.cppia`, `main_2.cppia`, ...), which replaces the last
one's classes. The executable's own compiled copies of the reloaded classes run until the
first reload; they're renamed (`_hot.Game`), so the modules' classes, under their own
names, don't collide with them.

## Limits

- Only hxcpp reloads, through cppia. A hot build for another target builds without it,
  with a warning.
- A hot build is bigger and slower to build: `-D scriptable` and `-dce no` keep every
  class the executable has, whole, for the modules to call.
- The reloaded code runs in cppia, which is slower than hxcpp's native code: measured at
  5–13× slower through its JIT, and up to 56× slower interpreted in a `-debug` build. Hot
  statics are read and written through their storage (as `Dynamic`), and hot functions
  are called through a variable. The debug and release builds have none of this.
- New code that uses a class the executable was built without, and which has native parts
  (an extern), fails to load, with "Bad link". Restart to build it in.
- A program started again runs the code it was built with, not what's in the sources now,
  until the next change reloads. Rebuild after editing a stopped program.
- Old modules aren't freed.
- A change to the main class, or to a `@:hot` function's signature, requires a restart.
- A class in the reloaded code with its own `@:native` can't be reloaded.

[docs/comparison.md](docs/comparison.md) compares hotreload-hx with hotreload-nim: reload
times, the speed of reloaded code, and what each can and can't do.

## The repo

```
haxelib.json             the package: classPath src, -lib hotreload-hx
extraParams.hxml         --macro hotreload.Builder.init(), which -lib hotreload-hx adds
src/hotreload/
  Builder.hx             the hot build: @:hot, the reload hooks, and the executable's
                         config for rebuilding the reloaded code
  Reloader.hx            the reloader: watch, rebuild, swap
  Slot.hx, Slots.hx      hot statics' storage, which the executable keeps
  Hooks.hx               the reload hooks, and the executable's @:hot functions
  Migrate.hx             carrying the hot statics' objects over to the new classes
docs/comparison.md       hotreload-nim and hotreload-hx, measured side by side
tests/                   `haxe tests/run.hxml`: a smoke test that builds tests/reload/
                         hot, runs it and edits it while it runs
tests/matrix/            the capability matrix behind docs/comparison.md
examples/hello/          a console application: src/Main.hx, its main class, and
                         src/Hello.hx, which is reloaded
examples/simple/         wgrender-hx's simple example, hot reloaded: a window, a scene,
                         assets, a native binding
```

## License

MIT. See [LICENSE](LICENSE).
