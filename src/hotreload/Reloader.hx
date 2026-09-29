package hotreload;

#if (hotreload && cpp && !cppia && !hotreload_library)
import haxe.io.Path;
import hotreload.Builder.Config;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import sys.thread.Deque;
import sys.thread.Thread;

using Lambda;
using StringTools;
#end

/**
	The main class's side of hot reload: make one, and `update` it every frame (or loop).

	While the program runs, `update` checks the reloaded code's sources a few times a
	second. Once they've changed and then stopped changing, it starts a build of the
	reloaded code as one cppia module, in the background, and returns: the old code keeps
	running, and compiler errors go to the terminal. The first `update` after the build
	finishes swaps the module in: it checks the `@:hot` functions' signatures, runs the old
	code's `@:beforeHotReload` hooks, starts the module, carries the `@:hot` statics over,
	points the executable's calls at the new code, and runs the new code's
	`@:afterHotReload` hooks. As such a swap only happens where `update` is called, never
	in the middle of a frame.

	Outside a hot build (`-D hotreload`, on a cpp target) it does nothing.
**/
class Reloader {
	/** the main class's: just before a swap, after the old code's `@:beforeHotReload` hooks **/
	public var beforeReload:() -> Void;

	/** the main class's: just after, after the new code's `@:afterHotReload` hooks **/
	public var afterReload:() -> Void;

	#if (hotreload && cpp && !cppia && !hotreload_library)
	static inline var CHECK_INTERVAL = 0.25;

	var config:Config;
	var importInfo:String;
	var stamps = new Map<String, Stamp>();
	var nextCheck = 0.0;
	var settling = false;
	var changed = new Array<String>();

	/** the sources changed since the last build started, which it tells the compilation server **/
	var changedPaths = new Array<String>();
	var building:String;
	var buildDone = new Deque<Int>();
	var changedSince = false;
	var version = 0;
	var modules = new Array<cpp.cppia.Module>();
	var warming = false;

	/** the compilation server the builds connect to (host:port), or null for none **/
	var server:String;

	/** the one this started, if it did **/
	var serverProcess:Process;

	/**
		`haxe --wait`, in a shell that stops it when this program stops, however that is
		(Ctrl-C stops them both anyway: they're in one process group)
	**/
	static final SERVER_WATCHDOG = 'haxe --wait "$$1" >/dev/null 2>&1 & s=$$!; '
		+ "trap 'kill $s 2>/dev/null' EXIT INT TERM HUP; "
		+ 'while kill -0 $$PPID 2>/dev/null && kill -0 $$s 2>/dev/null; do sleep 1; done';

	public function new() {
		var json = haxe.Resource.getString("hotreload.config");
		if (json == null) {
			Sys.println("hotreload: this build has no reload config: build it with --macro hotreload.Builder.init() (or -lib hotreload-hx)");
			return;
		}
		config = haxe.Json.parse(json);
		if (config.roots.length == 0) {
			Sys.println("hotreload: nothing to reload: no class has @:hot statics or functions, or reload hooks");
			config = null;
			return;
		}
		// the JIT compiles a module to native code: quicker, but no breakpoints in it
		cpp.cppia.Host.enableJit(!config.debug);
		importInfo = writeImportInfo();
		stamps = sources();
		var names = [for (root in config.roots) root.split(".").join("/") + ".hx"];
		var dirs = [for (d in config.dirs) relative(d) + "/"];
		Sys.println('hotreload: watching for changes to ${names.join(", ")} and the rest of ${dirs.join(", ")}');
		server = startServer();
		if (server != null) {
			// a build now, which isn't swapped in: the server has the code parsed and typed
			// by the first reload
			warming = true;
			runBuild(config.buildDir + "/warmup.cppia");
		}
	}

	/** stops the compilation server this started, if it did **/
	public function dispose() {
		if (serverProcess != null) {
			serverProcess.kill();
			serverProcess.close();
			serverProcess = null;
		}
		server = null;
	}

	/** call every frame: checks the sources a few times a second, and swaps a finished build in **/
	public function update() {
		if (config == null)
			return;
		if (building != null) {
			var code = buildDone.pop(false);
			if (code != null) {
				if (warming)
					warming = false;
				else if (code == 0)
					swap(building);
				else
					Sys.println("hotreload: build failed; still running the last one");
				building = null;
				if (changedSince) {
					changedSince = false;
					startBuild();
				}
			}
		}
		var now = haxe.Timer.stamp();
		if (now < nextCheck)
			return;
		nextCheck = now + CHECK_INTERVAL;
		var current = sources();
		var paths = [];
		for (path => stamp in current)
			if (!stamps.exists(path) || stamp.differs(stamps.get(path)))
				paths.push(path);
		for (path in stamps.keys())
			if (!current.exists(path))
				paths.push(path);
		if (paths.length > 0) {
			for (path in paths) {
				if (!changedPaths.contains(path))
					changedPaths.push(path);
				var name = relative(path);
				if (!changed.contains(name))
					changed.push(name);
			}
			stamps = current;
			// a build starts once the sources have stopped changing (a save can touch a file
			// twice, or several files), at the next check
			settling = true;
		} else if (settling) {
			// an empty source is one being saved (truncated, then written): wait for it
			for (stamp in current)
				if (stamp.empty())
					return;
			settling = false;
			if (building != null)
				changedSince = true;
			else
				startBuild();
		}
	}

	/** the .hx files in the reloaded code's directories and below, but the main class's, and when each last changed **/
	function sources():Map<String, Stamp> {
		var result = new Map<String, Stamp>();
		var now = Date.now().getTime();
		function walk(dir:String) {
			var entries = try FileSystem.readDirectory(dir) catch (_) [];
			for (entry in entries) {
				var path = dir + "/" + entry;
				if (FileSystem.isDirectory(path))
					walk(path);
				else if (entry.endsWith(".hx") && path != config.mainFile)
					result.set(path, Stamp.of(path, now));
			}
		}
		for (dir in config.dirs)
			walk(dir);
		return result;
	}

	/**
		The executable's classes, which a module is compiled against: what the build wrote
		(-D dll_export), but the reloaded ones, which the module has its own of
	**/
	function writeImportInfo():String {
		var exported = config.buildDir + "/host.info";
		var info = config.buildDir + "/import.info";
		var lines = [];
		for (line in File.getContent(exported).split("\n")) {
			var parts = line.split(" ");
			var reloaded = switch (parts[0]) {
				case "class" | "enum" | "interface": parts[1].startsWith(Builder.HOST_PREFIX);
				case "file": parts.length > 2 && config.dirs.exists(d -> parts[parts.length - 1].startsWith(d + "/"));
				default: false;
			}
			if (!reloaded)
				lines.push(line);
		}
		File.saveContent(info, lines.join("\n"));
		return info;
	}

	function startBuild() {
		var why = changed.join(", ") + " changed";
		changed = [];
		version++;
		Sys.println('hotreload: building ($why)');
		runBuild(config.buildDir + "/" + config.mainClass.toLowerCase() + "_" + version + ".cppia");
	}

	/** builds the reloaded code as a module, in the background: `update` sees it's done **/
	function runBuild(out:String) {
		building = out;
		var args = ["--cwd", config.cwd].concat(config.args).concat([
			"-D", "hotreload_library",
			"-D", "hotreload_dirs=" + config.dirs.join("|"),
			"-D", "hotreload_main=" + config.mainClass,
			"-D", "dll_import=" + importInfo,
			"--cppia", out
		]).concat(config.roots);
		if (changedPaths.length > 0)
			args = args.concat(["-D", "hotreload_invalidate=" + changedPaths.join("|")]);
		changedPaths = [];
		if (serverProcess != null && serverProcess.exitCode(false) != null) {
			Sys.println("hotreload: the compilation server stopped; building without it");
			dispose();
		}
		var server = server;
		var done = buildDone;
		// its output (errors) goes straight to this terminal
		Thread.create(() -> {
			if (server != null && serverReady(server))
				args = ["--connect", server].concat(args);
			var code = try Sys.command("haxe", args) catch (_) -1;
			done.add(code);
		});
	}

	/** the compilation server to use: the one the build names, or one this starts, or none **/
	function startServer():String {
		if (config.compilationServer == "off")
			return null;
		if (config.compilationServer != null)
			return config.compilationServer;
		var port = freePort();
		if (port == null)
			return null;
		var address = '127.0.0.1:$port';
		try {
			serverProcess = Sys.systemName() == "Windows" ? new Process("haxe", ["--wait", address]) : new Process("sh", ["-c", SERVER_WATCHDOG, "sh", address]);
		} catch (e) {
			Sys.println('hotreload: can\'t start a compilation server ($e); building without one');
			return null;
		}
		return address;
	}

	/** a port nothing's listening on, from the system **/
	static function freePort():Null<Int> {
		var socket = new sys.net.Socket();
		try {
			socket.bind(new sys.net.Host("127.0.0.1"), 0);
			var port = socket.host().port;
			socket.close();
			return port;
		} catch (_) {
			socket.close();
			return null;
		}
	}

	/** whether a server takes connections, waiting a few seconds for one that's starting **/
	static function serverReady(address:String):Bool {
		var parts = address.split(":");
		var host = parts.length > 1 ? parts[0] : "127.0.0.1";
		var port = Std.parseInt(parts[parts.length - 1]);
		var deadline = haxe.Timer.stamp() + 5;
		while (haxe.Timer.stamp() < deadline) {
			var socket = new sys.net.Socket();
			try {
				socket.connect(new sys.net.Host(host), port);
				socket.close();
				return true;
			} catch (_) {
				socket.close();
				Sys.sleep(0.05);
			}
		}
		Sys.println('hotreload: no compilation server at $address; building without it');
		return false;
	}

	function swap(path:String) {
		var module = try cpp.cppia.Module.fromData(File.getBytes(path).getData()) catch (e) {
			Sys.println('hotreload: can\'t load ${relative(path)}: $e');
			return;
		}

		// before any of the new code runs: the main class calls each hot function the way
		// it was compiled to
		var changedSigs = [];
		var found = [];
		for (proc in Hooks.procs) {
			var cls = module.resolveClass(proc.className);
			var sigFn = cls == null ? null : Reflect.field(cls, "__hot_sig_" + proc.name);
			if (sigFn == null) {
				found.push(null);
				continue;
			}
			if (Reflect.callMethod(cls, sigFn, []) != proc.sig)
				changedSigs.push(proc.className + "." + proc.name);
			found.push(cls);
		}
		if (changedSigs.length > 0) {
			Sys.println('hotreload: ${changedSigs.join(", ")}${changedSigs.length == 1 ? "'s" : "'"} signature changed: '
				+ "restart to run the new code (the last still runs)");
			return;
		}

		Hooks.runBefore(); // the old code's
		if (beforeReload != null)
			beforeReload();
		// the module's classes start: their statics are made (the @:hot ones are handed
		// their slots), and they add their hooks
		Hooks.forget();
		try {
			module.boot();
		} catch (e) {
			Sys.println('hotreload: ${relative(path)} failed as it started: $e');
			return;
		}
		// modules stay loaded: what old code handed out (a callback) still runs it
		modules.push(module);
		Migrate.run(name -> module.resolveClass(name));
		for (i in 0...Hooks.procs.length) {
			var proc = Hooks.procs[i];
			var cls = found[i];
			if (cls == null) {
				Sys.println('hotreload: ${proc.className}.${proc.name} is gone from the new code: its last version runs on');
				continue;
			}
			proc.point(Reflect.field(cls, proc.name));
		}
		Hooks.runAfter(); // the new code's
		if (afterReload != null)
			afterReload();
		Sys.println('hotreload: reloaded (${Path.withoutDirectory(path)})');
	}

	/** a path from the build's directory, for messages **/
	function relative(path:String):String {
		return path.startsWith(config.cwd) ? path.substr(config.cwd.length) : path;
	}
	#else
	public function new() {}

	public inline function dispose() {}


	/** outside a hot build, nothing to do **/
	public inline function update() {}
	#end
}

#if (hotreload && cpp && !cppia && !hotreload_library)
/**
	When a source last changed. A file's time is in whole seconds, so two saves in one
	second would look like one: a file changed in the last few seconds has its contents'
	hash too
**/
private class Stamp {
	var mtime:Float;
	var size:Int;
	var hash:Null<Int>;

	function new(mtime, size, hash) {
		this.mtime = mtime;
		this.size = size;
		this.hash = hash;
	}

	public static function of(path:String, now:Float):Stamp {
		try {
			var stat = FileSystem.stat(path);
			var mtime = stat.mtime.getTime();
			var hash = now - mtime < 3000 ? haxe.crypto.Crc32.make(File.getBytes(path)) : null;
			return new Stamp(mtime, stat.size, hash);
		} catch (_) {
			return new Stamp(0, 0, null);
		}
	}

	public function empty():Bool {
		return size == 0;
	}

	public function differs(other:Stamp):Bool {
		return mtime != other.mtime || size != other.size || (hash != null && other.hash != null && hash != other.hash);
	}
}
#end
