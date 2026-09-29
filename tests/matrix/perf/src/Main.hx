class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Bench.run("reloaded");
		Bench.run("native");
		while (true) {
			reloader.update();
			Sys.sleep(0.05);
		}
	}
}
