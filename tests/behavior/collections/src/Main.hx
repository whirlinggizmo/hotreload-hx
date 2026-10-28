/**
	The collections test: what a reload's walk reaches inside collections. An enum-keyed map
	whose constructors are reordered, a native Map's keys, and a native Set's items, objects of
	a class that gains a field
**/
enum Mood {
	A;
	B;
	C;
	D;
}

class K {
	public var name = "k";

	public function new() {}
}

class Main {
	static function main() {
		var reloader = new hotreload.Reloader();
		reloader.afterReload = () -> Game.report();
		Game.init();
		Game.report();
	}

	public static function say(line:String)
		js.Syntax.code("console.log({0})", line);
}

class Game {
	static var moods:Map<Mood, String>;
	static var native:js.lib.Map<K, String>;
	static var set:js.lib.Set<K>;

	public static function init() {
		moods = [A => "a", B => "b", C => "c", D => "d"];
		native = new js.lib.Map();
		native.set(new K(), "x");
		set = new js.lib.Set();
		set.add(new K());
	}

	public static function report() {
		var key:Dynamic = js.Syntax.code("[...{0}.keys()][0]", native);
		var item:Dynamic = js.Syntax.code("[...{0}][0]", set);
		Main.say('collections moods=${moods.get(A)},${moods.get(B)},${moods.get(C)},${moods.get(D)} key=${key.name},${key.extra} item=${item.name},${item.extra}');
	}
}
