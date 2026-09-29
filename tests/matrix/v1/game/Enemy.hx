package game;

class Enemy {
	public var hp:Int;
	public var speed:Int = 3;
	public var buddy:Enemy;

	public function new(hp:Int) {
		this.hp = hp;
	}

	public function describe() {
		return 'v1 hp$hp';
	}
}
