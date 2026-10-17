package game;

/** the reloaded code: each rule for statics, reported as built and after each reload **/
class State {
	@:hot static var kept = 0;
	static var plain = 1;
	@:hot static var widened:Int = 0;
	@:hot static var label = 7;

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
		Main.say('report v1 kept=$kept plain=$plain widened=$widened label=$label outside=${Outside.count} main=${Main.count}');
	}
}
