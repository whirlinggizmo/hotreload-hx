/**
	a library in the project's own repository (.haxelib/, haxelib newrepo): not the project's code,
	so its directory isn't watched. Its static function passed as a value is late-bound, as the project's
**/
class Lib {
	public static function start() {
		var held = later;
		held();
	}

	static function later() {}
}
