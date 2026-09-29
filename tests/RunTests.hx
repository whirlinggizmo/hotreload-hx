import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

using StringTools;

/**
	The smoke test: builds tests/reload/ hot, runs it, and edits its sources while it runs,
	checking what each reload does. `haxe tests/run.hxml` from the repo's directory.
**/
class RunTests {
	static var dir:String;
	static var output:Output;
	static var failures = 0;

	static function main() {
		dir = Path.normalize(Path.join([Sys.getCwd(), "tests/reload"]));
		copyVersion("v1");

		step("build the program hot");
		if (Sys.command("haxe", ["--cwd", dir, "build.hxml"]) != 0)
			fail("the build failed");

		// its output goes to a file, which this reads as it grows: a thread blocked reading
		// a pipe would hold up this one (the interpreter's threads take turns)
		var log = '$dir/out/hot/run.log';
		File.saveContent(log, "");
		var program = new Process("sh", ["-c", 'exec "$$0" > "$$1" 2>&1', '$dir/out/hot/Main-debug', log]);
		output = new Output(log);

		try {
			step("it runs the code it was built with");
			expect(~/^hotreload: watching for changes to Game.hx/);
			var v1 = expect(~/^v1 ticks=(\d+) hp3,hp5 mood=Happy\(1\) label=7 cycle=true map=true isEnemy=true isMood=true$/);
			var ticks = Std.parseInt(v1.matched(1));

			step("a reload runs the new code, with the hot statics carried over");
			copyVersion("v2");
			expect(~/^hotreload: building/);
			expect(~/^before: v1$/);
			expect(~/^main: beforeReload$/);
			expect(~/^after: v2$/);
			expect(~/^main: afterReload$/);
			expect(~/^hotreload: reloaded/);
			var v2 = expect(~/^v2 ticks=(\d+) hp3\/s10,hp5\/s10 mood=Happy\(1\) label=7 cycle=true map=true isEnemy=true isMood=true$/);
			check(Std.parseInt(v2.matched(1)) > ticks, "ticks counts on through the reload");

			step("a hot static whose type changed to another kind starts over");
			edit("Game.hx", "@:hot static var label = 7;", "@:hot static var label = \"seven\";");
			expect(~/^hotreload: Game.label's type changed \(Int to String\); started over/);
			expect(~/^v2 ticks=\d+ hp3\/s10,hp5\/s10 mood=Happy\(1\) label=seven /);

			step("a @:hot function whose signature changed is refused, and the last code runs on");
			edit("Game.hx", "public static function tick()", "public static function tick(n:Int = 1)");
			expect(~/^hotreload: Game.tick's signature changed: restart to run the new code/);
			expect(~/^v2 ticks=\d+ .* label=seven /);
			edit("Game.hx", "public static function tick(n:Int = 1)", "public static function tick()");
			expect(~/^hotreload: reloaded/);

			step("a build that fails leaves the last code running");
			edit("Game.hx", "static function describe() {", "static function describe() { oops");
			expect(~/^hotreload: build failed; still running the last one$/);
			expect(~/^v2 ticks=/);

			step("the next good build reloads");
			edit("Game.hx", "static function describe() { oops", "static function describe() {");
			edit("Game.hx", "'v2 ticks", "'v3 ticks");
			expect(~/^v3 ticks=\d+ hp3\/s10,hp5\/s10 mood=Happy\(1\) label=seven cycle=true map=true isEnemy=true isMood=true$/);

			step("a second save in the same second as the first is built too");
			edit("Game.hx", "'v3 ticks", "'v4 ticks");
			expect(~/^hotreload: building/);
			edit("Game.hx", "'v4 ticks", "'v5 ticks");
			expect(~/^v5 ticks=/);
		} catch (e:String) {
			fail(e);
		}

		program.kill();
		program.close();
		copyVersion("v1");
		Sys.println(failures == 0 ? "\nall passed" : '\n$failures failed');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function step(what:String) {
		Sys.println('\n== $what');
	}

	/** waits for a line of the program's output that matches, showing each **/
	static function expect(re:EReg, timeout = 30.0):EReg {
		var deadline = haxe.Timer.stamp() + timeout;
		var skipped = [];
		while (haxe.Timer.stamp() < deadline) {
			var line = output.next();
			if (line == null) {
				Sys.sleep(0.02);
				continue;
			}
			if (Sys.getEnv("VERBOSE") != null && !~/^v\d ticks=/.match(line))
				Sys.println("    > " + line);
			if (re.match(line)) {
				Sys.println('  ok: $line');
				return re;
			}
			// what else it said, but its ticks
			if (!~/^v\d ticks=/.match(line))
				skipped.push(line);
		}
		throw 'timed out waiting for ${Std.string(re)}' + [for (l in skipped) '\n    it said: $l'].join("");
	}

	static function check(cond:Bool, what:String) {
		if (cond)
			Sys.println('  ok: $what');
		else
			fail(what);
	}

	static function fail(what:String) {
		failures++;
		Sys.println('  FAILED: $what');
	}

	/** a version's sources into src/, beside Main.hx **/
	static function copyVersion(version:String) {
		function copy(from:String, to:String) {
			for (entry in FileSystem.readDirectory(from)) {
				var src = '$from/$entry', dst = '$to/$entry';
				if (FileSystem.isDirectory(src)) {
					FileSystem.createDirectory(dst);
					copy(src, dst);
				} else if (!FileSystem.exists(dst) || File.getContent(dst) != File.getContent(src)) {
					save(dst, File.getContent(src));
				}
			}
		}
		copy('$dir/$version', '$dir/src');
	}

	static function edit(file:String, from:String, to:String) {
		var path = '$dir/src/$file';
		var content = File.getContent(path);
		if (!content.contains(from))
			throw '$file has no "$from" to edit';
		save(path, content.replace(from, to));
	}

	/** as an editor saves: written beside it, then renamed over it **/
	static function save(path:String, content:String) {
		File.saveContent(path + ".tmp", content);
		FileSystem.rename(path + ".tmp", path);
	}
}

/** a file's lines, as it grows **/
private class Output {
	var path:String;
	var read = 0;
	var pending = new Array<String>();

	public function new(path) {
		this.path = path;
	}

	/** the next whole line, or null when there's none yet **/
	public function next():Null<String> {
		if (pending.length == 0) {
			var content = File.getContent(path);
			var end = content.lastIndexOf("\n");
			if (end >= read) {
				pending = content.substring(read, end).split("\n");
				read = end + 1;
			}
		}
		return pending.shift();
	}
}
