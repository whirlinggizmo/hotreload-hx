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
		Outside.tag = "t";
		Outside.n = 5;
		Outside.list.push(1);
		game.State.service = "on";
		var reloader = new hotreload.Reloader();
		// a completion the reloaded code made, held here across the next reload: it calls
		// a @:hot function, so after a reload it reaches the new code, on both targets.
		// Made again after each reload, by the code just loaded: the one the second reload
		// finds was made by a module, not by the executable's own copy of the code
		var completion = game.State.completion();
		completion(7);
		reloader.afterReload = () -> {
			completion(8);
			game.State.report();
			completion = game.State.completion();
		};
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
