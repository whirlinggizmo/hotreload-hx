/**
	hotreload's hello: the reloaded class. Edit it while it runs (the greeting, the name,
	how often it speaks) and save.
**/
class Hello {
	// kept across reloads. Its first value is used once, when it's made: an edit here
	// changes nothing while it runs; to change it, assign it (in sayReloaded, say)
	@:hot static var name = "world";

	@:hot static var ticks = 0; // kept: it counts on through each reload
	static var sinceReload = 0; // a plain static: starts over with each reload

	public static function onStart() {
		#if hotreload
		Sys.println("hello: running. Edit src/Hello.hx and save; Ctrl-C to stop.");
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
			Sys.println('Hello, $name! (ticks: $ticks, since the last reload: $sinceReload)');
	}
}
