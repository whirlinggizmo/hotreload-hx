# hotreload-hx

Hot reload for Haxe JavaScript applications, in the browser or in node. On each saved change,
the hotreload dev server rebuilds the bundle. The running program takes on the new classes and
keeps its state. It is meant for applications with a loop, such as a game or a tool, where a
page reload loses the loaded assets, the GPU's state and the current place in the program.
Release builds compile the same code with no reloading and no cost.

Native reload (hxcpp, through cppia) is on the [`hxcpp`](https://github.com/whirlinggizmo/hotreload-hx/tree/hxcpp)
branch. That branch holds the version that reloaded both targets under the same rules.

## Install

Requires Haxe 4.3 or later. Install with:

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

From a clone, use `haxelib dev hotreload-hx <clone>` instead. Only Linux is tested so far.

Requirements:

- A browser, or node 22.3 or later
- ES6 output (`-D js-es=6`). `-lib hotreload-hx` sets it. A hot build set to a lower version
  stops with a message. To request a later version, define it after `-lib hotreload-hx`.

## Setting up

The hotreload dev server builds the program hot, serves it, and rebuilds it when a source
changes. It takes the build's own arguments, such as an hxml:

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

The dev server adds `-lib hotreload-hx` and `-D hotreload` to the build. It serves the build's
output directory at `http://localhost:8080/` and watches the build's class paths. The main
class drives its loop the browser's way:

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

Each save to a source is built in the background. The page takes on the new code between two
frames. Without the dev server, the same sources build an ordinary program. That program is
the release build.

The dev server can also be started from a macro. The macro checks its options as it compiles
and returns, so one hxml can start the server beside other watchers. The compiler waits for
the server after its macros. The server stops when the compiler ends, however it ends:

```hxml
# watch.hxml: haxe watch.hxml
-lib hotreload-hx
--macro hotreload.DevServer.serve("build.web.hxml", {port: 8080, mounts: {"/assets": "assets"}})
```

`mounts` serves directories besides the build's output, such as assets. The watched sources
are the build's own class paths (`-cp`), not those of its libraries. This holds even for a
local repository (`haxelib newrepo`'s `.haxelib/`) inside the project. `hotreload: watch:
excluding` names those. `watch` adds directories to watch without making them part of the
project, such as a library's checkout edited while the program runs
(`watch: ["../helix/src"]`). With `background: true`, `serve` returns once the server is
serving and leaves it running, detached from the terminal, until it is stopped. Its messages
go to `.hotreload-<port>.log` (or `log`). Stop it with:

```bash
haxe -lib hotreload-hx --macro "hotreload.DevServer.stop(8080)"
```

`serve` and `stop` take their port from `-D hotreload-port=<n>` when none is given. With
`restart: true`, `serve` first stops a server this project left on the port (one started in
its directory). A server from another project is left running, and `serve` fails with a
message naming its owner. `stop` stops a server from any project. For example:

```hxml
-lib hotreload-hx
-D hotreload-port=8064
--macro hotreload.DevServer.serve("build.web.hxml", {background: true, restart: true})
```

`sidecars` are commands that run beside the server, each given as an array of its arguments.
They start once the server is serving. They stop with it, however it stops (Ctrl+C, its
terminal closed, `stop`, a `restart`). One example is an HTTPS proxy in front of the server,
for a phone on the network:

```hxml
--macro hotreload.DevServer.serve("build.web.hxml", {sidecars: [["docker", "compose", "run", "--rm", "tls"]]})
```

A sidecar's standard input is a pipe from the server, closed when the server stops. A sidecar
that does not stop when its input closes is killed 3 seconds later. Killing `docker` does not
stop its container, so a container's command needs to end when its input does. In Compose, set
`stdin_open: true`. For nginx, also set
`command: ["sh", "-c", "nginx -g 'daemon off;' & cat > /dev/null; nginx -s stop"]`. A
sidecar's output goes where the server's does. `haxe -lib hotreload-hx --run hotreload.DevServer --help` lists the server's
options.

Options:

- `--port <n>`: the port to serve on. Defaults to 8080.
- `--mount /assets=../assets`: serves another directory as well, with Range requests.
- `--watch ../lib/src`: watches another directory's sources as well, without making them part
  of the project.
- `--reload-define <name[=value]>`: a define for reload builds only. It is meant for something
  the first build makes and reloads do not need, such as a wasm engine the page loads.
- `--no-compilation-server`: builds each reload with a separate `haxe`.

A node program requests new builds from `HOTRELOAD_URL` (defaults to
`http://localhost:8080/__hotreload`). A request to `/__hotreload_stop` from the same machine
stops the dev server and its compilation server.

A web worker started from the hot bundle (`new Worker("main.js")`) reloads with the page.
Each of them asks the dev server for new builds and takes on the new code on its own. A
worker built from another hxml is not rebuilt or reloaded.

### Trying it

`examples/hello` is a small page:

```bash
cd examples/hello
haxe dev.hxml
```

Open `http://localhost:8080/`. The page prints a greeting a few times a second. Change the
first value of `name` in `src/Hello.hx` and save:

```
Hello, world! (ticks: 12, since the last reload: 12)
hello: reloading...
hotreload: static: Hello.name reset (initial value changed: "world" to "Rob")
hello: reloaded
Hello, Rob! (ticks: 16, since the last reload: 1)
```

`ticks` is kept, so it keeps counting. The first value of `name` was edited, so `name` takes
the new one. `sinceReload` is marked `@:resetOnHotReload`, so it starts over. The greeting's
first word comes from `assets/greeting.txt`. After an edit to that file, the next greeting
uses it, with nothing rebuilt. `haxe build.hxml` is the example's release build. Its
`.vscode/` has a Chrome launch configuration for debugging the page while it reloads.

## The rules

There are two rules. *A static keeps its value across a reload, unless its first value was
edited.* *A closure made before a reload runs its own code, but what it calls by name is new.*
Nothing needs to be marked. The rest of this section describes what the rules mean in
practice.

### Project code, the main class, and libraries

hotreload distinguishes three kinds of code. The distinction applies only to what the dev
server watches:

- **Project code:** the classes in the project's own class paths (the `-cp` directories inside
  the project). This code is watched.
- **The main class:** reloaded like the rest, but its `main` does not run again.
- **Libraries:** the standard library and haxelibs, reloaded with the bundle. A library's
  checkout under edit can be watched as well (`watch`).

Every class takes on its new code on a reload. The rules for statics are the same for all of
them.

### Statics

A static keeps its value across reloads:

```haxe
static var score = 0;
static var enemies:Array<Enemy> = [];
```

Exceptions:

- **Its first value was edited:** it resets to the new one. After `static var speed = 3.0;`
  is changed to `4.0` and saved, `speed` is `4.0`, whatever value the program had set. The
  first value is compared as written. An edit elsewhere that changes what it computes (a
  constant it reads, a function it calls) does not reset it.
- **It is marked `@:resetOnHotReload`:** it resets to its first value on every reload. This
  suits values derived from code, such as a cache or a lookup table, for the new code to
  make again:

  ```haxe
  @:resetOnHotReload static var layout = computeLayout();
  ```

- **Its type was changed, and its first value was not:** its value is kept when it is still
  the same kind (number, bool, string, object), and reset otherwise.

Each reset is reported, except a reset of a `@:resetOnHotReload` static:

```
hotreload: static: game.Tuning.speed reset (initial value changed: 3.0 to 4.0)
hotreload: static: game.State.mode reset (type changed: Int to String)
hotreload: static: game.State.widened kept (type changed: Int to Float)
```

A new static starts from its first value. A static with no first value is `null` until the
program sets it. `@:resetOnHotReload` and the hooks cannot be used on an instance field. Such
a use is a build error. `@:hot` marked the statics a reload kept, before every static was
kept. It now does nothing, and the build warns where it is written.

What a static holds survives with it. On each reload, the objects reachable from the statics
take on the new classes in place, so every reference to them stays valid. A new field starts
from its initializer:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // new: starts at 10
}
```

hotreload walks arrays, maps (keys and values), sets, anonymous structures, class instances
and enum values. Enum values are made again by constructor name. An enum-keyed map is sorted
again, so it still finds its keys after constructors are reordered. Shared objects stay
shared, and cycles stay cycles.

An enum constant with no arguments (`Sad`) is the same object across reloads, even where the
walk does not reach, such as inside a closure. It still matches its `case` and equals the new
code's `Sad`, even with constructors added or moved before it. A value with arguments
(`Angry(3)`) that the walk does not reach cannot be updated. When its constructor moves, the
value matches another `case`, and the reload reports it:

```
hotreload: enum: game.Mood.Angry moved (index 2 to 3, unreached values match another case)
```

### Callbacks

Every call by name reaches the new code, from any code, however old. A method passed as a
value runs the new code too, whether it is an object's (`addEventListener(CLICK, onClick)`)
or a static function (`addEventListener("keydown", Game.onKey)`). The new code's `onClick`
or `Game.onKey` is the same function, so `removeEventListener` removes the listener added
before the reload.

A closure (a lambda, a local function) made before a reload keeps its own body, but what
it calls is new:

```haxe
Models.load("ship.obj", file -> loaded(file)); // reaches the newest `loaded`
```

### Reload hooks

A class can run code just before a reload (on the old code) and just after (on the new code):

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
ones were saved, so the program can load them again. Nothing is rebuilt. Reloading the asset
is up to the program:

```haxe
var reloader = new hotreload.Reloader();
reloader.assetsChanged = urls -> for (url in urls) Game.reloadAsset(url);
```

`urls` are the files' URLs (`/assets/sounds/fire.ogg`). Deleted files are reported too.
Hidden files and an editor's temporary save files are not. The callback belongs to the main
class. Call project code through its class, as above, to reach the new version.

## How a reload works

The program loads the new bundle beside the running one and takes on its classes between
two frames. It keeps everything it made: a wasm engine, GPU state, loaded assets, open
connections.

- Every class takes on its new code, the main class included. Signature changes need no
  restart, since every caller reloads too.
- Statics follow [the rules](#statics). They are kept, except for an edited first value and
  `@:resetOnHotReload`.
- Objects the kept statics hold get the new classes in place. New fields start from their
  initializers, and enum values are rebuilt by constructor name. Enum constants with no
  arguments are the running code's, with the new code's indices.
- Old classes forward to the new ones, so leftover old code (a callback, an object nothing
  walked to) runs the new code, on the same state.
- A method reference in a static (`onFrame = Guest.frame`) points to the new code, and a
  bound method follows its method to the new code.

The bundle asks the dev server for a newer one with a long poll, so a reload starts as soon
as the build is done.

## When something fails

A reload hook (or `beforeReload`, `afterReload`) that throws does not stop the reload or the
other hooks. It is reported:

```
hotreload: hook: game.Level.rebuild failed (TypeError: cannot read properties of null)
```

A new bundle that fails as it loads, such as one whose static initializer throws, is
dropped, and the running code continues unchanged. A swap that throws partway leaves some
classes swapped, and is reported. In each case the next saved edit reloads again:

```
hotreload: reload: cannot load /main.js (Error: bad init)
hotreload: reload: failed (TypeError: ...); save again to retry
```

## Debugging

Reloaded code runs at full speed. The browser's DevTools and VS Code's JavaScript debugger
work as they do for any Haxe JS build. Build with `-debug` for source maps and set
breakpoints in the `.hx` files. Each reloaded bundle has its own source map, so a
breakpoint also hits in the new code after a reload.

## Limits

A reload reports each saved edit that it cannot bring in:

```
hotreload: main: Main.main changed (not run again); use an @:afterHotReload hook
hotreload: constructor: game.Enemy changed (existing objects not constructed again)
hotreload: field: game.Enemy.shield initializer changed (existing objects keep their values)
hotreload: field: game.Enemy.hp type changed (Int to Float, existing objects keep their values)
hotreload: field: game.Enemy.hp removed, game.Enemy.health added (values not moved)
hotreload: closure: src/Game.hx:30 changed (in Game.makeCallback, ones made before the reload run the old body)
hotreload: enum: game.Mood.Angry moved (index 2 to 3, unreached values match another case)
```

- A closure made before a reload keeps its own body. A reload cannot tell whether such a
  closure is still alive, so every edited closure is reported.
- Code that already ran is not run again. A changed `main` or constructor is reported.
  Other code that ran once, such as a function that ran when a level loaded, cannot be told
  apart from code that runs every frame, and is not reported. An `@:afterHotReload` hook
  runs code on each reload.
- A renamed or removed field is `undefined` on carried objects, as is a new field with no
  initializer. A new field's initializer runs only on objects the reload walks to.
- An enum value with arguments that the reload does not reach keeps its constructor's old
  index. When constructors are added or moved before it, it matches another `case`.

## Reference

### Defines

| Define                       | Meaning                                                                   |
| ---------------------------- | ------------------------------------------------------------------------- |
| `-D hotreload`               | a hot build (the dev server adds it)                                      |
| `-D hotreload-port=<n>`      | the port for `serve` and `stop` when none is given (defaults to 8080)     |
| `-D hotreload_url=<url>`     | where the program requests new builds                                     |

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
tests/behavior/          the behavior test: a program edited as it runs, and its builds, checked
tests/matrix/            the capability matrix: one program, many kinds of edit, read by hand
tests/scale/             reload time by program size
examples/hello/          a page with a reloaded class and an asset
```

`python3 tests/behavior/run.py` is the test to run after a change. It exits with 1 when
something differs from what is expected.

## License

MIT. See [LICENSE](LICENSE).
