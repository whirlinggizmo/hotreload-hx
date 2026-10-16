/** the smoke test's main class: ticks Game, which the test edits while it runs **/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.beforeReload = () -> Sys.println("main: beforeReload");
		reloader.afterReload = () -> Sys.println("main: afterReload");
		// the test names a directory for it (RunTests: tests/reload/assets)
		var assets = Sys.getEnv("HOTRELOAD_TEST_ASSETS");
		if (assets != null)
			reloader.watchAssets(assets);
		reloader.assetsChanged = paths -> Sys.println("main: assetsChanged " + paths.join(","));
		while (true) {
			reloader.update();
			Game.tick();
			Sys.sleep(0.1);
		}
	}
}
