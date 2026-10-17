package game;

/** v2: a new first value for the plain static, two @:hot statics' types changed, and a new @:hot static **/
class State {
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
		Main.say('report v2 kept=$kept plain=$plain widened=$widened label=$label added=$added outside=${Outside.count} main=${Main.count}');
	}
}
