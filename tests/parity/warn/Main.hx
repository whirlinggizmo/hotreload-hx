import Warn as W;

/**
	the warning test's main class: builds, never runs. A method it passes as a value is as
	stuck as one your code passes, and said so too; a call through an alias is just a
	call, and said nothing about
**/
class Main {
	static function main() {
		Warn.start();
		W.later();
		var held = Warn.later;
	}
}
