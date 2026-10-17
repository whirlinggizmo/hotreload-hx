package game;

/** the reloaded code: each rule for statics, reported as built and after each reload **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	@:hot public static var service(default, null):String;

	@:hot static var kept = 0;

	// a computed property: no storage, so no value to keep or to start over from
	public static var doubled(get, never):Int;

	static function get_doubled():Int
		return kept * 2;
	static var plain = 1;
	@:hot static var widened:Int = 0;
	@:hot static var label = 7;

	@:hot static var loaded = "";

	public static function start() {
		kept = 5;
		plain = 5;
		widened = 3;
		report();
	}

	/** a completion for the main class to hold: a lambda of this code, calling a @:hot function by name. (start, completion and report are the main class's calls: the build marks them @:hot itself) **/
	public static function completion():Int->Void {
		return x -> onLoaded(x);
	}

	@:hot static function onLoaded(x:Int):Void {
		loaded = "v1:" + x;
	}

	public static function report():Void {
		Main.say('report v1 kept=$kept doubled=$doubled plain=$plain widened=$widened label=$label service=$service outside=${Outside.count},${Outside.tag},${Outside.n},${Outside.list.length} main=${Main.count} loaded=$loaded');
	}
}
