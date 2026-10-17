import Warn as W;

/**
	the warning test's main class: builds, never runs. The build marks what it calls into
	the reloaded code @:hot itself, but can't see a call through an alias, and says so; a
	method it passes as a value is as stuck as one your code passes, and said so too
**/
class Main {
	static function main() {
		Warn.start();
		W.later();
		var held = Warn.later;
	}
}
