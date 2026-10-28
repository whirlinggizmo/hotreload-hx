/**
	The behavior test's main class: its statics are kept. It sets the statics, and
	game.State reports them, as built and after each reload
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
		// a function by name, so after a reload it reaches the new code. Made again after
		// each reload, by the code just loaded: the one the second reload finds was made by
		// a reloaded bundle, not the first
		var completion = game.State.completion();
		completion(7);
		reloader.afterReload = () -> {
			completion(8);
			game.State.report();
			completion = game.State.completion();
		};
		game.State.start();
	}

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}
