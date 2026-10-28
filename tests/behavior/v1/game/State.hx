package game;

/** the reloaded code: each rule for statics, reported as built and after each reload **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	public static var service(default, null):String;

	static var kept = 0;

	// a computed property: no storage, so no value to keep or to reset to
	public static var doubled(get, never):Int;

	static function get_doubled():Int
		return kept * 2;
	static var tuned = 1;
	static var widened:Int = 0;
	static var label:Int = 7;
	static var mode:Int;
	@:resetOnHotReload static var cache = 1;

	static var loaded = "";

	public static function start() {
		kept = 5;
		tuned = 5;
		widened = 3;
		mode = 5;
		cache = 5;
		report();
	}

	/** a completion for the main class to hold: a lambda of this code, calling a function by name **/
	public static function completion():Int->Void {
		return x -> onLoaded(x);
	}

	static function onLoaded(x:Int):Void {
		loaded = "v1:" + x;
	}

	public static function report():Void {
		Main.say('report v1 kept=$kept doubled=$doubled tuned=$tuned widened=$widened label=$label mode=$mode cache=$cache service=$service outside=${Outside.count},${Outside.tag},${Outside.n},${Outside.list.length} main=${Main.count} loaded=$loaded');
	}
}
