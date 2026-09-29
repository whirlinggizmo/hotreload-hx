package game;

class Enemy {
	public var hp:Int;
	public var buddy:Enemy;
	public var shield = 10; // new: a carried-over enemy starts at 10

	public function new(hp:Int) {
		this.hp = hp;
	}

	public function describe() {
		return 'hp$hp/s$shield';
	}
}
