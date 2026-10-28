package hotreload;

/**
	Provides the reload hooks that a reload calls.

	The hooks are the running code's `@:beforeHotReload` and `@:afterHotReload` functions.
	Their classes' static initializers add them, as the build macro generates them. A hook
	that throws does not stop the others or the reload. Its failure is passed on.
**/
@:keep
class Hooks {
	static var before = new Array<{name:String, hook:() -> Void}>();
	static var after = new Array<{name:String, hook:() -> Void}>();

	/**
		Adds a hook.

		@param isAfter  True for an `@:afterHotReload` hook, false for a `@:beforeHotReload` one.
		@param name  The hook's class and function, for a failure's message.
		@param hook  The hook.
		@return  True, for the static var the build macro initializes with it.
	**/
	public static function add(isAfter:Bool, name:String, hook:() -> Void):Bool {
		(isAfter ? after : before).push({name: name, hook: hook});
		return true;
	}

	/**
		Runs the `@:beforeHotReload` hooks.

		@param failed  Receives the name and the error of each hook that throws.
	**/
	public static function runBefore(failed:(String, Dynamic) -> Void)
		run(before, failed);

	/**
		Runs the `@:afterHotReload` hooks.

		@param failed  Receives the name and the error of each hook that throws.
	**/
	public static function runAfter(failed:(String, Dynamic) -> Void)
		run(after, failed);

	static function run(hooks:Array<{name:String, hook:() -> Void}>, failed:(String, Dynamic) -> Void) {
		for (h in hooks)
			try {
				h.hook();
			} catch (e:Dynamic) {
				failed(h.name, e);
			}
	}
}
