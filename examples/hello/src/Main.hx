/**
	hotreload's hello: the main class. It calls Hello a few times a second; run it with
	`haxe hot.hxml` (native) or `haxe web.hxml` (a page, served by hotreload's dev server),
	edit src/Hello.hx, save, and the next calls are the new code. Edit assets/greeting.txt,
	and the next greeting is the new one, with nothing rebuilt.

	On native, it's never reloaded; on JS every class reloads, this one too, but a reloaded
	bundle's `main` doesn't run again.
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.watchAssets("assets");
		// through Hello each time, so a reload's new code gets the call
		reloader.assetsChanged = paths -> Hello.onAssetsChanged(paths);
		Hello.onStart();
		#if js
		js.Browser.window.setInterval(() -> Hello.onTick(), 250);
		#else
		while (true) {
			reloader.update(); // pumps the file watcher, module builder, and reloader
			Hello.onTick();
			Sys.sleep(0.25);
		}
		#end
	}
}
