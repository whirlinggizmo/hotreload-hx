class Game {
	static var dispatcher:Dispatcher;
	static var button:Button;

	/** a DOM event target: its listeners are its own, where a reload's walk doesn't reach **/
	static var target:Dynamic;

	public static function start() {
		dispatcher = new Dispatcher();
		button = new Button();
		target = js.Syntax.code("new EventTarget()");
		dispatcher.add(button.onClick);
		target.addEventListener("tick", Button.onTick);
		dispatcher.dispatch();
		tick();
	}

	static function tick()
		target.dispatchEvent(js.Syntax.code("new Event('tick')"));

	/**
		the bound method and the static function added before the reload: the new code's,
		and removed by the new code (a second tick says nothing). Then added again, for the
		next reload, by this code
	**/
	public static function reloaded() {
		dispatcher.dispatch();
		tick();
		var removed = dispatcher.remove(button.onClick);
		target.removeEventListener("tick", Button.onTick);
		tick();
		Main.say('removed=$removed listeners=${dispatcher.count()}');
		dispatcher.add(button.onClick);
		target.addEventListener("tick", Button.onTick);
	}
}
