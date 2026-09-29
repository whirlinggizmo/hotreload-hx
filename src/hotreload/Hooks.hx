package hotreload;

/**
	What a reload calls: the running code's `@:beforeHotReload` and `@:afterHotReload`
	hooks, which their classes' static initializers add (as the macro makes them), and the
	executable's `@:hot` functions, whose calls a reload points at the new code
**/
@:keep
class Hooks {
	static var before = new Array<() -> Void>();
	static var after = new Array<() -> Void>();

	/** the executable's `@:hot` functions **/
	public static var procs(default, null) = new Array<HotProc>();

	public static function add(isAfter:Bool, hook:() -> Void):Bool {
		(isAfter ? after : before).push(hook);
		return true;
	}

	public static function proc(className:String, name:String, sig:String, point:Dynamic->Void):Bool {
		procs.push({className: className, name: name, sig: sig, point: point});
		return true;
	}

	public static function runBefore() {
		for (hook in before)
			hook();
	}

	public static function runAfter() {
		for (hook in after)
			hook();
	}

	/** before a module boots, which adds its own **/
	public static function forget() {
		before = [];
		after = [];
	}
}

typedef HotProc = {
	/** the class, by its own name (not the executable's copy's) **/
	var className:String;

	var name:String;
	var sig:String;

	/** points the executable's calls at a module's function **/
	var point:Dynamic->Void;
}
