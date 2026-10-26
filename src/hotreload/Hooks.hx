package hotreload;

/**
	What a reload calls: the running code's `@:beforeHotReload` and `@:afterHotReload`
	hooks, which their classes' static initializers add (as the macro makes them)
**/
@:keep
class Hooks {
	static var before = new Array<() -> Void>();
	static var after = new Array<() -> Void>();

	public static function add(isAfter:Bool, hook:() -> Void):Bool {
		(isAfter ? after : before).push(hook);
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
}
