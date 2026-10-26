using Lambda;
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
		readGreeting();
		#if !hotreload
		say("hello: running (no hot reload in this build: `haxe dev.hxml` for that)");
		#else
		say("hello: running. Edit src/Hello.hx, or assets/greeting.txt, and save.");
		#end
	}

	@:beforeHotReload static function sayBeforeReloaded() {
		say("hello: reloading...");
	}

	@:afterHotReload static function sayReloaded() {
		say("hello: reloaded");
	}

	public static function onTick() {
		ticks++;
		sinceReload++;
		if (ticks % 4 == 0)
			say('$greeting, $name! (ticks: $ticks, since the last reload: $sinceReload)');
	}

	/** saved assets, from the reloader (hot builds only), by URL **/
	public static function onAssetsChanged(urls:Array<String>) {
		if (urls.exists(u -> u.endsWith("assets/greeting.txt")))
			readGreeting(() -> say('hello: the greeting is now "$greeting"'));
	}

	/** sets `greeting` from assets/greeting.txt, once it's fetched **/
	static function readGreeting(?then:() -> Void) {
		function set(text:String) {
			text = text.trim();
			greeting = text == "" ? "Hello" : text;
			if (then != null)
				then();
		}
		js.Browser.window.fetch("assets/greeting.txt", {cache: NO_STORE})
			.then(r -> r.ok ? r.text() : js.lib.Promise.resolve(""))
			.then(set, _ -> set(""));
	}

	static function say(line:String) {
		js.Browser.console.log(line);
		var log = js.Browser.document.getElementById("log");
		if (log != null)
			log.textContent += line + "\n";
	}
}
