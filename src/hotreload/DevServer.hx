package hotreload;

#if (sys || eval)
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
	  for a library whose build step the page needs only once (wgrender-hx's host:
	  `--reload-define wgr-host=none`)
	- `--no-compilation-server`: builds each reload with a `haxe` of its own

	It serves the build's output directory at `/`, with Range requests (an engine may
	stream assets), and `/__hotreload`, which says what the latest build is (with `?since=<n>`, once there's
	one newer than n). `/__hotreload_assets` says which served files changed (with `?since=<n>`, the
	same way), and `/__hotreload_stop`, asked from this machine, stops it. Ten times a
	second it checks the sources in the main class's directory, and below, for changes;
	once they've stopped changing, it rebuilds, through a compilation server it starts,
	and the page, which is waiting to hear of it, loads it. Compiler errors go to this
	terminal, and the page keeps running what it has.
**/
class DevServer {
	/** how often the sources are checked: a check is a directory walk, cheap at this size **/
	static inline var CHECK_INTERVAL = 0.1;

	static var port = 8080;
	static var mounts = new Map<String, String>();
	static var reloadDefines = new Array<String>();
	static var root:String;
	static var bundleUrl:String;
	static var config:Builder.JsConfig;
	static var version = 0;
	static var failed = false;
	static var lock = new Mutex();

	/** the served files' changes: each settled batch a version, its URLs (/__hotreload_assets) **/
	/** cleared by a stop (/__hotreload_stop), which ends the watchers' loops and the serving one **/
	static var running = true;
	static var listener:Socket;

	static var assetVersion = 0;
	static var assetChanges = new Array<{version:Int, urls:Array<String>}>();

	static function main() {
		var args = Sys.args();
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
				default:
					build.push(args[i]);
			}
			i++;
		}
		if (build.length == 0) {
			Sys.println("usage: haxe -lib hotreload-hx --run hotreload.DevServer [--port n] [--mount /url=dir] <build arguments>");
			Sys.exit(1);
		}

		// the first build: hot, and saying how it was made
		var configFile = Path.join([Sys.getCwd(), ".hotreload." + Std.random(1 << 30) + ".json"]);
		Sys.println("hotreload: building");
		// with the library, whether the build names it or not
		var code = Sys.command("haxe", build.concat(["-lib", "hotreload-hx", "-D", "hotreload", "-D", 'hotreload_config=$configFile']));
		if (code != 0 || !FileSystem.exists(configFile)) {
			if (FileSystem.exists(configFile))
				FileSystem.deleteFile(configFile);
			Sys.println(code != 0 ? "hotreload: the build failed" : "hotreload: the build isn't hot: is it a JS build, with -lib hotreload-hx?");
			Sys.exit(1);
		}
		config = haxe.Json.parse(File.getContent(configFile));
		FileSystem.deleteFile(configFile);
		root = Path.directory(config.js);
		bundleUrl = "/" + Path.withoutDirectory(config.js);

		// the port first: if it's taken there's nothing to serve, and saying so beats a page that never loads
		var server = new Socket();
		try {
			server.bind(new Host("0.0.0.0"), port);
			server.listen(32);
		} catch (e) {
			Sys.println('hotreload: can\'t serve on port $port ($e): is something else using it? --port <n> for another');
			Sys.exit(1);
		}
		var compilationServer = useServer ? startCompilationServer() : null;
		listener = server;
		Thread.create(() -> serve(server));
		var dirs = [for (d in config.dirs) relative(d) + "/"];
		Sys.println('hotreload: serving http://localhost:$port/ ($root)');
		for (url => dir in mounts)
			Sys.println('hotreload: and $dir at $url/');
		Sys.println('hotreload: watching ${dirs.join(", ")}');
		Thread.create(watchAssets);
		watch(compilationServer);
		// the compilation server's shell sees this process go, and stops it
		Sys.println("hotreload: stopped");
		Sys.exit(0);
	}

	// --- building ---

	static function watch(compilationServer:String) {
		var stamps = sources();
		var changed = [];
		var settling = false;
		while (running) {
			Sys.sleep(CHECK_INTERVAL);
			var current = sources();
			var paths = [];
			for (path => stamp in current)
				if (!stamps.exists(path) || stamps.get(path) != stamp)
					paths.push(path);
			for (path in stamps.keys())
				if (!current.exists(path))
					paths.push(path);
			if (paths.length > 0) {
				for (p in paths)
					if (!changed.contains(p))
						changed.push(p);
				stamps = current;
				settling = true;
			} else if (settling) {
				// an empty source is one being saved (truncated, then written): wait for it
				var empty = false;
				for (path => _ in current)
					if (FileSystem.stat(path).size == 0)
						empty = true;
				if (empty)
					continue;
				settling = false;
				rebuild(changed, compilationServer);
				changed = [];
			}
		}
	}

	/**
		The served files (the output directory's and the mounts'), but the bundle: a saved
		one, once its save has settled, is told to the page by its URL, which loads it again
		in place. Nothing is built
	**/
	static function watchAssets() {
		var stamps = served();
		var changed = new Map<String, Bool>();
		var settling = false;
		while (running) {
			Sys.sleep(CHECK_INTERVAL);
			var current = served();
			var any = false;
			for (url => stamp in current)
				if (!stamps.exists(url) || stamps.get(url).stamp != stamp.stamp) {
					changed.set(url, true);
					any = true;
				}
			for (url in stamps.keys())
				if (!current.exists(url)) {
					changed.set(url, true);
					any = true;
				}
			stamps = current;
			if (any) {
				settling = true;
			} else if (settling) {
				// an empty file is one being saved (truncated, then written): wait for it
				var empty = false;
				for (url in changed.keys())
					if (current.exists(url) && current.get(url).size == 0)
						empty = true;
				if (empty)
					continue;
				settling = false;
				var urls = [for (url in changed.keys()) url];
				urls.sort(Reflect.compare);
				changed.clear();
				lock.acquire();
				assetVersion++;
				assetChanges.push({version: assetVersion, urls: urls});
				lock.release();
				Sys.println('hotreload: ${urls.join(", ")} changed; the page loads it next');
			}
		}
	}

	/** every served file by its URL, and a stamp: its time and size (a file isn't read: an asset can be large) **/
	static function served():Map<String, {stamp:String, size:Int}> {
		var result = new Map<String, {stamp:String, size:Int}>();
		var bundle = Path.normalize(FileSystem.absolutePath(config.js));
		function walk(dir:String, url:String) {
			for (entry in (try FileSystem.readDirectory(dir) catch (_) [])) {
				if (entry.startsWith("."))
					continue;
				var path = dir + "/" + entry;
				if (FileSystem.isDirectory(path))
					walk(path, url + "/" + entry);
				else if (Path.normalize(FileSystem.absolutePath(path)) != bundle && !entry.endsWith(".map"))
					try {
						var stat = FileSystem.stat(path);
						result.set(url + "/" + entry, {stamp: stat.mtime.getTime() + ":" + stat.size, size: stat.size});
					} catch (_) {}
			}
		}
		walk(root, "");
		for (url => dir in mounts)
			walk(dir, url);
		return result;
	}

	static function rebuild(changed:Array<String>, compilationServer:String) {
		Sys.println('hotreload: building (${[for (p in changed) relative(p)].join(", ")} changed)');
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
		var code = Sys.command("haxe", ["--cwd", config.cwd].concat(args));
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
		Sys.println(code == 0 ? 'hotreload: built in $ms ms; the page loads it next' : "hotreload: build failed; the page keeps what it has");
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

	/** the .hx files in the watched directories and below, and a stamp for each: its time, size and contents' hash **/
	static function sources():Map<String, String> {
		var result = new Map<String, String>();
		function walk(dir:String) {
			for (entry in (try FileSystem.readDirectory(dir) catch (_) [])) {
				var path = dir + "/" + entry;
				if (FileSystem.isDirectory(path))
					walk(path);
				else if (entry.endsWith(".hx"))
					try {
						var stat = FileSystem.stat(path);
						result.set(path, stat.mtime.getTime() + ":" + stat.size + ":" + haxe.crypto.Crc32.make(File.getBytes(path)));
					} catch (_) {}
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
			new Process("haxe", ["--wait", address]);
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
		Sys.println("hotreload: the compilation server didn't start; building without it");
		return null;
	}

	// --- serving ---

	static function serve(server:Socket) {
		while (running) {
			// a stop closes the socket, which ends a waiting accept
			var client = try server.accept() catch (_) break;
			Thread.create(() -> {
				try
					respond(client)
				catch (_) {}
				try
					client.close()
				catch (_) {}
			});
		}
	}

	static function respond(client:Socket) {
		var request = client.input.readLine();
		var range:String = null;
		while (true) {
			var header = client.input.readLine();
			if (header == "")
				break;
			if (header.toLowerCase().startsWith("range:"))
				range = header.substr(6).trim();
		}
		var parts = request.split(" ");
		var path = StringTools.urlDecode(parts[1].split("?")[0]);
		if (path == "/__hotreload") {
			// ?since=<version>: held until there's a newer build (or a while passes), so a
			// page hears of one as soon as it's built rather than at its next question
			var since = Std.parseInt(parts[1].indexOf("since=") >= 0 ? parts[1].split("since=")[1].split("&")[0] : "");
			if (since != null) {
				var end = haxe.Timer.stamp() + 20;
				while (haxe.Timer.stamp() < end) {
					lock.acquire();
					var newer = version > since;
					lock.release();
					if (newer)
						break;
					Sys.sleep(0.01);
				}
			}
			lock.acquire();
			var body = haxe.Json.stringify({version: version, url: bundleUrl, file: config.js, failed: failed});
			lock.release();
			send(client, 200, "application/json", haxe.io.Bytes.ofString(body));
			return;
		}
		if (path == "/__hotreload_stop") {
			// from this machine only: a page elsewhere has no business stopping it
			if (client.peer().host.toString() != "127.0.0.1") {
				send(client, 403, "text/plain", haxe.io.Bytes.ofString("from 127.0.0.1 only"));
				return;
			}
			send(client, 200, "text/plain", haxe.io.Bytes.ofString("stopping"));
			running = false;
			try
				listener.close()
			catch (_) {}
			return;
		}
		if (path == "/__hotreload_assets") {
			// ?since=<version>: held until files newer than it have changed (or a while
			// passes); -1 answers at once with the current version, to start from
			var since = Std.parseInt(parts[1].indexOf("since=") >= 0 ? parts[1].split("since=")[1].split("&")[0] : "");
			if (since != null && since >= 0) {
				var end = haxe.Timer.stamp() + 20;
				while (haxe.Timer.stamp() < end) {
					lock.acquire();
					var newer = assetVersion > since;
					lock.release();
					if (newer)
						break;
					Sys.sleep(0.01);
				}
			}
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

	static function send(client:Socket, status:Int, type:String, body:haxe.io.Bytes, ?extra = "") {
		var reason = switch (status) {
			case 200: "OK";
			case 206: "Partial Content";
			default: "Not Found";
		}
		client.output.writeString('HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.length}\r\n'
			+ 'Accept-Ranges: bytes\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n${extra}Connection: close\r\n\r\n');
		client.output.write(body);
		client.output.flush();
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
