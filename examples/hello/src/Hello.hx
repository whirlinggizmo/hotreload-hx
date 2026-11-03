using Lambda;
using StringTools;

/**
	The class to edit while hello runs.

	Try changing the name, or how often it speaks, and save. You can also edit
	assets/greeting.txt, which is read again whenever it is saved.
**/
class Hello {
	// Kept across reloads. If you edit this initial value, the reload uses the new one.
	static var name = "world";

	static var ticks = 0; // Kept across reloads, so it keeps counting.
	@:resetOnHotReload static var sinceReload = 0; // Starts over on every reload.

	static var greeting = "Hello"; // Read from assets/greeting.txt.

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

	/** Called by the reloader with the URLs of saved assets. Hot builds only. **/
	public static function onAssetsChanged(urls:Array<String>) {
		if (urls.exists(u -> u.endsWith("assets/greeting.txt")))
			readGreeting(() -> say('hello: the greeting is now "$greeting"'));
	}

	/** Sets `greeting` from assets/greeting.txt once it has been fetched. **/
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
