package hotreload;

#if (js && hotreload)
import js.Syntax;

/**
	Making a newly loaded bundle's classes the current ones, in place of the running
	bundle's. Each bundle registers its classes and enums as it loads (Reloader's
	__init__); the first one asks the DevServer, a few times a second, for a newer one,
	and loads it with `import()` beside itself. Then, between two frames:

	1. the old code's `@:beforeHotReload` hooks, and the main class's `beforeReload`;
	2. the statics' values move to the new classes: a class
	   of the project's (the build lists them, and their `@:hot` statics: a resource, each
	   bundle its own) has only its `@:hot` statics carried over, and the rest keep the
	   value the new bundle gave them, their first; any other class (the main class, the
	   standard library, a haxelib) has every one carried over. A new static keeps its first value, and one whose type
	   the new code changed (the build records each class's statics' types,
	   `__hot_types__`) is carried over when it's still the same kind of value
	   (sameKind), and keeps its first value when not. (A static the new code doesn't
	   have is carried anyway, unused: Haxe doesn't emit a static with no first value, so a
	   class's JS can't tell one that's gone from one that's never been set.) A function
	   that's a method of the old code (`onFrame = Guest.frame`) becomes the new code's;
	3. the objects the statics hold are carried over, walking arrays, maps and plain
	   objects: an object of an old class is given the new class's prototype, in place
	   (the same object, so every reference to it is still good), and its new fields
	   their initializers. An enum value is made again from the new enum, by its
	   constructor's name;
	4. the old classes forward to the new ones: their statics read and write the new
	   classes', and their methods are the new code's. The first bundle's classes are
	   re-pointed on every swap too, since the main class, and anything else from before
	   the first reload, calls through them: a copied method would stay the second
	   bundle's. So old code still around (a callback, an object nothing walked to) runs
	   the new code, on the same state.
	   A bound method made before the reload (`addEventListener(CLICK, onClick)`) runs the
	   new code too: a hot build's `$bind` looks its method up as it's called, and each
	   old method leads to its new one. What it can't reach: a closure made before the
	   reload runs the code it came from;
	5. the new code's `@:afterHotReload` hooks, and the main class's `afterReload`.

	hotreload's own classes are left out: each bundle keeps its own.
**/
@:keep
class JsSwap {
	public static var reloaders:Array<Reloader> = [];

	/** a bundle, as it loads: its classes and enums. Whether it's a reload's **/
	public static function register(self:Dynamic):Bool {
		var state:Dynamic = Syntax.code("globalThis.__hotreload || (globalThis.__hotreload = {bundles: [], version: {0}})", builtVersion());
		var bundle = {
			classes: Syntax.code("$hxClasses"),
			enums: Syntax.code("(typeof $hxEnums != 'undefined' ? $hxEnums : {})"),
			// the project's classes, by name, and their `@:hot` statics (Builder): read when
			// a swap asks, by the bundle's own code, since this runs before its statics are
			// made (haxe.Resource's decoder's among them)
			hot: () -> {
				var hot = haxe.Resource.getString("hotreload.statics");
				return hot == null ? {} : haxe.Json.parse(hot);
			},
			self: self,
		};
		var bundles:Array<Dynamic> = state.bundles;
		bundles.push(bundle);
		if (bundles.length > 1)
			return true;
		Syntax.code("setTimeout({0}, 0)", poll);
		Syntax.code("setTimeout({0}, 0)", pollAssets);
		return false;
	}

	/**
		This bundle's build: the DevServer numbers them, from 0, and stamps each one's first
		line with its number (on the line Haxe's comment is on, so no line moves)
	**/
	static function builtVersion():Int {
		var v:Null<Int> = Syntax.code("globalThis.__hotreload_built");
		return v == null ? 0 : v;
	}

	/** where to ask for a newer bundle, and how to load one: a page asks where it came from **/
	static function inBrowser():Bool
		return Syntax.code("typeof document != 'undefined'");

	static function statusUrl():String {
		#if hotreload_url
		return haxe.macro.Compiler.getDefine("hotreload_url");
		#else
		if (inBrowser())
			return "/__hotreload";
		var env:String = Syntax.code("(typeof process != 'undefined' && process.env.HOTRELOAD_URL) || null");
		return env != null ? env : "http://localhost:8080/__hotreload";
		#end
	}

	static var busy = false;

	/**
		Asks the DevServer for a build newer than the running one, and it answers when
		there is one (a long poll): so a reload starts as soon as the build is done
	**/
	static function poll() {
		var state:Dynamic = Syntax.code("globalThis.__hotreload");
		function ask() {
			if (busy)
				return;
			busy = true;
			Syntax.code("fetch({0} + '?since=' + {1}, {cache: 'no-store'}).then(r => r.json())", statusUrl(), state.version).then((info:Dynamic) -> {
				if (info.version <= state.version) {
					busy = false;
					Syntax.code("setTimeout({0}, 0)", ask);
					return;
				}
				state.version = info.version;
				var bundles:Array<Dynamic> = state.bundles;
				var before = bundles.length;
				load(info).then(_ -> {
					if (bundles.length > before)
						swap(bundles[bundles.length - 2], bundles[bundles.length - 1]);
					busy = false;
					Syntax.code("setTimeout({0}, 0)", ask);
				}, (e:Dynamic) -> {
					log('reload: cannot load ${info.url} ($e)');
					busy = false;
					Syntax.code("setTimeout({0}, 0)", ask);
				});
			}, (_:Dynamic) -> {
				// no DevServer (yet, or any more): ask again in a while
				busy = false;
				Syntax.code("setTimeout({0}, 1000)", ask);
			});
		}
		ask();
	}

	/**
		Asks the DevServer which served files changed (a long poll of its own, so an asset
		never loads a bundle) and tells the reloaders. The first answer is only where to
		start from: what changed before the program started, it loaded already
	**/
	static function pollAssets() {
		var known = -1;
		function ask() {
			Syntax.code("fetch({0} + '_assets?since=' + {1}, {cache: 'no-store'}).then(r => r.json())", statusUrl(), known).then((info:Dynamic) -> {
				var urls:Array<String> = info.urls;
				var first = known < 0;
				known = info.version;
				if (!first && urls.length > 0)
					for (r in reloaders)
						if (r.assetsChanged != null)
							try
								r.assetsChanged(urls)
							catch (e:Dynamic)
								log('assets: assetsChanged failed ($e)');
				Syntax.code("setTimeout({0}, 0)", ask);
			}, (_:Dynamic) -> Syntax.code("setTimeout({0}, 1000)", ask));
		}
		ask();
	}

	/**
		Runs the new bundle beside this one. A page imports it, under a new URL each time. In
		node, whose module cache ignores a URL's query for a CommonJS file (a plain .js), it's
		read and run as a script
	**/
	static function load(info:Dynamic):Dynamic {
		if (inBrowser())
			return Syntax.code("import({0})", info.url + "?v=" + info.version);
		return Syntax.code("new Promise(resolve => { const fs = process.getBuiltinModule('fs'); (0, eval)(fs.readFileSync({0}, 'utf8') + '\\n//# sourceURL=' + {0} + '?v=' + {1}); resolve(null); })", info.file, info.version);
	}

	static function log(message:String)
		Syntax.code("console.log({0})", "hotreload: " + message);

	/** the bundle `neu`'s classes, in place of `old`'s (see the class's doc) **/
	static function swap(old:Dynamic, neu:Dynamic) {
		var start = haxe.Timer.stamp();
		var oldHooks:Dynamic = Reflect.field(old.classes, "hotreload.Hooks");
		if (oldHooks != null)
			oldHooks.runBefore();
		for (r in reloaders)
			if (r.beforeReload != null)
				r.beforeReload();

		// the classes both bundles have, and their methods: old -> new. The first bundle's
		// too, when it isn't the old one: the main class, and whatever else holds on to
		// the first bundle's classes, calls through them, so they forward to the new code
		// straight away, not through the bundles in between (which are let go)
		var state:Dynamic = Syntax.code("globalThis.__hotreload");
		var first:Dynamic = state.bundles[0];
		var pairs:Array<{name:String, o:Dynamic, n:Dynamic, carry:Bool}> = [];
		var protos:Dynamic = Syntax.code("new Map()");
		var classes:Dynamic = Syntax.code("new Map()");
		var functions:Dynamic = Syntax.code("new Map()");
		for (name in Reflect.fields(neu.classes))
			for (from in (first == old || first == neu ? [old] : [old, first])) {
				var o:Dynamic = Reflect.field(from.classes, name);
				var n:Dynamic = Reflect.field(neu.classes, name);
				if (o == null || o == n || StringTools.startsWith(name, "hotreload."))
					continue;
				pairs.push({name: name, o: o, n: n, carry: from == old});
				classes.set(o, n);
				if (o.prototype != null && n.prototype != null)
					protos.set(o.prototype, n.prototype);
				for (key in methods(o))
					if (Syntax.code("typeof {0}[{1}] == 'function'", n, key))
						functions.set(Reflect.field(o, key), Reflect.field(n, key));
				if (o.prototype != null && n.prototype != null)
					for (key in methods(o.prototype))
						if (key != "constructor" && Syntax.code("typeof {0}[{1}] == 'function'", n.prototype, key))
							functions.set(Reflect.field(o.prototype, key), Reflect.field(n.prototype, key));
			}

		// a bound method made before the reload (a hot build's `$bind`: Builder.lateBind)
		// follows each old method to the new one; and the new one takes the old one's id, so
		// binding it again finds the same function: removeEventListener(CLICK, onClick)
		// removes the listener added before the reload
		Syntax.code("for (const [o, n] of {0}) { o.__hot_next__ = n; if (o.__id__ != null && n.__id__ == null) n.__id__ = o.__id__; }", functions);

		// the statics' values, and what they hold
		var walker = new Walker(protos, classes, functions, old.enums, neu.enums);
		var moved = 0;
		var fresh = 0;
		var newHot:Dynamic = neu.hot();
		var oldHot:Dynamic = old.hot();
		for (p in pairs) {
			if (!p.carry)
				continue; // the first bundle's statics already read the old one's
			// a project class's `@:hot` statics, if it is one (and was): null for every static
			var hot:Array<String> = Reflect.field(newHot, p.name);
			var wasHot:Array<String> = Reflect.field(oldHot, p.name);
			var oldTypes:Dynamic = Reflect.field(p.o, "__hot_types__");
			var newTypes:Dynamic = Reflect.field(p.n, "__hot_types__");
			for (key in statics(p.o))
				if (!isMethod(p.n, key)) {
					if (hot != null && (!hot.contains(key) || (wasHot != null && !wasHot.contains(key)))) {
						// a plain static of the project's: the new code's first value. One
						// with none isn't emitted (Haxe leaves a null first value out too): null, not undefined
						if (!Syntax.code("Object.prototype.hasOwnProperty.call({0}, {1})", p.n, key))
							Reflect.setField(p.n, key, null);
						fresh++;
						continue;
					}
					var value:Dynamic = Reflect.field(p.o, key);
					var was:String = oldTypes == null ? null : Reflect.field(oldTypes, key);
					var now:String = newTypes == null ? null : Reflect.field(newTypes, key);
					if (was != null && now != null && was != now) {
						// the new code declares another type: what still fits is carried over
						if (sameKind(value, Reflect.field(p.n, key))) {
							log('static: ${p.name}.$key carried over (type changed: $was to $now)');
						} else {
							log('static: ${p.name}.$key started over (type changed: $was to $now)');
							fresh++;
							continue;
						}
					}
					Reflect.setField(p.n, key, walker.visit(value));
					moved++;
				}
		}
		walker.finish();

		// the old classes forward to the new ones
		for (p in pairs) {
			var n = p.n;
			for (key in statics(p.o))
				if (!isMethod(n, key))
					Syntax.code("Object.defineProperty({0}, {1}, {get: () => {2}[{1}], set: (v) => { {2}[{1}] = v; }, configurable: true, enumerable: true})",
						p.o, key, n);
			for (key in methods(p.o))
				if (Syntax.code("typeof {0}[{1}] == 'function'", n, key))
					Syntax.code("Object.defineProperty({0}, {1}, {value: {2}[{1}], writable: true, configurable: true})", p.o, key, n);
			if (p.o.prototype != null && n.prototype != null)
				for (key in methods(p.o.prototype))
					if (key != "constructor" && Syntax.code("typeof {0}[{1}] == 'function'", n.prototype, key))
						Syntax.code("Object.defineProperty({0}, {1}, {value: {2}[{1}], writable: true, configurable: true})", p.o.prototype, key,
							n.prototype);
		}

		// only the current bundle is kept: the old one's code goes once nothing uses it
		state.bundles = first == neu ? [neu] : [first, neu];

		var newHooks:Dynamic = Reflect.field(neu.classes, "hotreload.Hooks");
		if (newHooks != null)
			newHooks.runAfter();
		for (r in reloaders)
			if (r.afterReload != null)
				r.afterReload();
		log('reload: done (${[for (p in pairs) if (p.carry) p].length} classes, $moved statics kept, $fresh started over, ${walker.objects} objects, '
			+ '${Math.round((haxe.Timer.stamp() - start) * 1000)} ms)');
	}

	/**
		Whether a value of one type can be carried to another: the same kind of value, or one
		to a type with no first value (null). The rule for a `@:hot` static whose type changed
	**/
	static function sameKind(old:Dynamic, fresh:Dynamic):Bool {
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

	/** a class's (or prototype's) own methods: its functions that aren't enumerable **/
	static function methods(o:Dynamic):Array<String>
		return Syntax.code("Object.getOwnPropertyNames({0}).filter(k => { const d = Object.getOwnPropertyDescriptor({0}, k); return d && !d.enumerable && typeof d.value == 'function' && k != 'length' && k != 'name' && k != 'prototype' && !k.startsWith('__'); })", o);

	/** a class's statics: its own enumerable properties, but Haxe's own (`__name__`) **/
	static function statics(o:Dynamic):Array<String>
		return Syntax.code("Object.keys({0}).filter(k => !k.startsWith('__'))", o);

	/** whether a class has a method by that name (and so no static) **/
	static function isMethod(o:Dynamic, key:String):Bool
		return Syntax.code("(() => { const d = Object.getOwnPropertyDescriptor({0}, {1}); return d != null && !d.enumerable && typeof d.value == 'function'; })()", o, key);
}

/** carrying the statics' values over: objects re-prototyped in place, enums made again, methods re-pointed **/
private class Walker {
	var protos:Dynamic;
	var classes:Dynamic;
	var functions:Dynamic;
	var oldEnums:Dynamic;
	var newEnums:Dynamic;
	var seen:Dynamic = Syntax.code("new Map()");
	var pending:Array<Dynamic> = [];
	var knownProtos:Dynamic = Syntax.code("new Set()");

	public var objects = 0;

	public function new(protos, classes, functions, oldEnums, newEnums) {
		this.protos = protos;
		this.classes = classes;
		this.functions = functions;
		this.oldEnums = oldEnums;
		this.newEnums = newEnums;
		Syntax.code("for (const [o, n] of {0}) { {1}.add(o); {1}.add(n); }", protos, knownProtos);
	}

	public function visit(v:Dynamic):Dynamic {
		var type:String = Syntax.code("typeof {0}", v);
		if (v == null || (type != "object" && type != "function"))
			return v;
		if (type == "function") {
			if (classes.has(v))
				return classes.get(v);
			if (functions.has(v))
				return functions.get(v);
			return v; // a closure: the code it came from
		}
		if (seen.has(v))
			return seen.get(v);
		if (Syntax.code("typeof {0}.__enum__ == 'string' && typeof {0}._hx_index == 'number'", v))
			return enumValue(v);
		if (!walkable(v)) {
			seen.set(v, v);
			return v;
		}
		seen.set(v, v);
		var proto:Dynamic = Syntax.code("Object.getPrototypeOf({0})", v);
		if (protos.has(proto)) {
			var next:Dynamic = protos.get(proto);
			Syntax.code("Object.setPrototypeOf({0}, {1})", v, next);
			objects++;
			// its new fields, from their initializers: each class's, from the top down
			Syntax.code("for (let p = {1}; p && p !== Object.prototype; p = Object.getPrototypeOf(p)) for (const k of Object.getOwnPropertyNames(p)) if (k.startsWith('__hot_init_') && typeof p[k] == 'function') p[k].call({0})", v, next);
		}
		pending.push(v);
		return v;
	}

	/** walks what the objects visited hold, a queue rather than recursion **/
	public function finish() {
		while (pending.length > 0) {
			var v:Dynamic = pending.pop();
			if (Syntax.code("Array.isArray({0})", v)) {
				var a:Array<Dynamic> = v;
				for (i in 0...a.length)
					a[i] = visit(a[i]);
			} else if (Syntax.code("{0} instanceof Map", v)) {
				Syntax.code("for (const [k, x] of Array.from({0})) {0}.set(k, {1}(x))", v, visit);
			} else {
				var keys:Array<String> = Syntax.code("Object.keys({0})", v);
				for (k in keys) {
					if (k == "hx__closures__")
						continue;
					var x:Dynamic = Syntax.code("{0}[{1}]", v, k);
					var y:Dynamic = visit(x);
					if (y != x)
						Syntax.code("{0}[{1}] = {2}", v, k, y);
				}
			}
		}
	}

	/** what's worth walking into: arrays, maps, plain objects, and Haxe classes' objects; not the page's, nor the engine's buffers **/
	function walkable(v:Dynamic):Bool {
		if (Syntax.code("Array.isArray({0}) || {0} instanceof Map", v))
			return true;
		if (Syntax.code("ArrayBuffer.isView({0}) || {0} instanceof ArrayBuffer || {0} === globalThis", v))
			return false;
		var proto:Dynamic = Syntax.code("Object.getPrototypeOf({0})", v);
		if (proto == null || proto == Syntax.code("Object.prototype"))
			return true;
		var p = proto;
		while (p != null) {
			if (knownProtos.has(p))
				return true;
			p = Syntax.code("Object.getPrototypeOf({0})", p);
		}
		return false;
	}

	/** an enum value, made again from the new enum by its constructor's name **/
	function enumValue(v:Dynamic):Dynamic {
		var name:String = v.__enum__;
		var oldEnum:Dynamic = Reflect.field(oldEnums, name);
		var newEnum:Dynamic = Reflect.field(newEnums, name);
		if (oldEnum == null || newEnum == null || oldEnum == newEnum) {
			seen.set(v, v);
			return v;
		}
		var constructs:Array<Dynamic> = oldEnum.__constructs__;
		var ctor:String = constructs[v._hx_index]._hx_name;
		var made:Dynamic = Reflect.field(newEnum, ctor);
		if (made == null) {
			Syntax.code("console.log({0})", 'hotreload: enum: $name.$ctor removed from the new code (old value kept)');
			seen.set(v, v);
			return v;
		}
		var result:Dynamic = made;
		if (Syntax.code("typeof {0} == 'function'", made)) {
			var params:Array<String> = made.__params__;
			result = Syntax.code("{0}.apply(null, {1})", made, [for (p in params) visit(Reflect.field(v, p))]);
		}
		seen.set(v, result);
		// a new value, if it's met again, is already the new enum's: never made again from it
		seen.set(result, result);
		return result;
	}
}
#end
