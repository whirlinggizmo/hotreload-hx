/**
	The matrix's main class for JS (node): the same as src/Main.hx, but ticking on a timer,
	since JS has no loop to sleep in. It calls Game.tick through the class, as Haxe code
	does, so a reload's new tick is the one called
**/
class Main {
	static function main() {
		new hotreload.Reloader();
		var held = Game.makeHeld(); // S14: an object of a reloaded class, kept by main
		var callback = Game.makeCallback(); // S10: a callback reloaded code handed to main
		var n = 0;
		js.Syntax.code("setInterval({0}, 50)", () -> {
			Game.tick();
			if (n % 20 == 10)
				Sys.println('main: held=${held.describe()} callback=${callback()}');
			n++;
		});
	}
}
