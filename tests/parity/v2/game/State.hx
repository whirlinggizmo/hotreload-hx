package game;

/** v2: a new first value for the plain static, two @:hot statics' types changed, and a new @:hot static **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	@:hot public static var service(default, null):String;

	@:hot static var kept = 0;
	static var plain = 2;
	@:hot static var widened:Float = 0;
	@:hot static var label = "seven";
	@:hot static var added = 42;

	@:hot public static function start() {
		kept = 5;
		plain = 5;
		widened = 3;
		report();
	}

	@:afterHotReload static function after() {
		report();
	}

	static function report() {
		Main.say('report v2 kept=$kept plain=$plain widened=$widened label=$label added=$added service=$service outside=${Outside.count} main=${Main.count}');
	}
}
