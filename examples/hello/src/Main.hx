/**
	hotreload's hello: the main class, never reloaded. It calls Hello a few times a
	second; run it with `haxe hot.hxml`, edit src/Hello.hx, save, and the next calls are
	the new code. Edit assets/greeting.txt, and the next greeting is the new one, with
	nothing rebuilt. Ctrl-C to stop.
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.watchAssets("assets");
		// through Hello each time, so a reload's new code gets the call
		reloader.assetsChanged = paths -> Hello.onAssetsChanged(paths);
		Hello.onStart();
		while (true) {
			reloader.update(); // pumps the file watcher, module builder, and reloader
			Hello.onTick();
			Sys.sleep(0.25);
		}
	}
}
