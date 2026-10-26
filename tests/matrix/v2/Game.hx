import game.Enemy;
import game.Mood;
import game.Animal;
import game.Held;

typedef Stats = {hp:Int, ?mana:Int};

class Game {
	static var ticks = 0;
	static var enemies:Array<Enemy> = pair();
	static var stats:Array<Stats> = [{hp: 7}];
	static var mood:Mood = Happy(1);
	static var pet:Animal = new Dog();
	static var fn:() -> String = () -> "v1 closure"; // S9: unchanged, so the v1 closure it holds is kept
	static var label = 7;
	static var fromCallback = 0;
	static var added = 42; // S2
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
			return "v2 callback";
		};
	}

	@:afterHotReload static function after() {
		report();
	}

	public static function tick() {
		ticks++;
		if (!started) {
			started = true;
			report();
		}
	}

	static function report() {
		var e = enemies[0];
		Sys.println('report v2 ticks=$ticks S3=${e.describe()} S4/S5=hp:${e.health},speed:${e.speed} S3b=${stats[0]} S7=$mood S8=${pet.speak()} '
			+ 'S9=${fn()} S11=${e.buddy.buddy == e && enemies[1].buddy == e} S10=fromCallback:$fromCallback label=$label S2=added:$added S12=${game.Extra.hello()} S3b-mana=${stats[0].mana}');
	}
}
