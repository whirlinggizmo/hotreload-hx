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
	static var sinceReload = 0; // a plain static: on native, starts over with each reload

	@:hot static var greeting = "Hello"; // read from assets/greeting.txt

	public static function onStart() {
		readGreeting();
		#if !hotreload
		say("hello: running (no hot reload in this build: `haxe hot.hxml` or `haxe web.hxml` for that)");
		#elseif js
		say("hello: running. Edit src/Hello.hx, or assets/greeting.txt, and save.");
		#else
		say("hello: running. Edit src/Hello.hx, or assets/greeting.txt, and save; Ctrl-C to stop.");
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

	/** saved assets, from the reloader (hot builds only): paths on native, URLs on JS **/
	public static function onAssetsChanged(paths:Array<String>) {
		if (paths.exists(p -> p.endsWith("assets/greeting.txt")))
			readGreeting(() -> say('hello: the greeting is now "$greeting"'));
	}

	/** sets `greeting` from assets/greeting.txt: at once on native, once it's fetched on JS **/
	static function readGreeting(?then:() -> Void) {
		function set(text:String) {
			text = text.trim();
			greeting = text == "" ? "Hello" : text;
			if (then != null)
				then();
		}
		#if js
		js.Browser.window.fetch("assets/greeting.txt", {cache: NO_STORE})
			.then(r -> r.ok ? r.text() : js.lib.Promise.resolve(""))
			.then(set, _ -> set(""));
		#else
		set(try sys.io.File.getContent("assets/greeting.txt") catch (_) "");
		#end
	}

	static function say(line:String) {
		#if js
		js.Browser.console.log(line);
		var log = js.Browser.document.getElementById("log");
		if (log != null)
			log.textContent += line + "\n";
		#else
		Sys.println(line);
		#end
	}
}
