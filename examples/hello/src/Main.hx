/**
	The main class of the hello example.

	It calls Hello four times a second, and Hello prints a greeting on every fourth call. Run
	it with `haxe dev.hxml` and open http://localhost:8080/. Then edit src/Hello.hx and save,
	and the next call runs the new code. If you edit assets/greeting.txt instead, the next
	greeting uses the new text, with nothing rebuilt.

	Every class reloads, this one included, but `main` doesn't run again after a reload.
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		// Call through Hello each time, so that after a reload the call reaches the new code.
		reloader.assetsChanged = urls -> Hello.onAssetsChanged(urls);
		Hello.onStart();
		js.Browser.window.setInterval(() -> Hello.onTick(), 250);
	}
}
