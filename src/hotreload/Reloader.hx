package hotreload;

/**
	Represents the reloader of a hot build.

	A hot build reloads whole. hotreload.DevServer rebuilds the bundle when a source changes,
	and each bundle that loads asks the DevServer whether there is a newer one. When there is,
	the bundle loads it beside itself and makes its classes the current ones (JsSwap). The
	page's host, the engine and the GPU's state stay unchanged. The statics and the objects
	stay the same, and the code is the new code.

	Nothing needs to be called. A hot build (-D hotreload) starts the reloader as the bundle
	loads. A reload happens between two frames, whenever the new bundle has loaded (JS runs one
	thing at a time). `new Reloader()` is for the main class's callbacks. Outside a hot JS
	build, on any target, the reloader does nothing, so the same main class builds everywhere.
**/
class Reloader {
	/**
		Gets or sets the main class's callback, called just before a swap, after the old code's
		`@:beforeHotReload` hooks.
	**/
	public var beforeReload:() -> Void;

	/**
		Gets or sets the main class's callback, called just after a swap, after the new code's
		`@:afterHotReload` hooks.
	**/
	public var afterReload:() -> Void;

	/**
		Gets or sets the main class's callback for served files that changed.

		It receives the files' URLs (`/assets/sounds/fire.ogg`) once their saves have settled.
		The DevServer watches its output directory and its mounts. Nothing is rebuilt. What to
		load again, and how, is up to the program.
	**/
	public var assetsChanged:(urls:Array<String>) -> Void;

	public function new() {
		#if (js && hotreload)
		JsSwap.reloaders.push(this);
		#end
	}

	/** Does nothing. A reload happens as soon as the new bundle has loaded. **/
	public inline function update() {}

	/** Does nothing. The DevServer watches every file it serves (`--mount` serves more). **/
	public inline function watchAssets(dir:String) {}

	public inline function dispose() {}

	#if (js && hotreload)
	/** Whether this bundle is a reload's, not the one the page (or node) started with. **/
	static var reloaded:Bool;

	/**
		Returns whether this bundle is a reload's.

		A reload's main must not start the program again.
	**/
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
