import Warn as W;

/**
	the warning test's main class: builds, never runs. A method it passes as a value, and a
	call through an alias, are said nothing about
**/
class Main {
	static function main() {
		Warn.start();
		W.later();
		var held = Warn.later;
	}
}
