package hotreload;

#if eval
import eval.luv.Buffer;
import eval.luv.Handle;
import eval.luv.Loop;
import eval.luv.SockAddr;
import eval.luv.Stream;
import eval.luv.Tcp;
import eval.luv.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Mutex;
import sys.thread.Thread;

using StringTools;

/**
	Provides hot reload for a JS build.

	The dev server builds the project hot, serves it, and rebuilds it when a source changes. The
	page (or a node program) loads each new build in place of the running one (Reloader, JsSwap).

	```
	haxe -lib hotreload-hx --run hotreload.DevServer [options] <build arguments>
	```

	The build arguments are the build's own, such as an hxml (`build.web.hxml`). The dev server
	adds `-D hotreload`. Options:

	- `--port <n>`: The port served on. Defaults to 8080.
	- `--mount <url>=<dir>`: Serves a directory at a path as well, as in `--mount /assets=../assets`.
	- `--watch <dir>`: Watches a directory's sources as well. A change there triggers a rebuild,
	  but the sources do not become the project's (for example, a library checkout being edited).
	- `--reload-define <name[=value]>`: A define for the reload builds only, not the first. It
	  suits something the page loads once, which the first build makes and a reload build does
	  not need (for example, a wasm engine the page loads).
	- `--no-compilation-server`: Builds each reload with a separate `haxe` process.
	- `--stop-with-stdin`: Stops when standard input closes. A program that starts the server with
	  a pipe there stops it when that program ends, however it ends (`serve` uses this).
	- `--log <file>`: Writes the server's messages, and the builds', to the file instead of the
	  terminal.
	- `--sidecar <command>`: A command that runs beside the server (for example, an HTTPS proxy in
	  front of it). It starts once the server is serving and stops with it. The command is a JSON
	  array of its arguments (`["docker", "compose", "run", "--rm", "tls"]`), or one string split
	  at spaces. Its standard input is a pipe from the server, closed when the server stops,
	  however it stops. A command that stops when its input closes stops with the server. One
	  that does not is killed after 3 s.
	- `--help`: Prints these options.

	A macro can also start it, from an hxml of its own beside others (for example, a watcher's):

	```
	-lib hotreload-hx
	--macro hotreload.DevServer.serve("build.web.hxml", {port: 8064, mounts: {"/assets": "assets"}})
	```

	`serve` starts the server and returns. The compiler waits for it once its macros are done,
	and the server stops with the compiler, by Ctrl+C or otherwise. With `background: true`, the
	server keeps running after the compiler, with its messages in a log, until it is stopped:

	```
	haxe -lib hotreload-hx --macro "hotreload.DevServer.stop(8064)"
	```

	The server serves the build's output directory at `/`, with Range requests (an engine may
	stream assets). `/__hotreload` reports the latest build. With `?since=<n>`, it answers once a
	build newer than n exists. `/__hotreload_assets` reports which served files changed, with
	`?since=<n>` the same way. `/__hotreload_project` reports the directory the server was started
	in. `/__hotreload_stop` stops the server, and is accepted only from this machine.

	Ten times a second, the server checks the project's sources for changes. The sources are the
	build's class paths inside its directory (`-cp`), or else the main class's directory, with
	their subdirectories, plus the build's hxml files. Once they stop changing, the server rebuilds
	from the hxml as it is then. A `-lib` or `-cp` added to it is used, and an added class path is
	watched. The rebuild goes through a compilation server the dev server starts, and the page,
	which waits to hear of it, loads it. Compiler errors go to this terminal (or the log), and the
	page keeps running the build it has.
**/
class DevServer {
	static inline var HELP = "usage: haxe -lib hotreload-hx --run hotreload.DevServer [options] <build arguments>

Builds the JS build (an hxml, say) hot, serves its output directory, and rebuilds it as its sources change; the page swaps the new
code in as it runs.

  --port <n>                  where it serves (8080)
  --mount <url>=<dir>         a directory served at a path too: --mount /assets=assets
  --watch <dir>               a directory whose sources are watched too, not the project's (a library being edited)
  --reload-define <name[=v]>  a define for the reload builds only, not the first
  --no-compilation-server     each build with a haxe of its own
  --sidecar <command>         a command run beside it, started once it is serving and stopped with it (an HTTPS proxy, say):
                              a JSON array of its arguments, or them in one string, split at spaces
  --log <file>                its messages, and the builds', to a file
  --stop-with-stdin           stops when its standard input closes
  --help                      this

From an hxml: --macro hotreload.DevServer.serve(\"build.web.hxml\", {port: 8064, mounts: {\"/assets\": \"assets\"}})
(options: port, mounts, watch, reloadDefines, compilationServer, sidecars, background, log, restart); stopped with
--macro hotreload.DevServer.stop(8064).";

	/**
		The interval between source checks, in seconds.

		A check is a directory walk, which is cheap at this size.
	**/
	static inline var CHECK_INTERVAL = 0.1;

	static var port = 8080;
	static var mounts = new Map<String, String>();
	static var reloadDefines = new Array<String>();

	/**
		The directories watched besides the project's (`--watch`).

		A change in one triggers a rebuild, but its sources are not treated as the project's code.
	**/
	static var watched = new Array<String>();
	static var root:String;

	/**
		The directory the server was started in, which is its project.

		A restart (`serve`'s) checks that it matches.
	**/
	static var project = Path.removeTrailingSlashes(Path.normalize(Sys.getCwd()));
	static var bundleUrl:String;
	static var config:Builder.JsConfig;

	/**
		The build's arguments, as provided, and the directory they are relative to.

		Every build reads its hxml again, so the next build uses an edited one (a -lib or -cp
		added).
	**/
	static var build:Array<String>;

	static var buildCwd = Sys.getCwd();
	static var version = 0;
	static var failed = false;
	static var lock = new Mutex();

	/** The log file for the server's messages (`--log`), or null for the terminal. **/
	static var log:sys.io.FileOutput;

	static var logLock = new Mutex();

	/**
		Gets or sets a value indicating whether the server is running.

		A stop (`/__hotreload_stop`) clears it, which ends the watchers' loops and the serving loop.
	**/
	static var running = true;

	/**
		The long polls being held.

		Each is answered once its condition is met, its time is up, or the server stops.
	**/
	static var waiting = new Array<{ready:() -> Bool, end:Float, answer:() -> Void}>();

	/**
		The commands run beside the server (`--sidecar`), and the ones running.

		The serving loop starts them. When it stops, it stops them before it lets the process end.
	**/
	static var sidecars = new Array<Array<String>>();

	static var sidecarsRunning = new Array<{process:eval.luv.Process, input:eval.luv.Pipe}>();
	static var sidecarsStopped = new sys.thread.Lock();

	static var assetVersion = 0;

	/** The served files' changes, with one version per settled batch and its URLs (`/__hotreload_assets`). **/
	static var assetChanges = new Array<{version:Int, urls:Array<String>}>();

	static function main() {
		var args = Sys.args();
		if (args[0] == "--compilation-server") {
			compilationServerUntilStdinCloses(args[1]);
			return;
		}
		build = [];
		var useServer = true;
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "--port":
					port = Std.parseInt(args[++i]);
				case "--mount":
					var m = args[++i].split("=");
					mounts.set("/" + m[0].replace("\\", "/").split("/").filter(s -> s != "").join("/"), FileSystem.absolutePath(m[1]));
				case "--watch":
					watched.push(Path.removeTrailingSlashes(Path.normalize(FileSystem.absolutePath(args[++i]))));
				case "--no-compilation-server":
					useServer = false;
				case "--reload-define":
					reloadDefines.push(args[++i]);
				case "--log":
					log = File.write(args[++i]);
				case "--sidecar":
					var command = args[++i];
					sidecars.push(command.startsWith("[") ? haxe.Json.parse(command) : [for (w in command.split(" ")) if (w != "") w]);
				case "--help" | "-h":
					Sys.println(HELP);
					Sys.exit(0);
				case "--stop-with-stdin":
					// The pipe's other end closes when its program ends, killed or not, on every system.
					Thread.create(() -> {
						try {
							while (true)
								Sys.stdin().readByte();
						} catch (_) {}
						running = false;
					});
				default:
					build.push(args[i]);
			}
			i++;
		}
		if (build.length == 0) {
			say(HELP);
			Sys.exit(1);
		}

		// The first build is hot and writes a config file that describes it. The file is in the
		// system's temporary directory, so one a stopped build leaves is not left in the project.
		var configFile = Path.join([tempDir(), "hotreload-" + Std.random(1 << 30) + ".json"]);
		say("hotreload: build: started");
		// The library is added whether the build names it or not.
		var code = runHaxe(build.concat(["-lib", "hotreload-hx", "-D", "hotreload", "-D", 'hotreload_config=$configFile']));
		if (code != 0 || !FileSystem.exists(configFile)) {
			if (FileSystem.exists(configFile))
				FileSystem.deleteFile(configFile);
			say(code != 0 ? "hotreload: build: failed" : "hotreload: build: not hot (a JS build with -lib hotreload-hx is needed)");
			Sys.exit(1);
		}
		config = haxe.Json.parse(File.getContent(configFile));
		FileSystem.deleteFile(configFile);
		root = Path.directory(config.js);
		bundleUrl = "/" + Path.withoutDirectory(config.js);

		// The port comes first. If it is taken, there is nothing to serve, and an error beats a page
		// that never loads. The socket is libuv's (eval.luv's). Its bind reuses the address, so a
		// restart does not wait out the last run's closed connections, and it reports a failure.
		// sys.net.Socket does neither on eval.
		var loop = Loop.init().resolve();
		var server = Tcp.init(loop).resolve();
		var failure:String = null;
		switch (server.bind(SockAddr.ipv4("0.0.0.0", port).resolve())) {
			case Error(e): failure = e.toString();
			case Ok(_):
		}
		// libuv reports a bind's address in use at the listen.
		if (failure == null)
			Stream.listen(server, result -> switch (result) {
				case Error(e): failure = e.toString();
				case Ok(_): accept(loop, server);
			}, 32);
		if (failure != null) {
			say('hotreload: serve: cannot use port $port ($failure); choose another with --port <n>');
			Sys.exit(1);
		}
		var compilationServer = useServer ? startCompilationServer() : null;
		Thread.create(() -> serveRequests(loop, server));
		say('hotreload: serve: http://localhost:$port/ (${relative(root)})');
		for (url => dir in mounts)
			say('hotreload: serve: $url/ (${relative(dir)})');
		sayWatch();
		Thread.create(watchAssets);
		watch(compilationServer);
		// The serving loop stops the sidecars as it stops, in a few seconds at most.
		sidecarsStopped.wait(5);
		// The compilation server's shell sees this process end, and stops the compilation server.
		say("hotreload: stopped");
		Sys.exit(0);
	}

	#if macro
	static var macroLoop:Loop;
	static var macroExit = 0;

	/**
		Returns the port for `serve` and `stop` when none is provided.

		The port is `-D hotreload-port=<n>`'s, or 8080 if it is omitted, so an hxml states it once.
	**/
	static function macroPort():Int {
		var defined = haxe.macro.Context.definedValue("hotreload-port");
		var port = defined == null ? null : Std.parseInt(defined);
		if (defined != null && port == null)
			haxe.macro.Context.fatalError('hotreload: -D hotreload-port=$defined is not a port', haxe.macro.Context.currentPos());
		return port == null ? 8080 : port;
	}

	/**
		Starts the dev server from a macro, as in `--macro hotreload.DevServer.serve(...)`.

		The call returns at once, so the hxml's other macros run too. Once they are done, the
		compiler waits for the server. The server stops with the compiler, because its standard
		input is a pipe from it (`--stop-with-stdin`).

		With `restart: true`, a dev server this project left on the port (one started in this
		directory) is stopped first. Another project's is not, and the call fails with an error
		that names its directory.

		With `background: true`, the call returns once the server is serving, or fails as the
		server does. The server keeps running after the compiler, detached from this terminal, so
		Ctrl+C here and closing the terminal leave it running. Its messages go to `log`, and
		`stop(port)` stops it.

		@param build  The build's arguments: an hxml, or an array of arguments.
		@param options  Optional. `port` defaults to `-D hotreload-port=<n>`'s, or 8080.
		`mounts`, `watch`, `reloadDefines`, `compilationServer` and `sidecars` match the
		command-line options. Each sidecar is an array of its arguments. `log` defaults to
		`.hotreload-<port>.log`.
	**/
	public static function serve(build:haxe.extern.EitherType<String, Array<String>>, ?options:{
		?port:Int,
		?mounts:haxe.DynamicAccess<String>,
		?watch:Array<String>,
		?reloadDefines:Array<String>,
		?compilationServer:Bool,
		?background:Bool,
		?log:String,
		?restart:Bool,
		?sidecars:Array<Array<String>>
	}) {
		var port = options != null && options.port != null ? options.port : macroPort();
		if (options != null && options.restart == true)
			stopOwn(port);
		var background = options != null && options.background == true;
		var args = ["-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--port", Std.string(port)];
		if (options != null) {
			if (options.mounts != null)
				for (url => dir in options.mounts)
					args = args.concat(["--mount", '$url=$dir']);
			if (options.watch != null)
				for (dir in options.watch)
					args = args.concat(["--watch", dir]);
			if (options.reloadDefines != null)
				for (d in options.reloadDefines)
					args = args.concat(["--reload-define", d]);
			if (options.compilationServer == false)
				args.push("--no-compilation-server");
			if (options.sidecars != null)
				for (command in options.sidecars)
					args = args.concat(["--sidecar", haxe.Json.stringify(command)]);
		}
		var logFile = null;
		if (background) {
			logFile = FileSystem.absolutePath(options.log != null ? options.log : '.hotreload-$port.log');
			// A last run's log says nothing about this one, so it is deleted. Windows does not release a
			// running server's log. One just stopped (by stop(), just before) may take a moment to end.
			// Past that, it is still running.
			var tries = 0;
			while (FileSystem.exists(logFile))
				try {
					FileSystem.deleteFile(logFile);
				} catch (_) {
					if (++tries < 30) {
						Sys.sleep(0.1);
						continue;
					}
					haxe.macro.Context.fatalError('hotreload: background: $logFile is in use (a dev server still running in the background); '
						+ 'to stop it: haxe -lib hotreload-hx --macro "hotreload.DevServer.stop($port)"', haxe.macro.Context.currentPos());
				}
			args = args.concat(["--log", logFile]);
		} else {
			args.push("--stop-with-stdin");
		}
		args = args.concat(Std.isOfType(build, String) ? [(build : String)] : (build : Array<String>));

		var loop = background ? Loop.init().resolve() : foregroundLoop();
		var pipe = eval.luv.Pipe.init(loop).resolve();
		var stdin = eval.luv.Process.toParentPipe(eval.luv.Process.stdin, pipe, true, false, false);
		// In the background, the server is detached. On Unix, it gets a session of its own. On
		// Windows, it gets no console and leaves libuv's job, which would end it with the compiler.
		// This terminal's Ctrl+C and closing it leave it running. Its builds start hidden (--log).
		var redirect = background ? [stdin] : [
			stdin,
			eval.luv.Process.inheritFd(eval.luv.Process.stdout, 1),
			eval.luv.Process.inheritFd(eval.luv.Process.stderr, 2)
		];
		// It does not inherit this process's stdout and stderr, which Windows would hand it.
		// Whatever reads them (an editor's task) would wait for it.
		if (background)
			eval.luv.Process.disableStdioInheritance();
		var exited = false;
		var onExit = (p:eval.luv.Process, status:eval.integers.Int64, signal) -> {
			exited = true;
			if (status.toInt() != 0)
				macroExit = status.toInt();
			Handle.close(pipe, () -> {});
			Handle.close(p, () -> {});
		};
		var process = switch (eval.luv.Process.spawn(loop, "haxe", [for (a in ["haxe"].concat(args)) (a : eval.NativeString)], {
			redirect: redirect,
			onExit: onExit,
			detached: background,
			windowsHide: background
		})) {
			case Error(e):
				haxe.macro.Context.fatalError('hotreload: serve: cannot start the server ($e)', haxe.macro.Context.currentPos());
			case Ok(p): p;
		}
		if (!background)
			return;

		// Once the server is serving, or has failed, its messages so far are printed here.
		var said = "";
		while (true) {
			loop.run(NOWAIT);
			said = try File.getContent(logFile) catch (_) "";
			if (exited || said.contains("hotreload: ready"))
				break;
			Sys.sleep(0.1);
		}
		if (said.trim() != "")
			Sys.println(said.rtrim());
		if (exited)
			Sys.exit(macroExit != 0 ? macroExit : 1);
		Sys.println('hotreload: background: log in $logFile; to stop it: haxe -lib hotreload-hx --macro "hotreload.DevServer.stop($port)"');
		// The process continues without this one. Only the handles are released.
		Handle.close(pipe, () -> {});
		Handle.close(process, () -> {});
		loop.run(NOWAIT);
	}

	/**
		Returns the loop that the processes the macros start run on in this terminal.

		Once the hxml's macros are done, the compiler runs the loop until all of them have ended.
		The compiler then fails if the server failed, as an hxml with --run does.
	**/
	static function foregroundLoop():Loop {
		if (macroLoop == null) {
			macroLoop = Loop.init().resolve();
			haxe.macro.Context.onAfterGenerate(() -> {
				macroLoop.run(DEFAULT);
				if (macroExit != 0)
					Sys.exit(macroExit);
			});
		}
		return macroLoop;
	}

	/**
		Stops the dev server serving on a port of this machine (`/__hotreload_stop`).

		A typical use is `--macro hotreload.DevServer.stop(8064)`, for one `serve` left in the
		background. A port with nothing serving is not an error, so an hxml can stop a last run's
		server before its `serve`.

		@param port  Optional. Defaults to `-D hotreload-port=<n>`'s, or 8080.
	**/
	public static function stop(?port:Int) {
		if (port == null)
			port = macroPort();
		var answer = ask(port, "/__hotreload_stop");
		if (answer == null) {
			Sys.println('hotreload: stop: nothing serving on port $port');
			return;
		}
		if (answer != "stopping")
			haxe.macro.Context.fatalError('hotreload: stop: port $port is not served by a dev server', haxe.macro.Context.currentPos());
		// The server is gone once the port is free.
		for (_ in 0...100) {
			if (ask(port, null) == null) {
				Sys.println('hotreload: stop: done (port $port)');
				return;
			}
			Sys.sleep(0.1);
		}
		haxe.macro.Context.fatalError('hotreload: stop: failed (the dev server on port $port is still serving)', haxe.macro.Context.currentPos());
	}

	/**
		Stops the server on the port for a restart, if it is this project's (started in this directory).

		Another project's server is left running, and the build fails with an error.
	**/
	static function stopOwn(port:Int) {
		var answer = ask(port, "/__hotreload_project");
		if (answer == null)
			return;
		var key = (dir:String) -> {
			var d = Path.removeTrailingSlashes(Path.normalize(dir));
			Sys.systemName() == "Windows" ? d.toLowerCase() : d;
		}
		var devServer = answer != "" && !answer.startsWith("HTTP");
		if (devServer && key(answer) == key(Sys.getCwd())) {
			stop(port);
			return;
		}
		var stopIt = 'haxe -lib hotreload-hx --macro "hotreload.DevServer.stop($port)"';
		haxe.macro.Context.fatalError(devServer ? 'hotreload: restart: port $port is served by another project\'s dev server ($answer); to stop it anyway: $stopIt'
			: 'hotreload: restart: port $port is in use, not by a dev server this can restart (one from an older hotreload-hx stops with: $stopIt)',
			haxe.macro.Context.currentPos());
	}

	/**
		Returns the body of a GET of a path from a port of this machine.

		A response other than 200 gives its status line instead of the body.

		@param path  The path to request. With null, only whether something serves is checked.
		@return  The body or status line, "" for a null path, or null if nothing serves there.
	**/
	static function ask(port:Int, path:Null<String>):Null<String> {
		var socket = new Socket();
		try {
			socket.connect(new Host("127.0.0.1"), port);
		} catch (_) {
			socket.close();
			return null;
		}
		if (path == null) {
			socket.close();
			return "";
		}
		var response = try {
			socket.output.writeString('GET $path HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n');
			socket.input.readAll().toString();
		} catch (_) "";
		socket.close();
		var head = response.indexOf("\r\n\r\n");
		var status = response.split("\r\n")[0];
		return status.indexOf(" 200 ") > 0 && head >= 0 ? response.substr(head + 4) : status;
	}
	#end

	// --- building ---

	static function watch(compilationServer:String) {
		var sourceWatch = new FileWatch(sources);
		// This follows the sources' first stamps, so a save from here on is a change.
		// A script waits for this message.
		say("hotreload: ready");
		while (running) {
			Sys.sleep(CHECK_INTERVAL);
			// A build starts once the sources have stopped changing (FileWatch).
			var paths = sourceWatch.check();
			if (paths != null && rebuild(paths, compilationServer))
				sourceWatch.relist();
		}
	}

	/**
		Watches the served files (the output directory's and the mounts'), excluding the bundle.

		Once a save settles, the page receives each saved file's URL and loads the file again in
		place. Nothing is built.
	**/
	static function watchAssets() {
		var assetWatch = new FileWatch(served);
		while (running) {
			Sys.sleep(CHECK_INTERVAL);
			var urls = assetWatch.check();
			if (urls == null)
				continue;
			lock.acquire();
			assetVersion++;
			assetChanges.push({version: assetVersion, urls: urls});
			lock.release();
			say('hotreload: assets: changed (${urls.join(", ")})');
		}
	}

	/** Returns every served file's path, by its URL. **/
	static function served():Map<String, String> {
		var result = new Map<String, String>();
		var bundle = Path.normalize(FileSystem.absolutePath(config.js));
		function walk(dir:String, url:String) {
			for (entry in (try FileSystem.readDirectory(dir) catch (_) [])) {
				if (entry.startsWith("."))
					continue;
				var path = dir + "/" + entry;
				if (FileSystem.isDirectory(path))
					walk(path, url + "/" + entry);
				else if (Path.normalize(FileSystem.absolutePath(path)) != bundle && !entry.endsWith(".map"))
					result.set(url + "/" + entry, path);
			}
		}
		walk(root, "");
		for (url => dir in mounts)
			walk(dir, url);
		return result;
	}

	/** Returns the system's directory for temporary files: TMPDIR, TEMP or TMP, or else /tmp. **/
	static function tempDir():String {
		for (name in ["TMPDIR", "TEMP", "TMP"]) {
			var dir = Sys.getEnv(name);
			if (dir != null && dir != "" && FileSystem.exists(dir))
				return dir;
		}
		return FileSystem.exists("/tmp") ? "/tmp" : Sys.getCwd();
	}

	/**
		Reports the directories watched, and the class paths in the project that are excluded (its
		local repository's libraries).
	**/
	static function sayWatch() {
		say('hotreload: watch: including ${[for (d in config.dirs.concat(watched)) relative(d) + "/"].join(", ")}');
		var excluded = config.excluded == null ? [] : config.excluded;
		if (excluded.length > 0)
			say('hotreload: watch: excluding ${[for (d in excluded) relative(d) + "/"].join(", ")} (libraries in the project\'s .haxelib/)');
	}

	/**
		Builds again for the changed files.

		@return  Whether the directories watched changed with the build.
	**/
	static function rebuild(changed:Array<String>, compilationServer:String):Bool {
		say('hotreload: build: started (${[for (p in changed) relative(p)].join(", ")})');
		var start = haxe.Timer.stamp();
		lock.acquire();
		var next = version + 1;
		lock.release();
		// The changed sources go through a file whose path (a define) is the same each build. The
		// config file the build describes itself in has a fixed path too.
		var list = Path.join([Path.directory(config.js), ".hotreload-changed"]);
		File.saveContent(list, [for (p in changed) if (p.endsWith(".hx")) p].join("\n"));
		var configFile = Path.join([Path.directory(config.js), ".hotreload-config.json"]);
		var args = ["--cwd", buildCwd].concat(build).concat(["-lib", "hotreload-hx", "-D", "hotreload", "-D", "hotreload_reload",
			"-D", 'hotreload_invalidate=$list', "-D", 'hotreload_config=$configFile']);
		for (d in reloadDefines)
			args = args.concat(["-D", d]);
		if (compilationServer != null)
			args = ["--connect", compilationServer].concat(args);
		var code = runHaxe(args);
		// An edited hxml may have changed the class paths. The new ones are watched from now on.
		var relisted = false;
		if (code == 0 && FileSystem.exists(configFile)) {
			var made:Builder.JsConfig = try haxe.Json.parse(File.getContent(configFile)) catch (_) null;
			try FileSystem.deleteFile(configFile) catch (_) {}
			if (made != null && (made.dirs.join("|") != config.dirs.join("|") || Std.string(made.excluded) != Std.string(config.excluded))) {
				config.dirs = made.dirs;
				config.excluded = made.excluded;
				relisted = true;
				sayWatch();
			}
		}
		lock.acquire();
		if (code == 0) {
			stamp(next);
			version = next;
			failed = false;
		} else {
			failed = true;
		}
		lock.release();
		var ms = Math.round((haxe.Timer.stamp() - start) * 1000);
		say(code == 0 ? 'hotreload: build: done ($ms ms)' : "hotreload: build: failed (continuing with last successful build)");
		return relisted;
	}

	/**
		Writes a build's number on its bundle's first line, so the bundle knows which build it is
		(JsSwap).

		The number goes on the line Haxe's comment is on, so no line moves. A define is not used,
		because a value that changed each build would give the compilation server a new context
		each time.
	**/
	static function stamp(n:Int) {
		var js = File.getContent(config.js);
		File.saveContent(config.js, 'globalThis.__hotreload_built = $n; ' + js);
	}

	/**
		Returns the .hx files in the watched directories (the project's, and `--watch`'s) and their
		subdirectories, and the build's hxml files.
	**/
	static function sources():Map<String, String> {
		var result = new Map<String, String>();
		function walk(dir:String) {
			for (entry in (try FileSystem.readDirectory(dir) catch (_) [])) {
				var path = dir + "/" + entry;
				if (FileSystem.isDirectory(path))
					walk(path);
				else if (entry.endsWith(".hx"))
					result.set(path, path);
			}
		}
		for (d in config.dirs.concat(watched))
			walk(d);
		for (f in hxmlFiles())
			result.set(f, f);
		return result;
	}

	/** Returns the build's hxml files, and the ones they name, resolved from the build's directory. **/
	static function hxmlFiles():Array<String> {
		var result = [];
		function add(file:String) {
			var path = Path.normalize(Path.isAbsolute(file) ? file : Path.join([buildCwd, file]));
			if (result.contains(path) || !FileSystem.exists(path))
				return;
			result.push(path);
			for (line in (try File.getContent(path) catch (_) "").split("\n")) {
				line = line.trim();
				if (line.endsWith(".hxml") && !line.startsWith("-") && !line.startsWith("#"))
					add(line);
			}
		}
		for (a in build)
			if (a.endsWith(".hxml"))
				add(a);
		return result;
	}

	static function startCompilationServer():String {
		var socket = new Socket();
		socket.bind(new Host("127.0.0.1"), 0);
		var address = "127.0.0.1:" + socket.host().port;
		socket.close();
		// The server runs in a shell that stops it when this process stops, however it stops
		// (as the Reloader's does).
		if (Sys.systemName() == "Windows")
			// Windows has no sh. This program runs again instead, and its stdin, a pipe from this one,
			// closes when this ends.
			new Process("haxe", ["-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--compilation-server", address]);
		else
			new Process("sh", [
				"-c",
				'haxe --wait "$$1" >/dev/null 2>&1 & s=$$!; trap \'kill $$s 2>/dev/null\' EXIT INT TERM HUP; '
				+ 'while kill -0 $$PPID 2>/dev/null && kill -0 $$s 2>/dev/null; do sleep 1; done',
				"sh",
				address
			]);
		// The server is ready once it accepts a connection.
		for (_ in 0...100) {
			var probe = new Socket();
			try {
				probe.connect(new Host("127.0.0.1"), Std.parseInt(address.split(":")[1]));
				probe.close();
				return address;
			} catch (_) {
				probe.close();
				Sys.sleep(0.05);
			}
		}
		say("hotreload: compilation server: not started (building without one)");
		return null;
	}

	/** Prints a message to the terminal, or to the log (`--log`). **/
	static function say(message:String) {
		if (log == null) {
			Sys.println(message);
			return;
		}
		logLock.acquire();
		log.writeString(message + "\n");
		log.flush();
		logLock.release();
	}

	/**
		Runs haxe with the arguments, and passes its messages to the terminal, or to the log (--log).

		@return  The exit code.
	**/
	static function runHaxe(args:Array<String>):Int {
		// The output is passed on a line at a time, as it comes. Sys.command is not used, because
		// `haxe --run` holds its child's stderr (the compiler's warnings and errors) until this ends.
		var p = new Process("haxe", args);
		// Both streams are read at once, because a full pipe would stall the compiler.
		var read = new sys.thread.Lock();
		Thread.create(() -> {
			passOn(p.stderr, Sys.stderr());
			read.release();
		});
		passOn(p.stdout, Sys.stdout());
		read.wait();
		var code = p.exitCode();
		p.close();
		return code;
	}

	/** Passes a build's output, line by line, to the same stream of this process (or to the log). **/
	static function passOn(input:haxe.io.Input, output:haxe.io.Output) {
		try {
			while (true) {
				var line = input.readLine();
				if (log != null) {
					say(line);
				} else {
					output.writeString(line + "\n");
					output.flush();
				}
			}
		} catch (_:haxe.io.Eof) {}
	}

	/**
		Runs `haxe --wait address` until stdin closes.

		This is the dev server's compilation server on Windows.
	**/
	static function compilationServerUntilStdinCloses(address:String) {
		var server = new Process("haxe", ["--wait", address]);
		try {
			while (true)
				Sys.stdin().readByte();
		} catch (_) {}
		server.kill();
		server.close();
	}

	// --- serving ---

	/** Runs the serving loop: its connections, and a check of the held long polls a hundred times a second. **/
	static function serveRequests(loop:Loop, server:Tcp) {
		startSidecars(loop);
		var stopping = -1.0;
		var check = Timer.init(loop).resolve();
		check.start(() -> {
			var now = haxe.Timer.stamp();
			for (w in waiting.copy())
				if (!running || now >= w.end || w.ready()) {
					waiting.remove(w);
					w.answer();
				}
			if (!running) {
				// The sidecars are told to stop by closing their input. Any still running after 3 s is killed.
				if (stopping < 0) {
					stopping = now;
					for (s in sidecarsRunning)
						Handle.close(s.input, () -> {});
				}
				if (sidecarsRunning.length > 0 && now < stopping + 3)
					return;
				// The kill is by pid, because Haxe 4.3 has no Process.kill.
				for (s in sidecarsRunning)
					eval.luv.Process.killPid(s.process.pid(), SIGKILL);
				sidecarsStopped.release();
				check.stop();
				Handle.close(check, () -> {});
				Handle.close(server, () -> {});
			}
		}, 10, 10);
		loop.run(DEFAULT);
	}

	/** Starts each sidecar, with its output to the terminal or the log. A failure is reported. **/
	static function startSidecars(loop:Loop) {
		for (command in sidecars) {
			var name = command.join(" ");
			var input = eval.luv.Pipe.init(loop).resolve();
			var redirect = [eval.luv.Process.toParentPipe(eval.luv.Process.stdin, input, true, false, false)];
			var outputs = [];
			if (log == null) {
				redirect.push(eval.luv.Process.inheritFd(eval.luv.Process.stdout, 1));
				redirect.push(eval.luv.Process.inheritFd(eval.luv.Process.stderr, 2));
			} else {
				for (fd in [eval.luv.Process.stdout, eval.luv.Process.stderr]) {
					var output = eval.luv.Pipe.init(loop).resolve();
					outputs.push(output);
					redirect.push(eval.luv.Process.toParentPipe(fd, output, false, true, false));
				}
			}
			var entry = null;
			var onExit = (p:eval.luv.Process, status:eval.integers.Int64, signal) -> {
				sidecarsRunning.remove(entry);
				if (running && status.toInt() != 0)
					say('hotreload: sidecar: failed ($name, exit ${status.toInt()})');
				Handle.close(p, () -> {});
			};
			switch (eval.luv.Process.spawn(loop, command[0], [for (a in command) (a : eval.NativeString)], {redirect: redirect, onExit: onExit})) {
				case Error(e):
					say('hotreload: sidecar: cannot start $name ($e)');
					Handle.close(input, () -> {});
					for (o in outputs)
						Handle.close(o, () -> {});
				case Ok(process):
					entry = {process: process, input: input};
					sidecarsRunning.push(entry);
					for (output in outputs)
						Stream.readStart(output, result -> switch (result) {
							case Ok(data):
								logLock.acquire();
								log.writeString(data.toString());
								log.flush();
								logLock.release();
							case Error(_):
								Handle.close(output, () -> {});
						});
			}
		}
	}

	static function accept(loop:Loop, server:Tcp) {
		var client = Tcp.init(loop).resolve();
		if (!Stream.accept(server, client).isOk()) {
			Handle.close(client, () -> {});
			return;
		}
		// The request is its line and headers, up to the blank line (a GET has no body).
		var head = new StringBuf();
		Stream.readStart(client, result -> switch (result) {
			case Ok(data):
				head.add(data.toString());
				var text = head.toString();
				var end = text.indexOf("\r\n\r\n");
				if (end >= 0) {
					Stream.readStop(client);
					try
						respond(client, text.substr(0, end).split("\r\n"))
					catch (_)
						Handle.close(client, () -> {});
				}
			case Error(_):
				Handle.close(client, () -> {});
		});
	}

	static function respond(client:Tcp, lines:Array<String>) {
		var request = lines[0];
		var range:String = null;
		for (header in lines.slice(1))
			if (header.toLowerCase().startsWith("range:"))
				range = header.substr(6).trim();
		var parts = request.split(" ");
		var path = StringTools.urlDecode(parts[1].split("?")[0]);
		if (path == "/__hotreload") {
			// With ?since=<version>, the answer is held until a newer build exists (or a while passes). A
			// page then hears of a build as soon as it is built, rather than at its next request.
			var since = Std.parseInt(parts[1].indexOf("since=") >= 0 ? parts[1].split("since=")[1].split("&")[0] : "");
			hold(since == null ? null : () -> {
				lock.acquire();
				var newer = version > since;
				lock.release();
				newer;
			}, () -> {
				lock.acquire();
				var body = haxe.Json.stringify({version: version, url: bundleUrl, file: config.js, failed: failed});
				lock.release();
				send(client, 200, "application/json", haxe.io.Bytes.ofString(body));
			});
			return;
		}
		if (path == "/__hotreload_stop" || path == "/__hotreload_project") {
			// These are accepted from this machine only. A page elsewhere must not stop the server,
			// or learn where it runs.
			var peer = switch (client.getPeerName()) {
				case Ok(addr): addr.toString();
				case Error(_): "";
			}
			if (peer != "127.0.0.1") {
				send(client, 403, "text/plain", haxe.io.Bytes.ofString("from 127.0.0.1 only"));
				return;
			}
			if (path == "/__hotreload_project") {
				send(client, 200, "text/plain", haxe.io.Bytes.ofString(project));
				return;
			}
			// Once the answer is sent, the watchers' loops end, and this loop's check closes the server.
			send(client, 200, "text/plain", haxe.io.Bytes.ofString("stopping"), () -> running = false);
			return;
		}
		if (path == "/__hotreload_assets") {
			// With ?since=<version>, the answer is held until files have changed after that version (or a
			// while passes). With -1, it answers at once with the current version, to start from.
			var since = Std.parseInt(parts[1].indexOf("since=") >= 0 ? parts[1].split("since=")[1].split("&")[0] : "");
			hold(since == null || since < 0 ? null : () -> {
				lock.acquire();
				var newer = assetVersion > since;
				lock.release();
				newer;
			}, () -> {
				lock.acquire();
				var urls = new Array<String>();
				if (since != null && since >= 0)
					for (c in assetChanges)
						if (c.version > since)
							for (u in c.urls)
								if (!urls.contains(u))
									urls.push(u);
				var body = haxe.Json.stringify({version: assetVersion, urls: urls});
				lock.release();
				send(client, 200, "application/json", haxe.io.Bytes.ofString(body));
			});
			return;
		}
		var file = resolve(path);
		if (file == null) {
			send(client, 404, "text/plain", haxe.io.Bytes.ofString("not found: " + path));
			return;
		}
		var data = File.getBytes(file);
		if (range != null && range.startsWith("bytes=")) {
			var r = range.substr(6).split("-");
			var from = Std.parseInt(r[0]);
			var to = r.length > 1 && r[1] != "" ? Std.parseInt(r[1]) : data.length - 1;
			if (from != null && to != null && from < data.length) {
				to = Std.int(Math.min(to, data.length - 1));
				send(client, 206, mime(file), data.sub(from, to - from + 1), 'Content-Range: bytes $from-$to/${data.length}\r\n');
				return;
			}
		}
		send(client, 200, mime(file), data);
	}

	/**
		Answers a long poll.

		Without a condition, the answer is sent at once. Otherwise it is held (by the serving loop's
		check) until the condition is met, for up to 20 s.
	**/
	static function hold(ready:Null<() -> Bool>, answer:() -> Void) {
		if (ready == null || ready())
			answer();
		else
			waiting.push({ready: ready, end: haxe.Timer.stamp() + 20, answer: answer});
	}

	/**
		Returns a request's file, under a mount or the output directory, and never outside it.

		@return  The file's path, or null if there is none.
	**/
	static function resolve(path:String):Null<String> {
		var base = root;
		var rest = path;
		for (url => dir in mounts)
			if (path == url || path.startsWith(url + "/")) {
				base = dir;
				rest = path.substr(url.length);
			}
		var file = Path.normalize(Path.join([base, rest]));
		if (!file.startsWith(Path.normalize(base)))
			return null;
		if (FileSystem.exists(file) && FileSystem.isDirectory(file))
			file = Path.join([file, "index.html"]);
		return FileSystem.exists(file) ? file : null;
	}

	/** Sends a response, then closes the connection (and calls `sent`) once it is written. **/
	static function send(client:Tcp, status:Int, type:String, body:haxe.io.Bytes, ?extra = "", ?sent:() -> Void) {
		var reason = switch (status) {
			case 200: "OK";
			case 206: "Partial Content";
			case 403: "Forbidden";
			default: "Not Found";
		}
		var head = 'HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.length}\r\n'
			+ 'Accept-Ranges: bytes\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n${extra}Connection: close\r\n\r\n';
		Stream.write(client, [Buffer.fromString(head), Buffer.fromBytes(body)], (_, _) -> {
			Handle.close(client, () -> {});
			if (sent != null)
				sent();
		});
	}

	static function mime(file:String):String {
		return switch (Path.extension(file).toLowerCase()) {
			case "html": "text/html; charset=utf-8";
			case "js" | "mjs": "text/javascript";
			case "wasm": "application/wasm";
			case "json": "application/json";
			case "css": "text/css";
			case "png": "image/png";
			case "jpg" | "jpeg": "image/jpeg";
			case "glb": "model/gltf-binary";
			case "gltf": "model/gltf+json";
			case "mp3": "audio/mpeg";
			case "ogg": "audio/ogg";
			case "wav": "audio/wav";
			case "ttf": "font/ttf";
			case "map": "application/json";
			default: "application/octet-stream";
		}
	}

	/**
		Returns a path relative to the build's directory, for messages.

		A file in a sibling directory gives `../lib/Lib.hx`. A path on another drive is unchanged.
	**/
	static function relative(path:String):String {
		if (path.startsWith(config.cwd))
			return path.substr(config.cwd.length);
		var split = ~/[\/\\]/g;
		var from = split.split(config.cwd).filter(s -> s != "");
		var to = split.split(path).filter(s -> s != "");
		var i = 0;
		while (i < from.length && i < to.length && from[i] == to[i])
			i++;
		if (i == 0)
			return path;
		return [for (_ in i...from.length) ".."].concat(to.slice(i)).join("/");
	}
}
#end
