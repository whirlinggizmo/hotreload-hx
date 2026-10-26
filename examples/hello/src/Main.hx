/**
	hotreload's hello: the main class. It calls Hello a few times a second; run it with
	`haxe dev.hxml` (a page, served by hotreload's dev server), open http://localhost:8080/,
	edit src/Hello.hx, save, and the next calls are the new code. Edit assets/greeting.txt,
	and the next greeting is the new one, with nothing rebuilt.

	Every class reloads, this one too, but a reloaded bundle's `main` doesn't run again.
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		// through Hello each time, so a reload's new code gets the call
		reloader.assetsChanged = urls -> Hello.onAssetsChanged(urls);
		Hello.onStart();
		js.Browser.window.setInterval(() -> Hello.onTick(), 250);
	}
}
