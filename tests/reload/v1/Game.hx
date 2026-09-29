import game.Enemy;
import game.Mood;

class Game {
	@:hot static var ticks = 0;
	@:hot static var enemies:Array<Enemy> = pair();
	@:hot static var mood:Mood = Happy(1);
	@:hot static var label = 7;
	@:hot static var byName:Map<String, Enemy> = new Map();

	@:beforeHotReload static function wrapUp() {
		Sys.println("before: v1");
	}

	@:afterHotReload static function fixUp() {
		Sys.println("after: v1");
	}

	static function pair() {
		var a = new Enemy(3), b = new Enemy(5);
		a.buddy = b;
		b.buddy = a;
		return [a, b];
	}

	@:hot public static function tick() {
		ticks++;
		if (!byName.exists("a"))
			byName.set("a", enemies[0]);
		Sys.println('v1 ticks=$ticks ${describe()}');
	}

	static function describe() {
		return enemies.map(e -> e.describe()).join(",")
			+ ' mood=$mood label=$label cycle=${enemies[0].buddy.buddy == enemies[0]} map=${byName.get("a") == enemies[0]}'
			+ ' isEnemy=${Std.isOfType(enemies[0], Enemy)} isMood=${Type.getEnum(mood) == Mood}';
	}
}
