/**
	hotreload's hello: the main class, never reloaded. It calls Hello a few times a
	second; run it with `haxe hot.hxml`, edit src/Hello.hx, save, and the next calls are
	the new code. Ctrl-C to stop.
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		Hello.onStart();
		while (true) {
			reloader.update(); // pumps the file watcher, module builder, and reloader
			Hello.onTick();
			Sys.sleep(0.25);
		}
	}
}
