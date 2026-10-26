# hotreload-hx

Hot reload for Haxe JavaScript applications, in the browser or in node. When you save a
change, hotreload's dev server rebuilds the bundle, and the running program takes on its
classes, keeping its state. It's for applications with a loop, such as a game or a tool,
where a reload of the page would cost you the loaded assets, the GPU's state and where you
were. Release builds compile the same code with no reloading and no cost.

Native reload (hxcpp, through cppia) is on the [`hxcpp`](https://github.com/whirlinggizmo/hotreload-hx/tree/hxcpp)
branch, the version that reloaded both targets under the same rules. It's the Haxe side of
[hotreload-nim](https://github.com/whirlinggizmo/hotreload-nim).

## Install

Haxe 4.3 or later, then:

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

or, from a clone, `haxelib dev hotreload-hx <clone>`. Only Linux is tested so far.

Requirements:

- A browser, or node 22.3 or later
- ES6 output (`-D js-es=6`): `-lib hotreload-hx` sets it, and a hot build set lower stops
  with a message. To ask for a later version, define it after `-lib hotreload-hx`.

## Setting up

hotreload's dev server builds the program hot, serves it, and rebuilds it when a source
changes. Give it the build's own arguments, such as an hxml:

```bash
haxe -lib hotreload-hx --run hotreload.DevServer [--port 8080] [--mount /url=dir] build.web.hxml
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
directory at `http://localhost:8080/`, and watches its class paths. The main class drives
its loop the browser's way:

```haxe
// src/Main.hx
class Main {
	static function main() {
		new hotreload.Reloader();
		Game.init();
		js.Browser.window.setInterval(() -> Game.tick(), 16);
	}
}
```

```
hotreload: serve: http://localhost:8080/ (web)
hotreload: watch: including src/
hotreload: ready
```

Each save to a source is built in the background, and the page takes on the new code
between two frames. Built without the dev server, the same sources build an ordinary
program, which is your release build.

The dev server can also be started from a macro, which checks its options as it compiles
and returns, so one hxml can start it beside other watchers; the compiler waits for it
after its macros, and it stops with the compiler however that ends:

```hxml
# watch.hxml: haxe watch.hxml
-lib hotreload-hx
--macro hotreload.DevServer.serve("build.web.hxml", {port: 8080, mounts: {"/assets": "assets"}})
```

`mounts` serves directories besides the build's output, such as assets; the sources it
watches are the build's own class paths (`-cp`), not its libraries', even in a local
repository (`haxelib newrepo`'s `.haxelib/`) inside the project (`hotreload: watch:
excluding` names those). `watch` names more directories to watch, without making them the
project's: a library's checkout you edit while the program runs, say
(`watch: ["../helix/src"]`). With
`background: true`, `serve` returns
once the server is serving and leaves it running, detached from the terminal, its messages
in `.hotreload-<port>.log` (or `log`), until it's stopped:

```bash
haxe -lib hotreload-hx --macro "hotreload.DevServer.stop(8080)"
```

Both take their port from `-D hotreload-port=<n>` when they're given none. With
`restart: true`, `serve` first stops a server this project left on the port (one started
in its directory); another project's it leaves running, and fails saying whose it is
(`stop` stops any):

```hxml
-lib hotreload-hx
-D hotreload-port=8064
--macro hotreload.DevServer.serve("build.web.hxml", {background: true, restart: true})
```

`sidecars` are commands that run beside the server, each an array of its arguments: started
once it's serving, and stopped with it however it stops (Ctrl+C, its terminal closed,
`stop`, a `restart`). An HTTPS proxy in front of it, say, for a phone on the network:

```hxml
--macro hotreload.DevServer.serve("build.web.hxml", {sidecars: [["docker", "compose", "run", "--rm", "tls"]]})
```

A sidecar's standard input is a pipe from the server, closed when the server stops; one that
doesn't stop when its input closes is killed 3 seconds later. Killing `docker` doesn't stop
its container, so a container's command should end when its input does (in Compose,
`stdin_open: true` and, for nginx,
`command: ["sh", "-c", "nginx -g 'daemon off;' & cat > /dev/null; nginx -s stop"]`). Its
output goes where the server's does. `haxe -lib hotreload-hx --run hotreload.DevServer --help` lists the server's
options.

Options:

- `--port <n>`: where it serves, 8080 by default.
- `--mount /assets=../assets`: serves another directory too, with Range requests.
- `--watch ../lib/src`: watches another directory's sources too, without making them the
  project's.
- `--reload-define <name[=value]>`: a define for reload builds only, for something the first
  build makes and reloads don't need (a wasm engine the page loads, say).
- `--no-compilation-server`: builds each reload with a `haxe` of its own.

A node program asks `HOTRELOAD_URL` for new builds (`http://localhost:8080/__hotreload` by
default). `/__hotreload_stop`, from the same machine, stops the dev server and its
compilation server.

### Trying it

`examples/hello` is a small page:

```bash
cd examples/hello
haxe dev.hxml
```

Open `http://localhost:8080/`. It prints a greeting a few times a second. Change `name`'s
first value in `src/Hello.hx` and save:

```
Hello, world! (ticks: 12, since the last reload: 12)
hello: reloading...
hotreload: static: Hello.name reset (initial value changed: "world" to "Rob")
hello: reloaded
Hello, Rob! (ticks: 16, since the last reload: 1)
```

`ticks` is kept, so it keeps counting; `name`'s first value was edited, so it's the new one;
`sinceReload` is marked `@:resetOnHotReload`, so it starts over. The greeting's first word
comes from `assets/greeting.txt`; edit it and the next greeting uses it, with nothing
rebuilt. `haxe build.hxml` is its release build, and its `.vscode/` has a Chrome launch
configuration for debugging the page while it reloads.

## The rules

There are two: *a static keeps its value across a reload, unless you edited its first
value*, and *a closure made before a reload runs its own code, though what it calls by name
is new*. There's nothing to mark. The rest of this section is what they mean in practice.

### Your code, the main class, and libraries

hotreload tells three kinds of code apart, though only for what it watches and warns about:

- **Your code:** the classes in the project's own class paths (the `-cp` directories inside
  the project). This is what's watched, and what the build warns about.
- **The main class:** reloaded like the rest, but its `main` doesn't run again.
- **Libraries:** the standard library and haxelibs, reloaded with the bundle. A library's
  checkout you edit can be watched too (`watch`).

Every class takes on its new code on a reload, and the rules for statics are the same for
all of them.

### Statics

A static keeps its value across reloads:

```haxe
static var score = 0;
static var enemies:Array<Enemy> = [];
```

Except:

- **Its first value was edited:** it resets to the new one. Change `static var speed = 3.0;`
  to `4.0`, save, and `speed` is `4.0`, whatever the program had set it to. The first value
  is compared as written, so an edit elsewhere that changes what it computes (a constant it
  reads, a function it calls) doesn't reset it.
- **It's marked `@:resetOnHotReload`:** it resets to its first value on every reload. For
  what's derived from code, such as a cache or a lookup table, that should be made again by
  the new code:

  ```haxe
  @:resetOnHotReload static var layout = computeLayout();
  ```

- **Its type was changed, and its first value wasn't:** its value is kept when it's still
  the same kind (number, bool, string, object), and reset otherwise.

A reset is said, but for `@:resetOnHotReload`'s:

```
hotreload: static: game.Tuning.speed reset (initial value changed: 3.0 to 4.0)
hotreload: static: game.State.mode reset (type changed: Int to String)
hotreload: static: game.State.widened kept (type changed: Int to Float)
```

A new static starts from its first value. One with no first value is `null` until the
program sets it. `@:resetOnHotReload` and the hooks can't be used on an instance field:
it's a build error. `@:hot`, which marked the statics a reload kept before every static was
kept, does nothing, and the build warns where it's written.

What a static holds survives with it. On each reload, the objects reachable from the statics
take on the new classes in place, so every reference to them stays good. A new field starts
from its initializer:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // new: starts at 10
}
```

hotreload walks arrays, maps, anonymous structures, classes' objects and enum values
(made again by constructor name). Shared objects stay shared and cycles stay cycles.

### Callbacks

Every call by name reaches the new code, from any code, however old. A closure made before
a reload keeps its own body, but what it calls is new, so a callback that may outlive a
reload, a load's completion, say, is best a lambda that calls a function by name:

```haxe
Models.load("ship.obj", file -> loaded(file)); // reaches the newest `loaded`
```

A bound method passed as a value (`addEventListener(CLICK, onClick)`) runs the new code
too, and the new code's `onClick` is the same function, so
`removeEventListener(CLICK, onClick)` removes the listener added before the reload. A
static function passed as a value (`Models.load("ship.obj", loaded)`) keeps its old code
unless a static holds it. The build warns about a method passed as a value, in your code
and in the main class.

### Reload hooks

A class can run code just before a reload (on the old code) and just after (on the new):

```haxe
@:beforeHotReload static function saveScratch() { ... }
@:afterHotReload static function rebuildCaches() { ... }
```

The main class uses the reloader's callbacks instead:

```haxe
var reloader = new hotreload.Reloader();
reloader.beforeReload = () -> trace("reloading");
reloader.afterReload = () -> trace("reloaded");
```

The order is: old `@:beforeHotReload` hooks, `beforeReload`, the swap, new
`@:afterHotReload` hooks, `afterReload`.

### Assets

The dev server watches the files it serves (except the bundle) and tells the program which
were saved, so it can load them again. Nothing is rebuilt; reloading the asset is up to the
program:

```haxe
var reloader = new hotreload.Reloader();
reloader.assetsChanged = urls -> for (url in urls) Game.reloadAsset(url);
```

`urls` are the files' URLs (`/assets/sounds/fire.ogg`). Deleted files are reported too;
hidden files and an editor's temporary save files aren't. The callback belongs to the main
class, so call your code through its class, as above, to reach the new version.

## How a reload works

The program loads the new bundle beside the running one and takes on its classes between
two frames. It keeps everything it made: a wasm engine, GPU state, loaded assets, open
connections.

- Every class takes on its new code, the main class included, and signature changes need
  no restart, since every caller reloads too.
- Statics follow [the rules](#statics): kept, but for an edited first value and
  `@:resetOnHotReload`.
- Objects the kept statics hold get the new classes in place. New fields start from their
  initializers, and enum values are rebuilt by constructor name.
- Old classes forward to the new ones, so leftover old code (a callback, an object nothing
  walked to) runs the new code, on the same state.
- A method reference in a static (`onFrame = Guest.frame`) points to the new code, and a
  bound method follows its method to the new code.

The bundle asks the dev server for a newer one with a long poll, so a reload starts as soon
as the build is done.

## Debugging

Reloaded code runs at full speed, and the browser's DevTools or VS Code's JavaScript
debugger work as they do for any Haxe JS build. Build with `-debug` for source maps and set
breakpoints in the `.hx` files. Each reloaded bundle has its own source map, so a
breakpoint also hits in the new code after a reload.

## Limits

- A closure made before a reload keeps its own body.
- A static function passed as a value keeps its old code unless a static holds it.
- Code that already ran isn't run again: a listener a new version of `init()` would add
  isn't added until `init()` runs. Use an `@:afterHotReload` hook for that.
- A renamed or removed field is `undefined` on carried objects, as is a new field with no
  initializer. A new field's initializer runs only on objects the reload walks to.

## Reference

### Defines

| Define                       | Meaning                                                           |
| ---------------------------- | ----------------------------------------------------------------- |
| `-D hotreload`               | a hot build (the dev server adds it)                              |
| `-D hotreload-port=<n>`      | `serve`'s and `stop`'s port when they're given none (8080 if not) |
| `-D hotreload_url=<url>`     | where the program asks for new builds                             |

Other targets build without hot reload, with a warning.

### The repo

```
haxelib.json             the package: classPath src
extraParams.hxml         --macro hotreload.Builder.init(), added by -lib hotreload-hx
src/hotreload/
  Builder.hx             the hot build: statics' first values, reload hooks, what a carried object needs
  Reloader.hx            the reloader: the main class's callbacks
  JsSwap.hx              loading a new bundle and taking on its classes
  Hooks.hx               reload hooks
  DevServer.hx           building, serving and rebuilding
  FileWatch.hx           file watching, for the dev server
docs/comparison.md       hotreload-nim and hotreload-hx side by side
tests/parity/            the behavior test: a program edited as it runs, and its builds, checked
tests/matrix/            the capability matrix behind docs/comparison.md
tests/scale/             reload time by program size, for JS and Nim
examples/hello/          a page with a reloaded class and an asset
```

`python3 tests/parity/run.py` is the test to run after a change: it exits with 1 when
something differs from what's expected.

## License

MIT. See [LICENSE](LICENSE).
