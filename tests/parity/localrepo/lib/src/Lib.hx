/**
	a library in the project's own repository (.haxelib/, haxelib newrepo): not the project's code,
	so its method passed as a value isn't warned about, and its directory isn't watched
**/
class Lib {
	public static function start() {
		var held = later;
		held();
	}

	static function later() {}
}
