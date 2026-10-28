/**
	The enum test's main class: enum values across a reload that puts a constructor before
	the others. One a static holds, which the reload walks to; ones a closure holds, which
	it doesn't; and a static's edited first value, made by the new code
**/
class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Game.report();
		Game.start();
	}

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}
