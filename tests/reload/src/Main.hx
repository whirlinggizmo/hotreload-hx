/** the smoke test's main class: ticks Game, which the test edits while it runs **/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.beforeReload = () -> Sys.println("main: beforeReload");
		reloader.afterReload = () -> Sys.println("main: afterReload");
		while (true) {
			reloader.update();
			Game.tick();
			Sys.sleep(0.1);
		}
	}
}
