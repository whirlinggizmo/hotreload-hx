import game.Held;

class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		var held = Game.makeHeld(); // S14: an object of a reloaded class, kept by main
		var callback = Game.makeCallback(); // S10: a callback reloaded code handed to main
		var n = 0;
		while (true) {
			reloader.update();
			Game.tick();
			if (n % 20 == 10)
				Sys.println('main: held=${held.describe()} callback=${callback()}');
			n++;
			Sys.sleep(0.05);
		}
	}
}
