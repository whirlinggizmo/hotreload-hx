/**
	The recovery test: an abstract's statics across reloads, a reload hook that throws, and a
	bundle whose static initializer throws. Reloads go on after each failure, and a failed load
	leaves the running code's enum constants as they were
**/
abstract Counter(Int) {
	public static var count = 1;
	public static var edited = 10;
}

enum Mood {
	Happy;
	Sad;
}

class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Game.report();
		Counter.count = 2;
		Counter.edited = 20;
		Game.held = Sad;
		js.Syntax.code("setInterval({0}, 100)", () -> Game.check());
		Game.report();
	}

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);

	public static function fail():Int
		throw "bad init";
}

class Game {
	public static var held:Mood;

	public static function report()
		Main.say('recovery v1 count=${Counter.count} edited=${Counter.edited}');

	/** the running code's switch on a constant, every 100 ms: said only when it is wrong **/
	public static function check()
		if (describe(held) != "sad")
			Main.say('recovery wrong held=${describe(held)}');

	static function describe(m:Mood):String {
		return switch (m) {
			case Happy: "happy";
			case Sad: "sad";
			case _: "other";
		}
	}
}
