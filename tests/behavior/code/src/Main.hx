/**
	The code-change test: one edit to what a reload cannot bring in, each said. The main,
	a closure main made, the constructor of an object made before, a field initializer, a
	field's type, and a field renamed
**/
class Main {
	static var enemy:Enemy;
	static var ticker:() -> String;

	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> report();
		enemy = new Enemy();
		ticker = () -> "tick v1";
		report();
	}

	static function report()
		say('code ${ticker()} hp=${enemy.hp} shield=${enemy.shield}');

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}

class Enemy {
	public var hp:Int;
	public var shield = 10;
	public var mana = 5;

	public function new() {
		hp = 3;
	}
}
