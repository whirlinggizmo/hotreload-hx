package game;

/** v3: v2 with a new onLoaded, which the completion made by v2 must reach **/
@:allow(Main)
class State {
	// set by the main class, read by everyone (as a framework's services): no first value
	@:hot public static var service(default, null):String;

	@:hot static var kept = 0;
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
		loaded = "v3:" + x;
	}

	public static function report():Void {
		Main.say('report v3 kept=$kept plain=$plain widened=$widened label=$label added=$added service=$service outside=${Outside.count},${Outside.tag},${Outside.n},${Outside.list.length} main=${Main.count} loaded=$loaded');
	}
}
