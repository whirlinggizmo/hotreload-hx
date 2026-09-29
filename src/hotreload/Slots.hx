package hotreload;

/**
	The `@:hot` statics' slots, by class and name (`Hello.ticks`). A class's static
	initializer asks for its slots (as `@:hot` makes it): the first time a slot is made,
	with the first value; each time after, it's the one there already, but when the new
	code declares another type, what it holds is carried over when it's the same kind of
	value (a number, a string, an object), and started over from the first value when not
**/
@:keep
class Slots {
	static var slots = new Map<String, Slot>();
	static var order = new Array<String>();

	public static function get(key:String, sig:String, first:() -> Dynamic):Slot {
		var slot = slots.get(key);
		if (slot == null) {
			slot = new Slot(first(), sig);
			slots.set(key, slot);
			order.push(key);
			return slot;
		}
		if (slot.sig != sig) {
			var fresh = first();
			if (Migrate.sameKind(slot.value, fresh)) {
				Sys.println('hotreload: $key\'s type changed (${slot.sig} to $sig); carried over what still fits');
			} else {
				Sys.println('hotreload: $key\'s type changed (${slot.sig} to $sig); started over from its first value');
				slot.value = fresh;
			}
			slot.sig = sig;
		}
		return slot;
	}

	/** every slot, in the order they were made **/
	public static function all():Array<Slot> {
		return [for (key in order) slots.get(key)];
	}

	/** the slots' keys **/
	public static function keys():Array<String> {
		return order.copy();
	}
}
