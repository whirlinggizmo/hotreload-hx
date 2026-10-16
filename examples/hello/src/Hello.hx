using StringTools;

/**
	hotreload's hello: the reloaded class. Edit it while it runs (the name, how often it
	speaks) and save; or edit assets/greeting.txt, an asset, which is read again as it's
	saved.
**/
class Hello {
	// kept across reloads. Its first value is used once, when it's made: an edit here
	// changes nothing while it runs; to change it, assign it (in sayReloaded, say)
	@:hot static var name = "world";

	@:hot static var ticks = 0; // kept: it counts on through each reload
	static var sinceReload = 0; // a plain static: starts over with each reload

	@:hot static var greeting = "Hello"; // read from assets/greeting.txt

	public static function onStart() {
		greeting = readGreeting();
		#if hotreload
		Sys.println("hello: running. Edit src/Hello.hx, or assets/greeting.txt, and save; Ctrl-C to stop.");
		#else
		Sys.println("hello: running (no hot reload in this build: `haxe hot.hxml` for that). Ctrl-C to stop.");
		#end
	}

	@:beforeHotReload static function sayBeforeReloaded() {
		Sys.println("hello: reloading...");
	}

	@:afterHotReload static function sayReloaded() {
		Sys.println("hello: reloaded");
	}

	@:hot public static function onTick() {
		ticks++;
		sinceReload++;
		if (ticks % 4 == 0)
			Sys.println('$greeting, $name! (ticks: $ticks, since the last reload: $sinceReload)');
	}

	/** saved assets, by path, from the reloader (hot builds only) **/
	@:hot public static function onAssetsChanged(paths:Array<String>) {
		if (paths.contains("assets/greeting.txt")) {
			greeting = readGreeting();
			Sys.println('hello: the greeting is now "$greeting"');
		}
	}

	static function readGreeting():String {
		var text = try sys.io.File.getContent("assets/greeting.txt").trim() catch (_) "";
		return text == "" ? "Hello" : text;
	}
}
