/**
	The bound-method test's main class (JS): a listener added as a bound method before a
	reload, a button's `onClick`, as OpenFL's `addEventListener(MouseEvent.CLICK, onClick)`
	adds one, and a static function, `Button.onTick`. After the reload the dispatcher calls
	them, and the new code removes them
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Game.reloaded();
		Game.start();
	}

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}
