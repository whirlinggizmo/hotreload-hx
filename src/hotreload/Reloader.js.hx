package hotreload;

/**
	The JS reloader. A JS build reloads whole: hotreload.DevServer rebuilds the bundle
	when a source changes, and each bundle that loads asks it, a few times a second,
	whether there's a newer one. When there is, it loads it beside itself (the page's
	host, the engine and the GPU's state stay as they are) and makes its classes the
	current ones (JsSwap): the same statics, the same objects, the new code.

	Nothing to call: a hot build (-D hotreload) starts it as the bundle loads, and a
	reload happens between two frames, whenever the new bundle has loaded (JS runs one
	thing at a time). `new Reloader()` and `update()` are here so the same main class
	builds for cpp too, where they're the whole of it.
**/
class Reloader {
	/** the main class's: just before a swap, after the old code's `@:beforeHotReload` hooks **/
	public var beforeReload:() -> Void;

	/** the main class's: just after, after the new code's `@:afterHotReload` hooks **/
	public var afterReload:() -> Void;

	public function new() {
		#if hotreload
		JsSwap.reloaders.push(this);
		#end
	}

	/** nothing to do on JS: a reload happens as soon as the new bundle has loaded **/
	public inline function update() {}

	public inline function dispose() {}

	#if hotreload
	/** whether this bundle is a reload's, not the one the page (or node) started with **/
	static var reloaded:Bool;

	/** whether this bundle is a reload's: its main mustn't start the program again **/
	public static function isReload():Bool
		return reloaded;

	static function __init__() {
		reloaded = JsSwap.register(Type.resolveClass("hotreload.Reloader"));
	}
	#else
	public static inline function isReload():Bool
		return false;
	#end
}
