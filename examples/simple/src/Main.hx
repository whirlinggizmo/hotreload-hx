/**
	hotreload's simple: wgrender's simple example (wgrender-c's bindings/haxe/examples/simple-hxcpp),
	hot reloaded. This is the main class, never reloaded. wgrender owns the loop, so the
	reloader is pumped from the frame callback, before Simple's frame; run it with
	`haxe hot.hxml`, edit src/Simple.hx, save, and the next frame is the new code.
	Escape to quit.

	It loads its assets from `assets` beside the executable or in the working directory,
	or from $WGR_ASSET_BASE. Once, from this directory:

	```
	ln -s "$(haxelib libpath wgrender-hx)../../examples/assets" assets
	```
**/
import wgr.*;

class Main {
	static function main() {
		Wgr.initValues(Simple.SCREEN_WIDTH, Simple.SCREEN_HEIGHT, "simple (wgrender, Haxe, hot reload)", Msaa4x | Resizable);
		var reloader = new hotreload.Reloader();
		Wgr.setInit(Simple.onInit);
		Wgr.setFrame((dt, tickFraction) -> {
			reloader.update(); // pumps the file watcher, module builder, and reloader
			Simple.frame(dt, tickFraction);
		});
		Sys.exit(Wgr.run());
	}
}
