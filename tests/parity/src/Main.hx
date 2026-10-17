/**
	The parity test's main class: never part of the reloaded code, so its statics are
	kept on both targets. It sets the statics, and game.State reports them, as built and
	after each reload
**/
class Main {
	public static var count = 0;

	static function main() {
		count = 5;
		Outside.count = 5;
		game.State.service = "on";
		var reloader = new hotreload.Reloader();
		game.State.start();
		#if !js
		while (true) {
			reloader.update();
			Sys.sleep(0.05);
		}
		#end
	}

	public static function say(line:String) {
		#if js
		js.Syntax.code("console.log({0})", line);
		#else
		Sys.println(line);
		#end
	}
}
