package hotreload;

/**
	A `@:hot` static's storage, which the executable keeps: the same one is handed to the
	executable's copy of its class and to every module that loads, so old code still
	around after a reload (a callback from before it) reads and writes the same value
**/
@:keep
class Slot {
	public var value:Dynamic;

	/** its type, as its class declared it: a module with another type has its value carried over, or started over **/
	public var sig:String;

	public function new(value:Dynamic, sig:String) {
		this.value = value;
		this.sig = sig;
	}
}
