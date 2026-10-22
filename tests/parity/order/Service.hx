import Facade;

/**
	statics with no type written, which the hot build mustn't type while Service is built:
	that would build Facade first, before Service's own build macro has run
**/
@:build(Mark.record())
class Service {
	public static var MAX = 8 * 1024;
	@:hot static var made = new haxe.ds.StringMap<Int>();

	@:hot public static function size(scale = 2):Int
		return MAX * scale + Facade.extra();
}
