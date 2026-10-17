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

	/**
		Whether a value of one type can be carried to another: the same kind of value, or one
		to a type with no first value (null). Both targets' rule for a `@:hot` static whose
		type changed (Slots natively, JsSwap on JS)
	**/
	public static function sameKind(old:Dynamic, fresh:Dynamic):Bool {
		var o = kind(old), f = kind(fresh);
		if (f == "null")
			return o == "null" || o == "object" || o == "string";
		return o == f || o == "null";
	}

	public static function kind(v:Dynamic):String {
		return switch (Type.typeof(v)) {
			case TNull: "null";
			case TInt | TFloat: "number";
			case TBool: "bool";
			case TFunction: "function";
			case TClass(c) if (c == String): "string";
			default: "object";
		}
	}
}
