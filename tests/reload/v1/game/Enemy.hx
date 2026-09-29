package game;

class Enemy {
	public var hp:Int;
	public var buddy:Enemy;

	public function new(hp:Int) {
		this.hp = hp;
	}

	public function describe() {
		return 'hp$hp';
	}
}
