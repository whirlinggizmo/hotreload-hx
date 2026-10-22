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
	Hot reload for a JS build: builds it hot, serves it, and rebuilds it when a source
	changes, and the page (or a node program) loads each new build in place of the
	running one (Reloader.js.hx, JsSwap).

	```
	haxe -lib hotreload-hx --run hotreload.DevServer [options] <build arguments>
	```

	The build arguments are the build's own, an hxml say (`build.web.hxml`); this adds
	`-D hotreload`. Options:

	- `--port <n>`: where it serves, 8080 by default
	- `--mount <url>=<dir>`: serves a directory at a path too, as `--mount /assets=../assets`
	- `--reload-define <name[=value]>`: a define for the reload's builds only, not the first:
	  for something the page loads once, which the first build makes and a reload's needn't
	  (a native host a guest runs in, say)
	- `--no-compilation-server`: builds each reload with a `haxe` of its own
	- `--stop-with-stdin`: stops when its standard input closes: for a program that starts
	  it with a pipe there, so it stops when that program does, however that is (`serve`)
	- `--log <file>`: its messages, and the builds', to the file instead of the terminal

	Or from a macro, in an hxml of its own beside others' (a watcher, say):

	```
	-lib hotreload-hx
	--macro hotreload.DevServer.serve("build.web.hxml", {port: 8064, mounts: {"/assets": "assets"}})
	```

	`serve` starts it and returns; the compiler waits for it once its macros are done, and
	it stops with the compiler, Ctrl+C or not. With `background: true` it keeps running
	after the compiler, its messages in a log, until it's stopped:

	```
	haxe -lib hotreload-hx --macro "hotreload.DevServer.stop(8064)"
	```

	It serves the build's output directory at `/`, with Range requests (an engine may
	stream assets), and `/__hotreload`, which says what the latest build is (with `?since=<n>`, once there's
	one newer than n). `/__hotreload_assets` says which served files changed (with `?since=<n>`, the
	same way), `/__hotreload_project` says the directory it was started in, and
	`/__hotreload_stop`, asked from this machine, stops it. Ten times a
	second it checks the project's sources for changes: the build's class paths inside its
	directory (`-cp`), or else the main class's directory, and below. Once they've stopped
	changing, it rebuilds, through a compilation server it starts, and the page, which is
	waiting to hear of it, loads it. Compiler errors go to this terminal (or the log), and
	the page keeps running what it has.
**/
class DevServer {
	/** how often the sources are checked: a check is a directory walk, cheap at this size **/
	static inline var CHECK_INTERVAL = 0.1;

	static var port = 8080;
	static var mounts = new Map<String, String>();
	static var reloadDefines = new Array<String>();
	static var root:String;

	/** the directory it was started in: its project, which a restart (serve's) checks is the same **/
	static var project = Path.removeTrailingSlashes(Path.normalize(Sys.getCwd()));
	static var bundleUrl:String;
	static var config:Builder.JsConfig;
	static var version = 0;
	static var failed = false;
	static var lock = new Mutex();

	/** where its messages go: the terminal, or a file (--log) **/
	static var log:sys.io.FileOutput;

	static var logLock = new Mutex();

	/** the served files' changes: each settled batch a version, its URLs (/__hotreload_assets) **/
	/** cleared by a stop (/__hotreload_stop), which ends the watchers' loops and the serving one **/
	static var running = true;

	/** the long polls being held, each answered once it can be, or its time is up, or there's a stop **/
	static var waiting = new Array<{ready:() -> Bool, end:Float, answer:() -> Void}>();

	static var assetVersion = 0;
	static var assetChanges = new Array<{version:Int, urls:Array<String>}>();

	static function main() {
		var args = Sys.args();
		if (args[0] == "--compilation-server") {
			compilationServerUntilStdinCloses(args[1]);
			return;
		}
		var build = [];
		var useServer = true;
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "--port":
					port = Std.parseInt(args[++i]);
				case "--mount":
					var m = args[++i].split("=");
					mounts.set("/" + m[0].replace("\\", "/").split("/").filter(s -> s != "").join("/"), FileSystem.absolutePath(m[1]));
				case "--no-compilation-server":
					useServer = false;
				case "--reload-define":
					reloadDefines.push(args[++i]);
				case "--log":
					log = File.write(args[++i]);
				case "--stop-with-stdin":
					// the pipe's other end closes when its program ends, killed or not, on every system
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
			say("usage: haxe -lib hotreload-hx --run hotreload.DevServer [--port n] [--mount /url=dir] <build arguments>");
			Sys.exit(1);
		}

		// the first build: hot, and saying how it was made
		var configFile = Path.join([Sys.getCwd(), ".hotreload." + Std.random(1 << 30) + ".json"]);
		say("hotreload: building");
		// with the library, whether the build names it or not
		var code = runHaxe(build.concat(["-lib", "hotreload-hx", "-D", "hotreload", "-D", 'hotreload_config=$configFile']));
		if (code != 0 || !FileSystem.exists(configFile)) {
			if (FileSystem.exists(configFile))
				FileSystem.deleteFile(configFile);
			say(code != 0 ? "hotreload: the build failed" : "hotreload: the build isn't hot: is it a JS build, with -lib hotreload-hx?");
			Sys.exit(1);
		}
		config = haxe.Json.parse(File.getContent(configFile));
		FileSystem.deleteFile(configFile);
		root = Path.directory(config.js);
		bundleUrl = "/" + Path.withoutDirectory(config.js);

		// the port first: if it's taken there's nothing to serve, and saying so beats a page that never loads.
		// libuv's (eval.luv's): its bind reuses the address, so a restart needn't wait out the
		// last run's closed connections, and it says when it fails (sys.net.Socket does neither on eval)
		var loop = Loop.init().resolve();
		var server = Tcp.init(loop).resolve();
		var failure:String = null;
		switch (server.bind(SockAddr.ipv4("0.0.0.0", port).resolve())) {
			case Error(e): failure = e.toString();
			case Ok(_):
		}
		// libuv tells a bind's address in use at the listen
		if (failure == null)
			Stream.listen(server, result -> switch (result) {
				case Error(e): failure = e.toString();
				case Ok(_): accept(loop, server);
			}, 32);
		if (failure != null) {
			say('hotreload: can\'t serve on port $port ($failure): is something else using it? --port <n> for another');
			Sys.exit(1);
		}
		var compilationServer = useServer ? startCompilationServer() : null;
		Thread.create(() -> serveRequests(loop, server));
		var dirs = [for (d in config.dirs) relative(d) + "/"];
		say('hotreload: serving http://localhost:$port/ ($root)');
		for (url => dir in mounts)
			say('hotreload: and $dir at $url/');
		say('hotreload: watching ${dirs.join(", ")}');
		Thread.create(watchAssets);
		watch(compilationServer);
		// the compilation server's shell sees this process go, and stops it
		say("hotreload: stopped");
		Sys.exit(0);
	}

	#if macro
	static var macroLoop:Loop;
	static var macroExit = 0;

	/** serve's and stop's port when they're given none: `-D hotreload-port=<n>`, or 8080, so an hxml says it once **/
	static function macroPort():Int {
		var defined = haxe.macro.Context.definedValue("hotreload-port");
		var port = defined == null ? null : Std.parseInt(defined);
		if (defined != null && port == null)
			haxe.macro.Context.fatalError('hotreload: -D hotreload-port=$defined isn\'t a port', haxe.macro.Context.currentPos());
		return port == null ? 8080 : port;
	}

	/**
		Starts it from a macro, `--macro hotreload.DevServer.serve(...)`, with the build's
		arguments (an hxml, say) and the options above, and returns, so the hxml's other
		macros run too; once they're done, the compiler waits for it. It stops with the
		compiler: its standard input is a pipe from it (`--stop-with-stdin`). Its port is
		`port`, or else `-D hotreload-port=<n>`'s, or 8080. With `restart: true`, a dev
		server this project left on the port (one started in this directory) is stopped
		first; another project's isn't, and this fails saying whose it is.

		With `background: true`, it returns once the server is serving (or fails as it
		does), and the server keeps running after the compiler, detached from this terminal,
		so Ctrl+C here and closing it leave it be; its messages go to `log` (`.hotreload-<port>.log` by default), and `stop(port)`
		stops it.
	**/
	public static function serve(build:haxe.extern.EitherType<String, Array<String>>, ?options:{
		?port:Int,
		?mounts:haxe.DynamicAccess<String>,
		?reloadDefines:Array<String>,
		?compilationServer:Bool,
		?background:Bool,
		?log:String,
		?restart:Bool
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
			if (options.reloadDefines != null)
				for (d in options.reloadDefines)
					args = args.concat(["--reload-define", d]);
			if (options.compilationServer == false)
				args.push("--no-compilation-server");
		}
		var logFile = null;
		if (background) {
			logFile = FileSystem.absolutePath(options.log != null ? options.log : '.hotreload-$port.log');
			// a last run's says nothing of this one. Windows won't let go of a running server's: one just stopped (stop(), just
			// before) may take a moment to end, past that it's still running
			var tries = 0;
			while (FileSystem.exists(logFile))
				try {
					FileSystem.deleteFile(logFile);
				} catch (_) {
					if (++tries < 30) {
						Sys.sleep(0.1);
						continue;
					}
					haxe.macro.Context.fatalError('hotreload: $logFile is in use: a dev server still running in the background? '
						+ 'To stop it: haxe -lib hotreload-hx --macro "hotreload.DevServer.stop($port)"', haxe.macro.Context.currentPos());
				}
			args = args.concat(["--log", logFile]);
		} else {
			args.push("--stop-with-stdin");
		}
		args = args.concat(Std.isOfType(build, String) ? [(build : String)] : (build : Array<String>));

		var loop = if (background) Loop.init().resolve() else {
			if (macroLoop == null) {
				macroLoop = Loop.init().resolve();
				// and fails as the server does, as the hxml with --run did
				haxe.macro.Context.onAfterGenerate(() -> {
					macroLoop.run(DEFAULT);
					if (macroExit != 0)
						Sys.exit(macroExit);
				});
			}
			macroLoop;
		}
		var pipe = eval.luv.Pipe.init(loop).resolve();
		var stdin = eval.luv.Process.toParentPipe(eval.luv.Process.stdin, pipe, true, false, false);
		// in the background, detached: a session of its own (Unix), no console and out of libuv's job, which would end it
		// with the compiler (Windows); so this terminal's Ctrl+C and closing it leave it be. Its builds start hidden (--log)
		var redirect = background ? [stdin] : [
			stdin,
			eval.luv.Process.inheritFd(eval.luv.Process.stdout, 1),
			eval.luv.Process.inheritFd(eval.luv.Process.stderr, 2)
		];
		// nor this one's stdout and stderr, which Windows would hand it: whatever reads them (an editor's task) would wait for it
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
				haxe.macro.Context.fatalError('hotreload: can\'t start the server: $e', haxe.macro.Context.currentPos());
			case Ok(p): p;
		}
		if (!background)
			return;

		// once it's serving, or it's failed: its messages so far, here
		var said = "";
		while (true) {
			loop.run(NOWAIT);
			said = try File.getContent(logFile) catch (_) "";
			if (exited || said.contains("hotreload: watching"))
				break;
			Sys.sleep(0.1);
		}
		if (said.trim() != "")
			Sys.println(said.rtrim());
		if (exited)
			Sys.exit(macroExit != 0 ? macroExit : 1);
		Sys.println('hotreload: in the background, its messages in $logFile; to stop it: haxe -lib hotreload-hx --macro "hotreload.DevServer.stop($port)"');
		// the process goes on without this: only the handles are let go
		Handle.close(pipe, () -> {});
		Handle.close(process, () -> {});
		loop.run(NOWAIT);
	}

	/**
		Stops the dev server serving on this machine's port (`/__hotreload_stop`), as
		`--macro hotreload.DevServer.stop(8064)`: one `serve` left in the background, say.
		Nothing serving there is fine, so an hxml can stop a last run's before its `serve`.
	**/
	public static function stop(?port:Int) {
		if (port == null)
			port = macroPort();
		var answer = ask(port, "/__hotreload_stop");
		if (answer == null) {
			Sys.println('hotreload: nothing is serving on port $port');
			return;
		}
		if (answer != "stopping")
			haxe.macro.Context.fatalError('hotreload: what serves on port $port isn\'t the dev server', haxe.macro.Context.currentPos());
		// gone once the port is free
		for (_ in 0...100) {
			if (ask(port, null) == null) {
				Sys.println('hotreload: stopped the dev server on port $port');
				return;
			}
			Sys.sleep(0.1);
		}
		haxe.macro.Context.fatalError('hotreload: the dev server on port $port was asked to stop, and is still serving', haxe.macro.Context.currentPos());
	}

	/** restart's stop: the server on the port stopped if it's this project's (started in this directory), left be if not **/
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
		haxe.macro.Context.fatalError(devServer ? 'hotreload: port $port is served by the dev server of $answer, not this project\'s; to stop it anyway: $stopIt'
			: 'hotreload: port $port is in use, and not by a dev server to restart (one from an older hotreload-hx stops with: $stopIt)',
			haxe.macro.Context.currentPos());
	}

	/**
		The body of a GET of path from this machine's port, or null if nothing serves
		there; one not answered 200 is its status line. With no path, only whether
		something serves (null or "").
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
		while (running) {
			Sys.sleep(CHECK_INTERVAL);
			// a build starts once the sources have stopped changing (FileWatch)
			var paths = sourceWatch.check();
			if (paths != null)
				rebuild(paths, compilationServer);
		}
	}

	/**
		The served files (the output directory's and the mounts'), but the bundle: a saved
		one, once its save has settled, is told to the page by its URL, which loads it again
		in place. Nothing is built
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
			say('hotreload: ${urls.join(", ")} changed; the page loads it next');
		}
	}

	/** every served file, by its URL, and its path **/
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

	static function rebuild(changed:Array<String>, compilationServer:String) {
		say('hotreload: building (${[for (p in changed) relative(p)].join(", ")} changed)');
		var start = haxe.Timer.stamp();
		lock.acquire();
		var next = version + 1;
		lock.release();
		// the changed files through a file, whose path (a define) is the same each build
		var list = Path.join([Path.directory(config.js), ".hotreload-changed"]);
		File.saveContent(list, changed.join("\n"));
		var args = config.args.concat(["-D", "hotreload_reload", "-D", 'hotreload_invalidate=$list']);
		for (d in reloadDefines)
			args = args.concat(["-D", d]);
		if (compilationServer != null)
			args = ["--connect", compilationServer].concat(args);
		var code = runHaxe(["--cwd", config.cwd].concat(args));
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
		say(code == 0 ? 'hotreload: built in $ms ms; the page loads it next' : "hotreload: build failed; the page keeps what it has");
	}

	/**
		A build's number, on its bundle's first line, for the bundle to know which it is
		(JsSwap). On the line Haxe's comment is on, so no line moves, and a define whose
		value changed each build would give the compilation server a new context each time
	**/
	static function stamp(n:Int) {
		var js = File.getContent(config.js);
		File.saveContent(config.js, 'globalThis.__hotreload_built = $n; ' + js);
	}

	/** the .hx files in the watched directories and below **/
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
		for (d in config.dirs)
			walk(d);
		return result;
	}

	static function startCompilationServer():String {
		var socket = new Socket();
		socket.bind(new Host("127.0.0.1"), 0);
		var address = "127.0.0.1:" + socket.host().port;
		socket.close();
		// in a shell that stops it when this stops, however that is (as the Reloader's)
		if (Sys.systemName() == "Windows")
			// no sh: this again, whose stdin, a pipe from this, closes when this ends
			new Process("haxe", ["-lib", "hotreload-hx", "--run", "hotreload.DevServer", "--compilation-server", address]);
		else
			new Process("sh", [
				"-c",
				'haxe --wait "$$1" >/dev/null 2>&1 & s=$$!; trap \'kill $$s 2>/dev/null\' EXIT INT TERM HUP; '
				+ 'while kill -0 $$PPID 2>/dev/null && kill -0 $$s 2>/dev/null; do sleep 1; done',
				"sh",
				address
			]);
		// ready once it takes a connection
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
		say("hotreload: the compilation server didn't start; building without it");
		return null;
	}

	/** `haxe --wait address` until stdin closes: the dev server's compilation server on Windows **/
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

	/** haxe with these arguments, its messages to the terminal, or to the log (--log) **/
	static function runHaxe(args:Array<String>):Int {
		// its output passed on a line at a time, as it comes: not Sys.command, whose child's
		// stderr (the compiler's warnings and errors) `haxe --run` holds until this ends
		var p = new Process("haxe", args);
		// both read at once: a full pipe would stall the compiler
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

	/** a build's output, line by line, to the same stream of this (or the log) **/
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

	/** runs the loop: its connections, and a check of the held long polls a hundred times a second **/
	static function serveRequests(loop:Loop, server:Tcp) {
		var check = Timer.init(loop).resolve();
		check.start(() -> {
			var now = haxe.Timer.stamp();
			for (w in waiting.copy())
				if (!running || now >= w.end || w.ready()) {
					waiting.remove(w);
					w.answer();
				}
			if (!running) {
				check.stop();
				Handle.close(check, () -> {});
				Handle.close(server, () -> {});
			}
		}, 10, 10);
		loop.run(DEFAULT);
	}

	static function accept(loop:Loop, server:Tcp) {
		var client = Tcp.init(loop).resolve();
		if (!Stream.accept(server, client).isOk()) {
			Handle.close(client, () -> {});
			return;
		}
		// the request: its line and headers, up to the blank line (a GET has no body)
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
			// ?since=<version>: held until there's a newer build (or a while passes), so a
			// page hears of one as soon as it's built rather than at its next question
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
			// from this machine only: a page elsewhere has no business stopping it, or knowing where it runs
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
			// once it's said: the watchers' loops end, and this one's check closes the server
			send(client, 200, "text/plain", haxe.io.Bytes.ofString("stopping"), () -> running = false);
			return;
		}
		if (path == "/__hotreload_assets") {
			// ?since=<version>: held until files newer than it have changed (or a while
			// passes); -1 answers at once with the current version, to start from
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

	/** a long poll's answer: at once without a condition, or held (by serve's check) until it's met, for up to 20 s **/
	static function hold(ready:Null<() -> Bool>, answer:() -> Void) {
		if (ready == null || ready())
			answer();
		else
			waiting.push({ready: ready, end: haxe.Timer.stamp() + 20, answer: answer});
	}

	/** a request's file: under a mount, or the output directory, and never outside it **/
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

	/** a response, and then the connection closed (and `sent` called) once it's written **/
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

	static function relative(path:String):String {
		return path.startsWith(config.cwd) ? path.substr(config.cwd.length) : path;
	}
}
#end
