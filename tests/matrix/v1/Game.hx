import game.Enemy;
import game.Mood;
import game.Animal;
import game.Held;

typedef Stats = {hp:Int};

class Game {
	@:hot static var ticks = 0;
	@:hot static var enemies:Array<Enemy> = pair();
	@:hot static var stats:Array<Stats> = [{hp: 7}];
	@:hot static var mood:Mood = Happy(1);
	@:hot static var pet:Animal = new Dog();
	@:hot static var fn:() -> String = () -> "v1 closure";
	@:hot static var label = 7;
	@:hot static var fromCallback = 0;
	static var started = false;

	static function pair() {
		var a = new Enemy(3), b = new Enemy(5);
		a.buddy = b;
		b.buddy = a;
		return [a, b];
	}

	public static function makeHeld() return new Held();

	public static function makeCallback():() -> String {
		return () -> {
			fromCallback++;
			return "v1 callback";
		};
	}

	@:afterHotReload static function after() {
		report();
	}

	@:hot public static function tick() {
		ticks++;
		if (!started) {
			started = true;
			report();
		}
	}

	static function report() {
		var e = enemies[0];
		Sys.println('report v1 ticks=$ticks S3=${e.describe()} S4/S5=hp:${e.hp},speed:${e.speed} S3b=${stats[0]} S7=$mood S8=${pet.speak()} '
			+ 'S9=${fn()} S11=${e.buddy.buddy == e && enemies[1].buddy == e} S10=fromCallback:$fromCallback label=$label');
	}
}
