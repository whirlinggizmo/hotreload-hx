class Game {
	static var dispatcher:Dispatcher;
	static var button:Button;

	public static function start() {
		dispatcher = new Dispatcher();
		button = new Button();
		dispatcher.add(button.onClick);
		dispatcher.dispatch();
	}

	/**
		the bound method added before the reload: the new code's, and removed by the new code.
		Then added again, for the next reload, by this code
	**/
	public static function reloaded() {
		dispatcher.dispatch();
		var removed = dispatcher.remove(button.onClick);
		Main.say('removed=$removed listeners=${dispatcher.count()}');
		dispatcher.add(button.onClick);
	}
}
