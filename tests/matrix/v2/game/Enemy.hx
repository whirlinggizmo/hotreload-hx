package game;

class Enemy {
	public var health:Int; // S4: renamed from hp
	public var speed:Float = 3; // S5: Int -> Float
	public var shield = 10; // S3: new, with an initializer
	public var buddy:Enemy;

	public function new(hp:Int) {
		this.health = hp;
	}

	public function describe() {
		return 'v2 health$health shield$shield speed$speed';
	}
}
