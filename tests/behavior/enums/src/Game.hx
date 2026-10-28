enum Mood {
	Happy;
	Sad;
	Angry(level:Int);
}

class Game {
	static var held:Mood;
	static var edited:Mood = Happy;

	/** what a closure holds: the reload doesn't reach it **/
	static var captured:() -> String;

	public static function start() {
		held = Sad;
		var mood = Sad;
		var angry = Angry(3);
		captured = () -> describe(mood) + " " + describe(angry) + " " + isSad(mood);
		report();
	}

	public static function report()
		Main.say('enums held=${describe(held)} captured=${captured()} edited=${describe(edited)} ${isSad(edited)}');

	static function describe(m:Mood):String {
		return switch (m) {
			case Happy: "happy";
			case Sad: "sad";
			case Angry(level): 'angry$level';
			case _: "other";
		}
	}

	static function isSad(m:Mood):Bool
		return m == Sad;
}
