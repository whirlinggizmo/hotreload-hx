package hotreload;

/**
	Provides the reload hooks that a reload calls.

	The hooks are the running code's `@:beforeHotReload` and `@:afterHotReload` functions.
	Their classes' static initializers add them, as the build macro generates them.
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
