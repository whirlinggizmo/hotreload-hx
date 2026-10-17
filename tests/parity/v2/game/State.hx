package game;

/** v2: a new first value for the plain static, two @:hot statics' types changed, and a new @:hot static **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	@:hot public static var service(default, null):String;

	@:hot static var kept = 0;

	// a computed property: no storage, so no value to keep or to start over from
	public static var doubled(get, never):Int;

	static function get_doubled():Int
		return kept * 2;
	static var plain = 2;
	@:hot static var widened:Float = 0;
	@:hot static var label = "seven";
	@:hot static var added = 42;

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
		loaded = "v2:" + x;
	}

	public static function report():Void {
		Main.say('report v2 kept=$kept doubled=$doubled plain=$plain widened=$widened label=$label added=$added service=$service outside=${Outside.count},${Outside.tag},${Outside.n},${Outside.list.length} main=${Main.count} loaded=$loaded');
	}
}
