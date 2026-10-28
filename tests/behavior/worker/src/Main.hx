/**
	The worker test: a page that starts a web worker from the hot bundle itself. Both run the
	program, and both take on the new code when it is reloaded, each on its own
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Game.report();
		if (inPage())
			js.Syntax.code("new Worker('main.js')");
		Game.report();
	}

	public static function inPage():Bool
		return js.Syntax.code("typeof document != 'undefined'");

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}

class Game {
	public static function report()
		Main.say('worker-test ${Main.inPage() ? "page" : "worker"} v1');
}
