package game;

/** v3: v2 with a new onLoaded, which the completion made by v2 must reach, and nothing else changed: no static reset but the one marked **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	public static var service(default, null):String;

	static var kept = 0;

	// a computed property: no storage, so no value to keep or to reset to
	public static var doubled(get, never):Int;

	static function get_doubled():Int
		return kept * 2;
	static var tuned = 2;
	static var widened:Float = 0;
	static var label:String = "seven";
	static var mode:String;
	@:resetOnHotReload static var cache = 1;
	static var added = 42;

	static var loaded = "";

	public static function start() {
		kept = 5;
		tuned = 5;
		widened = 3;
		mode = "five";
		cache = 5;
		report();
	}

	/** a completion for the main class to hold: a lambda of this code, calling a function by name **/
	public static function completion():Int->Void {
		return x -> onLoaded(x);
	}

	static function onLoaded(x:Int):Void {
		loaded = "v3:" + x;
	}

	public static function report():Void {
		Main.say('report v3 kept=$kept doubled=$doubled tuned=$tuned widened=$widened label=$label mode=$mode cache=$cache added=$added service=$service outside=${Outside.count},${Outside.tag},${Outside.n},${Outside.list.length} main=${Main.count} loaded=$loaded');
	}
}
