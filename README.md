# hotreload-hx

Hot reload for Haxe programs that run as JavaScript, in a browser or in node.

You save a `.hx` file and the running program switches to the new code within a moment. Nothing
restarts: the score, the level, the loaded textures, the open sockets and the GPU state are all
where you left them. It is built for programs with a loop, like games, editors and visualizers,
where a page reload throws away a lot of state and takes a long time to get back to.

The same code builds as a normal release program, with nothing extra in it.

## Try it

You need Haxe 4.3 or later and a browser. Install the library from GitHub:

```bash
haxelib git hotreload-hx https://github.com/whirlinggizmo/hotreload-hx
```

Then run the example:

```bash
cd examples/hello
haxe dev.hxml
```

Open http://localhost:8080/. The page prints a greeting a few times a second. Open
`src/Hello.hx`, change `name = "world"` to your own name, and save. The page says:

```
Hello, world! (ticks: 12, since the last reload: 12)
hello: reloading...
hotreload: static: Hello.name reset (initial value changed: "world" to "Rob")
hello: reloaded
Hello, Rob! (ticks: 16, since the last reload: 1)
```

A few things happened there:

- The new code is running, so the greeting uses the new name.
- `ticks` kept counting. Static variables keep their values across a reload.
- `name` took the new value because you edited the value it starts with. hotreload assumes that
  is what you meant, and says so in the console.
- `sinceReload` is marked `@:resetOnHotReload`, so it started over.

Try changing how often it speaks, or edit `assets/greeting.txt`. The asset change shows up on
the next greeting without a rebuild.

## Using it in your project

Add `-lib hotreload-hx` to your JS build and create a `hotreload.Reloader` in `main`:

```hxml
# build.hxml
-cp src
-lib hotreload-hx
--main Main
--js web/main.js
-debug
```

```haxe
class Main {
	static function main() {
		new hotreload.Reloader();
		Game.init();
		js.Browser.window.setInterval(() -> Game.tick(), 16);
	}
}
```

Then run your build through the dev server instead of running `haxe` directly:

```bash
haxe -lib hotreload-hx --run hotreload.DevServer build.hxml
```

```
hotreload: serve: http://localhost:8080/ (web)
hotreload: watch: including src/
hotreload: ready
```

The dev server builds the program with hot reload turned on, serves the output directory, and
watches your source directories (`-cp`). When you save, it rebuilds in the background and the
page picks up the new code between two frames. If the build fails, the errors appear in the
terminal and the page keeps running the last good build.

To make a release build, run `haxe build.hxml` as usual. Without the dev server, hot reload is
compiled out and `Reloader` does nothing.

The build must output ES6 or later (`-D js-es=6`). The library sets that for you.

## What survives a reload

### Static variables keep their values

```haxe
static var score = 0;
static var enemies:Array<Enemy> = [];
```

After a reload, `score` and `enemies` are exactly what they were. There are three exceptions:

- **You edited the initial value.** If you change `static var speed = 3.0;` to `4.0`, then
  `speed` becomes `4.0`, whatever the program had set it to. This is the usual way to tune a
  value while the program runs. Only the text of the initial value is compared. If you change
  a constant or a function that the initial value uses, the static keeps its value.
- **It is marked `@:resetOnHotReload`.** It goes back to its initial value on every reload. Use
  this for anything derived from code, such as a cache or a lookup table, so that the new code
  builds it again:

  ```haxe
  @:resetOnHotReload static var layout = computeLayout();
  ```

- **You changed its type to something incompatible.** Changing `Int` to `Float` keeps the
  value. Changing `Int` to `String` resets it.

hotreload prints a line for each reset, so nothing changes without you seeing it:

```
hotreload: static: game.Tuning.speed reset (initial value changed: 3.0 to 4.0)
hotreload: static: game.State.mode reset (type changed: Int to String)
hotreload: static: game.State.widened kept (type changed: Int to Float)
```

A static you add starts from its initial value.

### Objects get the new code

Everything reachable from your statics gets the new classes in place. This includes arrays,
maps (keys and values), sets, anonymous structures, class instances and enum values. Existing
references to those objects stay valid, shared objects stay shared, and cycles are fine.

A field you add to a class starts at its initializer on objects that already exist:

```haxe
class Enemy {
	public var hp:Int;       // kept
	public var shield = 10;  // added during a reload: existing enemies get 10
}
```

Enum values are rebuilt by constructor name, so adding or reordering constructors does not
break them. Maps keyed by enums are re-sorted to match.

### Callbacks call the new code

A method that you passed somewhere as a value runs the new code after a reload. That covers
both instance methods (`addEventListener("click", onClick)`) and static ones
(`addEventListener("keydown", Game.onKey)`). It is still the same function object, so
`removeEventListener` still removes it.

A closure (a lambda or local function) is different. It keeps the body it was created with,
but anything it calls by name is the new version. So it pays to keep closures thin and put the
work in a named function:

```haxe
Models.load("ship.obj", file -> loaded(file)); // `loaded` is always the newest version
```

### Running code around a reload

Any class can have static functions that run just before a reload (on the old code) and just
after (on the new code). They are useful for rebuilding things the new code needs:

```haxe
@:beforeHotReload static function saveScratch() { ... }
@:afterHotReload static function rebuildCaches() { ... }
```

You can also set callbacks on the `Reloader` you created in `main`:

```haxe
var reloader = new hotreload.Reloader();
reloader.beforeReload = () -> trace("reloading");
reloader.afterReload = () -> trace("reloaded");
```

They run in this order: the old `@:beforeHotReload` functions, `beforeReload`, the swap, the new
`@:afterHotReload` functions, and then `afterReload`.

### Assets

The dev server also watches the files it serves. When you save one, it tells the program
which files changed, and the program decides how to reload them. Nothing is rebuilt.

```haxe
reloader.assetsChanged = urls -> for (url in urls) Game.reloadAsset(url);
```

`urls` are the URLs the files are served at, like `/assets/sounds/fire.ogg`. Deleted files are
included. Hidden files and editor temporary files are not.

Call into your code through a class name, as above, rather than a closure. That way the call
reaches the new code after a reload.

## What a reload can't do

Some edits can't take effect without a restart. hotreload notices them and says so in the
console, instead of leaving you to wonder why the change did nothing:

```
hotreload: main: Main.main changed (not run again); use an @:afterHotReload hook
hotreload: constructor: game.Enemy changed (existing objects not constructed again)
hotreload: field: game.Enemy.shield initializer changed (existing objects keep their values)
hotreload: field: game.Enemy.hp type changed (Int to Float, existing objects keep their values)
hotreload: field: game.Enemy.hp removed, game.Enemy.health added (values not moved)
hotreload: closure: src/Game.hx:30 changed (in Game.makeCallback, ones made before the reload run the old body)
hotreload: enum: game.Mood.Angry moved (index 2 to 3, unreached values match another case)
```

These come from a few limits:

- **Code that runs once doesn't run again.** That includes `main`, constructors of existing
  objects and level setup. hotreload reports a change to `main` or a constructor. It can't tell
  that a function only runs once, so it doesn't report other one-time code. If something needs
  to run again, put it in an `@:afterHotReload` function.
- **Closures keep their old body.** A lambda is a closure too, so it has the same limit.
  hotreload can't tell whether an old closure is still around, so it reports every closure you
  edit. To keep an edit reloadable, pass a method instead (`onLoaded`), or keep the lambda to a
  single call to a named function (`file -> loaded(file)`) and make the edits in that function.
  The lambda is the one to use when the callback needs local variables, since it can pass them
  along (`file -> loaded(file, ship)`).
- **Renamed fields aren't moved.** On existing objects, a renamed or removed field is
  `undefined`. So is a new field that has no initializer.
- **Only reachable objects are updated.** An object that no static leads to keeps its old
  class, although its methods still forward to the new code. The same applies to an enum value
  with arguments. If you insert constructors before it, it can match the wrong `case`, and that
  is reported.

If something goes wrong during a reload, the program keeps running and the next save tries
again:

- A hook or callback that throws is reported. The other hooks still run and the reload
  continues.
- A new build that throws while loading (from a static initializer, for example) is thrown
  away, and the old code keeps running.
- A failure partway through the swap is reported. Save again to retry.

```
hotreload: hook: game.Level.rebuild failed (TypeError: cannot read properties of null)
hotreload: reload: cannot load /main.js (Error: bad init)
hotreload: reload: failed (TypeError: ...); save again to retry
```

## The dev server

```bash
haxe -lib hotreload-hx --run hotreload.DevServer [options] build.hxml
```

| Option                         | What it does                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------ |
| `--port <n>`                   | The port to serve on. Defaults to 8080.                                        |
| `--mount /assets=../assets`    | Serves another directory at a URL path. Range requests are supported.          |
| `--watch ../lib/src`           | Also rebuilds when files there change, for a library you are editing.          |
| `--reload-define <name[=v]>`   | A define used only for the rebuilds, not the first build.                      |
| `--no-compilation-server`      | Runs a separate `haxe` for each rebuild instead of a compilation server.       |
| `--sidecar <command>`          | Runs a command alongside the server, such as an HTTPS proxy.                    |
| `--log <file>`                 | Writes the server's output to a file.                                          |
| `--help`                       | Lists the options.                                                             |

Only your project's own source directories are watched, not the libraries it uses (including
a local `.haxelib/` repository). The startup output lists what is watched and what isn't. To
work on a library and the program together, add its source directory with `--watch`.

### Starting it from an hxml

You can also start the dev server from a macro. Then a plain `haxe watch.hxml` starts it, and
the hxml can sit alongside your other tooling:

```hxml
# watch.hxml
-lib hotreload-hx
--macro hotreload.DevServer.serve("build.hxml", {port: 8080, mounts: {"/assets": "assets"}})
```

`serve` takes these options: `port`, `mounts`, `watch`, `reloadDefines`, `compilationServer`,
`sidecars`, `background`, `log` and `restart`.

By default, the server runs until the `haxe` command ends, for example on Ctrl+C. With
`background: true`, it keeps running on its own and writes its output to
`.hotreload-<port>.log`. Stop it with:

```bash
haxe -lib hotreload-hx --macro "hotreload.DevServer.stop(8080)"
```

With `restart: true`, `serve` first stops a server that this project left running on the port.
It won't stop another project's server. Instead, it fails with a message naming that project.
Both `serve` and `stop` use `-D hotreload-port=<n>` when no port is given:

```hxml
-lib hotreload-hx
-D hotreload-port=8064
--macro hotreload.DevServer.serve("build.hxml", {background: true, restart: true})
```

### Sidecars

A sidecar is a command that starts once the server is up and stops when it stops. A typical
use is an HTTPS proxy, so you can test on a phone:

```hxml
--macro hotreload.DevServer.serve("build.hxml", {sidecars: [["docker", "compose", "run", "--rm", "tls"]]})
```

The sidecar's standard input is a pipe from the server, and the server closes it on shutdown.
A sidecar that hasn't exited 3 seconds after that is killed. Killing `docker` doesn't stop the
container, so the container's command should exit when its input closes. In Compose, set
`stdin_open: true`. For nginx, use
`command: ["sh", "-c", "nginx -g 'daemon off;' & cat > /dev/null; nginx -s stop"]`.

## Node and web workers

A node program (node 22.3 or later) works the same way. It asks the dev server for new builds
at `HOTRELOAD_URL`, which defaults to `http://localhost:8080/__hotreload`. You can also set the
URL at compile time with `-D hotreload_url=<url>`.

A web worker started from the same bundle (`new Worker("main.js")`) reloads along with the
page. A worker built from a separate hxml isn't rebuilt or reloaded.

## Debugging

Build with `-debug` to get source maps, and set breakpoints in your `.hx` files in the
browser's DevTools or VS Code. Each reload has its own source map, so breakpoints keep working
in the new code. The hello example includes a VS Code launch configuration for Chrome.

Reloaded code runs at full speed. Nothing is interpreted.

## How it works

On each reload, the program loads the new bundle next to the running one and switches over
between two frames:

1. The new classes replace the old ones, including the main class.
2. Statics are carried over, following the rules above.
3. Objects reachable from the statics are switched to the new classes in place. New fields get
   their initializers, and enum values are rebuilt.
4. The old classes forward to the new ones. Any old code still in use, such as an old callback
   or an object nothing led to, ends up running the new code on the same data.

The page waits on a long poll to the dev server, so a reload starts as soon as the build is
done.

## hxcpp and cppia

hotreload-hx used to reload native hxcpp builds as well, by loading the reloadable code as a
cppia script. That version is frozen on the
[`hxcpp`](https://github.com/whirlinggizmo/hotreload-hx/tree/hxcpp) branch. It still works,
but it gets no fixes or new features. Everything added since the split exists only on `main`:
late-bound static callbacks, kept enum constants, the reload messages, failure recovery, Map
and Set walking, and worker reloads.

Native support was dropped because cppia can never do what JavaScript can, and trying to keep
the two the same was holding the JavaScript version back:

- **Objects have a fixed layout.** In JavaScript an object is a dictionary, so a reload can give
  existing objects new methods and new fields in place. A cppia object belongs to the class
  that created it. A reload brings in new classes, and existing objects stay on the old ones
  until something rebuilds them and copies their state over.
- **The host can't be reloaded.** Everything compiled into the native host, including the main
  class, the standard library and other libraries, is fixed for the life of the program. Only
  the code in the script reloads. In JavaScript the whole bundle reloads.
- **References are typed.** The JavaScript reload walks the program's data and re-points
  functions and enum values wherever it finds them. Native code holds typed pointers, so much
  less can safely be changed.
- **Type changes are unsafe.** JavaScript accepts any value in any field, so a changed field
  type is handled when the reload runs. In cppia, changing the type of a field used across the
  host and the script means a crash or a full rebuild.

To work around these limits, the two-target version needed extra rules that JavaScript didn't:
statics had to be marked `@:hot`, callbacks had to go through generated forwarding functions,
and the build warned about method references that native couldn't follow. Dropping cppia
removed all of that.

At best, cppia can reload method bodies and new code in classes the script owns, with stricter
rules than JavaScript has. If native reload comes back, it will be a separate, narrower feature
with its own rules, not a copy of the JavaScript one.

## Working on hotreload-hx

```
src/hotreload/
  Builder.hx      the compile-time side: records what a reload needs to know
  Reloader.hx     the API the program uses
  JsSwap.hx       loads a new bundle and switches to it
  Hooks.hx        the reload hooks
  DevServer.hx    builds, serves and rebuilds
  FileWatch.hx    file watching for the dev server
tests/behavior/   edits a running program and checks the results
tests/matrix/     one program put through many kinds of edits, for reading by hand
tests/scale/      reload time by program size
examples/hello/   the example above
```

Run `python3 tests/behavior/run.py` after a change. It exits with 1 if anything differs from
what's expected. To use a local clone, run `haxelib dev hotreload-hx <clone>`. Development and
testing so far have been on Linux.

## License

MIT. See [LICENSE](LICENSE).
