/** a method passed as a value, which a reload can't re-point: warned about; a lambda calling it, not **/
class Warn {
	@:hot static var pending:Array<Int->Void> = [];

	public static function start() {
		var w = new Warn();
		load(x -> w.place(x));
		load(x -> placeAll(x));
		load(function(x) {
			placeAll(x);
		});
		w.place(1);
		placeAll(1);
		load(w.place);
		load(placeAll);
	}

	static function load(done:Int->Void) {
		pending.push(done);
	}

	static function placeAll(x:Int) {}

	public static function later() {}

	function new() {}

	function place(x:Int) {}
}
