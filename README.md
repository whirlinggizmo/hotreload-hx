# hotreload-hx

Hot reload for Haxe applications. When you save a change, hotreload rebuilds the code in
the background and swaps it into the running application, keeping its state. It's for
applications with a loop, such as a game or a windowed tool, where a restart would cost you
the window, the loaded assets and where you were. Debug and release builds compile the same
code with no reloading and no cost.

Two targets reload, and they follow the same rules:

- **Native (hxcpp):** the reloaded code is built as a cppia module and run by the
  executable's cppia host. See [Native](#native-hxcpp-through-cppia).
- **JavaScript (browser or node):** a dev server rebuilds the bundle, and the running
  program takes on its classes. See [JavaScript](#javascript-browser-or-node).

The rules are in [The rules](#the-rules), and what still differs between the targets is in
[Differences between the targets](#differences-between-the-targets). It's the Haxe
side of [hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim).

## Install

Haxe 4.3 or later, then:

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

or, from a clone, `haxelib dev hotreload-hx <clone>`. Each target's own requirements are in
its section. Only Linux is tested so far.

## The rules

This part is the same on both targets, and code written to it behaves the same on both.
There are two rules: *a static of yours survives a reload if it says `@:hot`*, and *a
callback that may outlive a reload is a lambda that calls a `@:hot` function*. The rest of
this section is what they mean in practice. How each target does it is under
[Native](#how-a-native-reload-works) and [JavaScript](#how-a-js-reload-works).

### Your code, the main class, and libraries

hotreload tells three kinds of code apart, on both targets:

- **Your code:** the classes in the project's own class paths (the `-cp` directories inside
  the project). This is what you edit while the application runs. Natively, the part of it
  that reloads is every class in a directory with a `@:hot` static or a reload hook, and
  below; an edit anywhere else in your code needs a restart, and says so. On JS, all of it
  reloads.
- **The main class:** compiled once, and never reloaded on either target.
- **Libraries:** the standard library and haxelibs. Never reloaded on either target.

The rules for statics below are for your code. The main class's and a library's statics
keep their values across every reload, on both targets.

### Statics

In your code, a `@:hot` static keeps its value across reloads, and a plain static starts over
from its first value on every reload, on both targets, whether or not native reloads its
class:

```haxe
@:hot static var score = 0;
@:hot static var enemies:Array<Enemy> = [];
static var frameCount = 0; // starts over on each reload
```

A `@:hot` static's first value is only used when it's first made, so editing it changes
nothing while the application runs. To change a kept value, assign it, for example in an
`@:afterHotReload` hook. A plain static's first value is used again on each reload, so an
edit to it takes effect.

If a reload changes a `@:hot` static's type, its value is kept when it's still the same kind
(number, bool, string, object), and reset otherwise, with a message:

```
hotreload: game.State.label's type changed (Int to String); started over from its first value
```

`@:hot` takes a static var, or a static function ([Callbacks](#callbacks)). A var needs a
type or a first value. It can also be read-only from outside, `(default, null)` or
`(default, never)`:

```haxe
@:hot public static var graphics(default, null):Graphics; // everyone reads it; only its class sets it
```

`@:hot` and the hooks can't be used in the main class, on an instance field, or on a
property with accessors: each is a build error on both targets.

What a `@:hot` static holds survives with it. On each reload, the objects reachable from the
`@:hot` statics take on the new classes, field by field by name. A removed field is dropped,
and a new one starts from its initializer:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // new: starts at 10
}
```

hotreload walks arrays, maps, anonymous structures, reloaded classes' fields and reloaded
enums' values (matched by constructor name). Shared objects stay shared and cycles stay
cycles. An object held only from outside the `@:hot` statics, by the main class, say, isn't
reached, and natively keeps its old code.

### Callbacks

The main class calls into your code through static functions, and the build marks those
`@:hot` itself: each reload points them at the new code, so the main class needs nothing
written. (On JS every call reaches the new code anyway. Natively, a `@:hot` function is
what makes a call from code compiled before the reload reach the new code.)

A callback is the same situation, made by your own code. A closure made before a reload
keeps its own code on both targets, and natively so do the methods it calls and the object
it captured. So a callback that may outlive a reload, a load's completion, say, is a
springboard: a lambda that calls a `@:hot` static function by name and leaves the work to
it.

```haxe
@:hot static function loaded(file:Model) { ... }   // its types written out: a reload checks them
Models.load("ship.obj", file -> loaded(file));    // reaches the newest `loaded`, on both targets
```

Don't pass a method as a value (`Models.load("ship.obj", loaded)`). That's a bound method,
or a static's closure, which no reload can re-point, so it runs its old code on both
targets; the build warns about one, in your code and in the main class. A callback
registered once for the program's life (for input, say) can be made again in an
`@:afterHotReload` hook instead.

A `@:hot` function's parameter and return types are written out (or come from a default
value); with neither, a function that returns nothing is `Void`. When the build marked the
function because the main class calls it, its message says so. A call the build can't see,
through an import alias, is warned about: mark that function yourself.


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

### Assets

The reloader tells the program which asset files were saved, so it can load them again.
Nothing is rebuilt; reloading the asset is up to the program:

```haxe
var reloader = new hotreload.Reloader();
reloader.watchAssets("assets"); // native; on JS the dev server watches what it serves
reloader.assetsChanged = files -> for (f in files) Game.reloadAsset(f);
```

Natively, `files` are paths that start as the directory was given (`assets/sounds/fire.ogg`).
On JS they're URLs (`/assets/sounds/fire.ogg`). Deleted files are reported too; hidden files
and an editor's temporary save files aren't. The callback belongs to the main class, so call
reloaded code through its class, as above, to reach the new version.

---

## Native (hxcpp, through cppia)

### Requirements

- hxcpp (stock works, 4.3.2 or later) and a C++ toolchain (gcc or clang; MSVC or MinGW on
  Windows)
- `haxe` on the `PATH` while the application runs, since it builds each reload
- To debug reloaded code: forks of hxcpp and hxcpp-debugger can be used to set breakpoints (see
  [Debugging native code](#debugging-native-code))

### Setting up

The main class calls `reloader.update()` in its loop. That's where everything happens:

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

```haxe
// src/game/Game.hx: the reloaded code
package game;

class Game {
	@:hot static var score = 0;             // survives a reload

	public static function init() { ... }  // the main class calls these: the build marks them @:hot
	public static function tick() { ... }
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

While it runs, each save to `src/game/Game.hx` (or anything beside it) is built in the
background and swapped in at the next `update()`. `score` keeps its value, and `Game.tick()`
calls the new `tick`. Without `-D hotreload`, the same sources build an ordinary program,
which is your debug and release build.

### Trying it

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

`ticks` is a `@:hot` static, so it keeps counting; `sinceReload` is a plain static, so it
starts over. The greeting's first word comes from `assets/greeting.txt`; edit it and the
next greeting uses it, with nothing rebuilt:

```
hotreload: assets/greeting.txt changed
hello: the greeting is now "Howdy"
```

It also has debug and release builds, with VS Code tasks and launch configurations. For a
larger program, [HeliX](https://github.com/whirlinggizmo/helix), a Haxe game framework,
develops with hotreload-hx.

### How a native reload works

A few times a second, `update()` checks the reloaded code's sources. Once a change has
settled, it builds a module in the background while the old code keeps running; compiler
errors go to the terminal. The first `update()` after the build checks the `@:hot` functions'
signatures, runs the hooks, starts the module, carries the `@:hot` statics over and points
the `@:hot` functions at the new code. So a swap never happens in the middle of a frame.

- Each reload is a new module (`main_1.cppia`, `main_2.cppia`, ...). The executable's own
  copies of the reloaded classes run until the first reload, renamed (`_hot.Game`) so they
  don't collide.
- A `@:hot` static's storage is kept by the executable, so the old code and the new share it.
- The rest of your code stays in the executable, but a reload starts its plain statics over
  too, so a plain static starts over wherever it is, as on JS.
- Objects are copied to the new classes. An object held only from outside the `@:hot`
  statics, such as by the main class, isn't reached, and keeps its old code.
- A replaced module stays loaded, so a callback handed out before a reload (to an asset
  loader, say) still works when it fires. It runs its own old code, on the same `@:hot`
  statics: a `@:hot` function it calls is the newest, any other method is the old module's,
  and an object it captured is the old copy, which the new code no longer holds.
- A `@:hot` function (the ones the main class calls, which the build marks, and the ones
  you mark for callbacks) is a stub calling through a variable, in the executable and in
  every module. A reload points every copy at the new module's function, which is how the
  main class, and a callback made before the reload, reach the newest code.
- A `@:hot` function whose signature changed is refused with a message, and the old code
  runs on until a restart. The same goes for adding or renaming one.
- An edit outside the reloaded code is reported, and needs a restart:
  `hotreload: src/Main.hx changed, outside the reloaded code: restart to run it`.
- Module files are deleted as soon as they're loaded, so none are left behind, even after
  Ctrl-C.

### Building

`-D hotreload` sets what cppia needs: `-D scriptable`, `-dce no` and `-D dll_export`. Each
module is built by its own `haxe`, with the hot build's command line except for the target,
main class and `--cmd`, plus `-D hotreload_library`. So a hot build must be a single build:
`--next` and `--each` are refused. Modules go to `hotreload/` in the hot build's `--cpp`
directory.

The reloader starts a Haxe compilation server (`haxe --wait` on a free local port) and
builds each module through it, so a reload only retypes what changed. The first build runs
at startup and isn't swapped in, so the first reload is quick too. In `examples/hello` a
module builds in about 0.1 s with the server and 0.3 s without. To use your own server (your
editor's, say), pass `-D hotreload_compilation_server=<port>` or `host:port`; to build
without one, `-D hotreload_no_compilation_server`. The server stops when the application
does.

### Native bindings

cppia can't run an extern call or `__cpp__`, which is what a C binding is made of. So a
module build doesn't inline library code: every `inline` function outside the reloaded code
and the standard library becomes a call to the executable's compiled copy, where the C++
runs. This is automatic. A binding needs two things for it to work:

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

### Debugging native code

Reloading works with stock hxcpp (tested with haxelib's 4.3.2), but breakpoints in the
reloaded code don't: hxcpp 4.x doesn't tell the debugger when a cppia module loads, so
breakpoints never bind, and inspecting variables crashes in functions with arguments.
Forks of hxcpp and hxcpp-debugger fix this; the hxcpp fork is upstream's git master
(v4.3.171) plus the fixes. With them, breakpoints hit in reloaded code and stay on their
lines after a reload. It's much slower than JS, though: breakpoints only fire in
interpreted cppia. Debug on JS when you can.

Upstream hxcpp has the hook for debugging cppia, but compiles it only for Haxe 5
(`HXCPP_API_LEVEL >= 500`), and reads `this` from the wrong slot in functions with
arguments; the fix for that is upstream as
[hxcpp#1426](https://github.com/HaxeFoundation/hxcpp/pull/1426). Neither has been tried
with this library on Haxe 5.

```bash
haxelib git hxcpp https://github.com/robknopf/hxcpp
haxelib git hxcpp-debug-server https://github.com/robknopf/hxcpp-debugger master hxcpp-debug-server
code --install-extension hxcpp-debugger-<version>.vsix   # from the root of robknopf/hxcpp-debugger
```

If the git hxcpp doesn't build its build tool on first use, run `haxe compile.hxml` in its
`tools/hxcpp/`.

A hot build to debug adds `-debug` and `-lib hxcpp-debug-server`, as `examples/hello`'s
`build hot` tasks and `Hot (hxcpp)` launch configurations do. The extension uses port 6972,
so a program left running from an earlier session can stop a new one from starting.

### Native limits

- A hot build is bigger and slower to build: `-D scriptable` and `-dce no` keep every class
  whole.
- Reloaded code runs in cppia: 5–13× slower than native through its JIT, and up to 56×
  slower interpreted in a `-debug` build. Debug and release builds have no such cost.
- New reloaded code that uses an extern class the executable wasn't built with fails to load
  ("Bad link"). Restart to build it in.
- A restarted program runs the code it was built with until the next change reloads.
  Rebuild after editing a stopped program.
- Old modules aren't freed, since old code may still run, so memory grows a little with each
  reload until a restart.
- A reloaded class with its own `@:native` can't be reloaded.

---

## JavaScript (browser or node)

### Requirements

- A browser, or node 22.3 or later
- ES6 output (`-D js-es=6`): `-lib hotreload-hx` sets it, and a hot build set lower stops
  with a message. To ask for a later version, define it after `-lib hotreload-hx`.

### Setting up

hotreload's dev server builds the program hot, serves it, and rebuilds it when a source
changes. Give it the build's own arguments, such as an hxml:

```bash
haxe -lib hotreload-hx --run hotreload.DevServer [--port 8080] [--mount /url=dir] build.web.hxml
```

Or from a macro, which checks its options as it compiles and returns, so one hxml can start
the dev server beside other watchers; the compiler waits for it after its macros, and it
stops with the compiler however that ends:

```hxml
# watch.hxml: haxe watch.hxml
-lib hotreload-hx
--macro hotreload.DevServer.serve("build.web.hxml", {port: 8080, mounts: {"/assets": "assets"}})
```

```hxml
# build.web.hxml
-cp src
-lib hotreload-hx
--main Main
--js web/main.js
-debug
```

The dev server adds `-lib hotreload-hx` and `-D hotreload` to the build, serves its output
directory at `http://localhost:8080/`, and watches its class paths. The main class is the
same as natively, but drives its loop the browser's way; `reloader.update()` does nothing on
JS, so one main class works for both:

```haxe
// src/Main.hx
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		Game.init();
		#if js
		js.Browser.window.setInterval(() -> Game.tick(), 16);
		#else
		while (true) {
			reloader.update();
			Game.tick();
		}
		#end
	}
}
```

```
hotreload: serving http://localhost:8080/ (/home/you/game/web)
hotreload: watching src/
```

Options:

- `--port <n>`: where it serves, 8080 by default.
- `--mount /assets=../assets`: serves another directory too, with Range requests.
- `--reload-define <name[=value]>`: a define for reload builds only, for something the first
  build makes and reloads don't need (a native host the page loads once, say).
- `--no-compilation-server`: builds each reload with a `haxe` of its own.

A node program asks `HOTRELOAD_URL` for new builds (`http://localhost:8080/__hotreload` by
default). `/__hotreload_stop`, from the same machine, stops the dev server and its
compilation server.

### How a JS reload works

The program loads the new bundle beside the running one and takes on its classes between
two frames. It keeps everything it made: a wasm engine, GPU state, loaded assets, open
connections.

- Every class takes on its new code, the main class included: an edit that would need a
  restart natively just runs.
- Statics follow [the rules](#statics): your code's `@:hot` statics are kept and its plain
  ones start over; the main class's and libraries' are kept.
- Objects the kept statics hold get the new classes in place, so every reference to them
  stays good. New fields start from their initializers, and enum values are rebuilt by
  constructor name.
- Old classes forward to the new ones, so leftover old code (a callback, an object nothing
  walked to) runs the new code, on the same state.
- A method reference in a static (`onFrame = Guest.frame`) points to the new code.
- Signature changes need no restart, since every caller reloads too. `@:hot` on a function,
  the build's mark or yours, changes nothing here; it's there so the same source builds for
  both targets.

The dev server also watches the files it serves (except the bundle) and reports saved ones
to the reloader's `assetsChanged`, by URL.

### Debugging JS code

Debug on JS when you can. Reloaded JS code runs at full speed, and the browser's DevTools or
VS Code's JavaScript debugger work as they do for any Haxe JS build. Build with `-debug` for
source maps and set breakpoints in the `.hx` files. Each reloaded bundle has its own source
map, so a breakpoint also hits in the new code after a reload.

### JS limits

- A closure made before a reload keeps its own code, though what it calls by name is new. A
  method passed as a value (`load(path, place)`) keeps its old code; the build warns about one.
- A renamed or removed field is `undefined` on carried objects, as is a new field with no
  initializer.

---

## Differences between the targets

Most of the behaviour is the same on both targets. These differences come from how each
target runs code and can't be removed. Code that doesn't depend on them behaves the same on
both.

|                                                    | Native                                    | JS                                    |
| -------------------------------------------------- | ----------------------------------------- | ------------------------------------- |
| An edit to the main class, or to your code outside the directories native reloads | needs a restart | runs                           |
| A `@:hot` function's signature changes             | needs a restart                           | reloads                               |
| The main class calls reloaded code                 | the new code through `@:hot` functions (marked by the build) | always the new code |
| A carried object                                   | copied to the new class                   | the same object, given the new class  |
| An object held only from outside the `@:hot` statics | keeps its old code                      | runs the new code                     |
| A closure made before a reload                     | its own code; the new through `@:hot` functions | its own code; the new for what it calls |
| A new field with no initializer                    | its type's default (0, false, null)       | `undefined`                           |
| Reloaded code's speed                              | cppia: 5–56× slower than native           | full speed                            |
| Breakpoints in reloaded code                       | need the forks; interpreted only          | DevTools, as usual                    |

`tests/parity/` runs the same program and edits on both targets and checks both against the
same results. [docs/comparison.md](docs/comparison.md) compares hotreload-hx with
hotreload-nim: reload times, reloaded code's speed, and what each can do.

## Reference

### Defines

| Define                                      | Target  | Meaning                                                   |
| ------------------------------------------- | ------- | --------------------------------------------------------- |
| `-D hotreload`                              | both    | a hot build (the JS dev server adds it)                   |
| `-D hotreload_compilation_server=<port>`    | native  | build modules through this server (`port` or `host:port`) |
| `-D hotreload_no_compilation_server`        | native  | build each module with a `haxe` of its own                |
| `-D hotreload_url=<url>`                    | JS      | where the program asks for new builds                     |

Other targets build without hot reload, with a warning.

### The repo

```
haxelib.json             the package: classPath src
extraParams.hxml         --macro hotreload.Builder.init(), added by -lib hotreload-hx
src/hotreload/
  Builder.hx             the hot build: @:hot, reload hooks, the reloaded code
  Reloader.hx            native: watching, rebuilding, swapping, and asset changes
  FileWatch.hx           file watching, shared by the reloader and the dev server
  Slot.hx, Slots.hx      native: @:hot statics' storage, kept by the executable
  Hooks.hx               reload hooks and @:hot functions
  Migrate.hx             native: moving objects to the new classes
  Reloader.js.hx         JS: the reloader
  JsSwap.hx              JS: loading a new bundle and taking on its classes
  DevServer.hx           JS: building, serving and rebuilding
docs/comparison.md       hotreload-nim and hotreload-hx side by side
tests/                   `haxe tests/run.hxml`: builds tests/reload/ hot and edits it while it runs
tests/parity/            the same program and edits on both targets, checked against the same results
tests/matrix/            the capability matrix behind docs/comparison.md
tests/scale/             reload time by program size, for hxcpp, JS and Nim
examples/hello/          a console application with a reloaded class and an asset
```

## License

MIT. See [LICENSE](LICENSE).
