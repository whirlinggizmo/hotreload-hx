package hotreload;

import haxe.ds.IntMap;
import haxe.ds.ObjectMap;
import haxe.ds.StringMap;

/**
	Carrying the `@:hot` statics' values over to a new module. An object keeps the class
	it was made with, and its methods with it, so each reload copies the reloaded classes'
	objects into the new module's classes: field by field, by name, where the field is
	still there and holds the same kind of value (a number, a bool, anything else). A new
	field starts from its initializer, as it would in a new object, or else from its
	type's default (0, false, null).

	The objects are copied as a graph: each once, however many references there are to
	it, so what was shared is shared in the copy, and a cycle stays a cycle. Arrays, maps
	and anonymous structures are walked and updated in place, so references to them from
	elsewhere stay good. An enum value of a reloaded enum is made again from the new enum,
	by its constructor's name. The executable's own classes' objects are left as they are,
	and not walked into.
**/
class Migrate {
	var resolve:String->Class<Dynamic>;
	var copies = new ObjectMap<Dynamic, Dynamic>();
	var pending = new Array<() -> Void>();
	var classes = new Map<String, Class<Dynamic>>();

	/** carries the slots over to the module whose classes `resolve` finds by name **/
	public static function run(resolve:String->Class<Dynamic>) {
		var m = new Migrate(resolve);
		for (slot in Slots.all())
			slot.value = m.carry(slot.value);
		while (m.pending.length > 0)
			m.pending.pop()();
	}

	/** whether a value of one type can be carried to another: the same kind of value, or one to a type with no first value (null) **/
	public static function sameKind(old:Dynamic, fresh:Dynamic):Bool {
		var o = kind(old), f = kind(fresh);
		if (f == "null")
			return o == "null" || o == "object" || o == "string";
		return o == f || o == "null";
	}

	static function kind(v:Dynamic):String {
		return switch (Type.typeof(v)) {
			case TNull: "null";
			case TInt | TFloat: "number";
			case TBool: "bool";
			case TFunction: "function";
			case TClass(c) if (c == String): "string";
			default: "object";
		}
	}

	function new(resolve) {
		this.resolve = resolve;
	}

	/** the new module's class for a class's objects, or null when it's the executable's own **/
	function newClass(name:String):Class<Dynamic> {
		if (StringTools.startsWith(name, Builder.HOST_PREFIX))
			name = name.substr(Builder.HOST_PREFIX.length);
		if (classes.exists(name))
			return classes.get(name);
		var c = resolve(name);
		classes.set(name, c);
		return c;
	}

	function carry(v:Dynamic):Dynamic {
		if (v == null)
			return null;
		switch (Type.typeof(v)) {
			case TObject:
				if (Std.isOfType(v, Class) || Std.isOfType(v, Enum) || copies.exists(v))
					return v;
				copies.set(v, v);
				pending.push(() -> {
					for (f in Reflect.fields(v))
						Reflect.setField(v, f, carry(Reflect.field(v, f)));
				});
				return v;
			case TClass(c):
				if (c == String)
					return v;
				if (copies.exists(v))
					return copies.get(v);
				if (c == Array) {
					copies.set(v, v);
					var a:Array<Dynamic> = v;
					pending.push(() -> for (i in 0...a.length) a[i] = carry(a[i]));
					return v;
				}
				if (c == StringMap || c == IntMap) {
					copies.set(v, v);
					var map:haxe.Constraints.IMap<Dynamic, Dynamic> = v;
					pending.push(() -> for (k in map.keys()) map.set(k, carry(map.get(k))));
					return v;
				}
				if (c == ObjectMap) {
					copies.set(v, v);
					var map:ObjectMap<Dynamic, Dynamic> = v;
					pending.push(() -> {
						var pairs = [for (k in map.keys()) {k: k, v: map.get(k)}];
						map.clear();
						for (p in pairs)
							map.set(carry(p.k), carry(p.v));
					});
					return v;
				}
				var nc = newClass(Type.getClassName(c));
				if (nc == null || nc == c)
					return v;
				var o = Type.createEmptyInstance(nc);
				copies.set(v, o);
				pending.push(() -> fill(v, o, nc));
				return o;
			case TEnum(e):
				var ne:Enum<Dynamic> = cast newClass(Type.getEnumName(e));
				if (ne == null || ne == cast e)
					return v;
				var params = [for (p in Type.enumParameters(v)) carry(p)];
				try {
					return Type.createEnum(ne, Type.enumConstructor(v), params);
				} catch (_) {
					Sys.println('hotreload: ${Type.getEnumName(e)}.${Type.enumConstructor(v)} is gone from the new code; kept the old value');
					return v;
				}
			default:
				return v;
		}
	}

	/** a new object's fields from an old one's: those it still has, of the same kind; then its initializers for the rest **/
	function fill(old:Dynamic, o:Dynamic, nc:Class<Dynamic>) {
		var had = Reflect.fields(old);
		var copied = [];
		for (f in Reflect.fields(o)) {
			if (!had.contains(f))
				continue;
			var value = Reflect.field(old, f);
			if (!fits(value, Reflect.field(o, f)))
				continue;
			Reflect.setField(o, f, carry(value));
			copied.push(f);
		}
		var c = nc;
		while (c != null) {
			var init = Reflect.field(o, initializerName(Type.getClassName(c)));
			if (init != null)
				Reflect.callMethod(o, init, [copied]);
			c = Type.getSuperClass(c);
		}
	}

	/** whether an old field's value fits the new field, by the new one's default: a number for a number, a bool for a bool, and anything else for null **/
	static function fits(value:Dynamic, def:Dynamic):Bool {
		var v = kind(value), d = kind(def);
		if (v == "null")
			return true;
		if (d == "null")
			return v != "number" && v != "bool";
		return v == d;
	}

	public static function initializerName(className:String):String {
		return "__hot_init_" + StringTools.replace(className, ".", "_");
	}
}
