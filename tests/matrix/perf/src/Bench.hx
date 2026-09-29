class P {
	public var x:Float;
	public var vx:Float;

	public function new(i:Int) {
		x = i;
		vx = (i % 7) + 0.5;
	}
}

class Bench {
	@:hot static var dummy = 0;

	@:hot public static function run(what:String):Void {
		var t = haxe.Timer.stamp();
		var acc = 0.0, k = 0;
		for (i in 0...20000000) {
			k = (k * 31 + i) & 0xffff;
			acc += Math.sqrt(k) * 0.5;
		}
		var math = haxe.Timer.stamp() - t;
		t = haxe.Timer.stamp();
		var ps = [for (i in 0...1000) new P(i)];
		for (f in 0...5000)
			for (p in ps) {
				p.x += p.vx;
				if (p.x > 1000 || p.x < 0)
					p.vx = -p.vx;
			}
		var objects = haxe.Timer.stamp() - t;
		Sys.println('bench $what: math ${Math.round(math * 1000)} ms, objects ${Math.round(objects * 1000)} ms (${Math.round(acc) % 10}${Math.round(ps[0].x) % 10})');
	}
}
