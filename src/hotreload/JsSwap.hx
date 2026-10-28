package hotreload;

#if (js && hotreload)
import js.Syntax;

/**
	Provides the swap that makes a newly loaded bundle's classes the current ones.

	Each bundle registers its classes and enums as it loads (Reloader's `__init__`). The first
	bundle asks the DevServer for a newer one, a few times a second. It loads a newer bundle with
	`import()` beside itself. The swap then runs between two frames:

	1. The old code's `@:beforeHotReload` hooks run, then the main class's `beforeReload`.
	2. The statics' values move to the new classes, for every class alike. The build records
	   each class's statics' types and first values as written (`__hot_statics__`). A static
	   whose first value was edited keeps the new one. So does one marked `@:resetOnHotReload`.
	   A static whose type changed is carried over when it is still the same kind of value
	   (sameKind). Otherwise it keeps its first value. The rest are carried over. A new static
	   keeps its first value. A static the new code does not have is carried anyway, unused.
	   Haxe does not emit a static with no first value, so a class's JS cannot tell a removed
	   static from one never set. A function that is a method of the old code
	   (`onFrame = Guest.frame`) becomes the new code's.
	3. The objects the statics hold are carried over. The walk covers arrays, maps and plain
	   objects. An object of an old class receives the new class's prototype, in place. It
	   stays the same object, so every reference to it stays valid. Its new fields receive
	   their initializers. An enum value is made again from the new enum, by its constructor's
	   name. A constant with no arguments is already the new enum's, the same object. The new
	   bundle took the running bundle's constants as it loaded (adoptEnums).
	4. The old classes forward to the new ones. Their statics read and write the new classes'
	   statics. Their methods are the new code's. The first bundle's classes are re-pointed on
	   every swap too. The main class, and anything else from before the first reload, calls
	   through them, and a copied method would stay the second bundle's. Old code still around
	   (a callback, an object the walk did not reach) runs the new code, on the same state.
	   A bound method made before the reload (`addEventListener(CLICK, onClick)`) runs the new
	   code too. A hot build's `$bind` looks its method up on each call, and each old method
	   leads to its new one. A static function passed as a value
	   (`addEventListener("keydown", Game.onKey)`) also runs the new code. The build makes each
	   one a function that calls it. A swap keeps that function, as the new class's, and points
	   it to the new code. A closure made before the reload is not reached. It runs the code it
	   came from.
	5. The new code's `@:afterHotReload` hooks run, then the main class's `afterReload`.

	hotreload's own classes are excluded. Each bundle keeps its own.
**/
@:keep
class JsSwap {
	public static var reloaders:Array<Reloader> = [];

	/**
		Registers a bundle's classes and enums as it loads.

		@return  True if the bundle is a reload's, false for the first bundle.
	**/
	public static function register(self:Dynamic):Bool {
		var state:Dynamic = Syntax.code("globalThis.__hotreload || (globalThis.__hotreload = {bundles: [], version: {0}})", builtVersion());
		var bundle = {
			classes: Syntax.code("$hxClasses"),
			enums: Syntax.code("(typeof $hxEnums != 'undefined' ? $hxEnums : {})"),
			self: self,
			adopted: new Array<{value:Dynamic, index:Int}>(),
		};
		var bundles:Array<Dynamic> = state.bundles;
		bundles.push(bundle);
		if (bundles.length > 1) {
			adoptEnums(bundles[bundles.length - 2].enums, bundle.enums, bundle.adopted);
			return true;
		}
		Syntax.code("setTimeout({0}, 0)", poll);
		Syntax.code("setTimeout({0}, 0)", pollAssets);
		return false;
	}

	/**
		Gives a newly loaded bundle the running bundle's enum constants that take no arguments.

		Runs before the new bundle's code. Each constant (`Sad`) keeps its object and receives
		its index in the new code. A value the reload does not reach, such as one a closure
		holds, still matches its case and equals the new code's constant. A value with
		arguments is a new object each time it is made, so it cannot be kept. A message
		reports a constructor with arguments whose index changed.

		@param old  The running bundle's enums, by name.
		@param neu  The new bundle's enums, by name.
		@param adopted  Receives each constant taken, with its index before, for a failed load to restore.
	**/
	static function adoptEnums(old:Dynamic, neu:Dynamic, adopted:Array<{value:Dynamic, index:Int}>) {
		for (name in Reflect.fields(neu)) {
			var o:Dynamic = Reflect.field(old, name);
			var n:Dynamic = Reflect.field(neu, name);
			if (o == null || o == n || o.__constructs__ == null || n.__constructs__ == null)
				continue;
			var was:Array<Dynamic> = o.__constructs__;
			var now:Array<Dynamic> = n.__constructs__;
			for (i in 0...now.length) {
				var ctor:String = now[i]._hx_name;
				var value:Dynamic = Reflect.field(o, ctor);
				if (value == null)
					continue;
				var made = Syntax.code("typeof {0} == 'function'", now[i]);
				if (made != Syntax.code("typeof {0} == 'function'", value))
					continue;
				if (!made) {
					adopted.push({value: value, index: value._hx_index});
					value._hx_index = i;
					Reflect.setField(n, ctor, value);
					now[i] = value;
				} else if (was.indexOf(value) != i)
					log('enum: $name.$ctor moved (index ${was.indexOf(value)} to $i, unreached values match another case)');
			}
		}
	}

	/**
		Returns this bundle's build number.

		The DevServer numbers builds from 0. It stamps each build's first line with its number,
		on the line that holds Haxe's comment, so no line moves.
	**/
	static function builtVersion():Int {
		var v:Null<Int> = Syntax.code("globalThis.__hotreload_built");
		return v == null ? 0 : v;
	}

	/**
		Returns whether the code runs in a page or in a web worker.

		The answer decides where to ask for a newer bundle and how to load one. A page or a
		worker asks the server it came from, and imports the bundle. A worker started from the
		hot bundle (`new Worker("main.js")`) reloads with the page, each on its own.
	**/
	static function inBrowser():Bool
		return Syntax.code("typeof document != 'undefined' || (typeof WorkerGlobalScope != 'undefined' && self instanceof WorkerGlobalScope)");

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
		Asks the DevServer for a build newer than the running one.

		The DevServer answers when there is one (a long poll), so a reload starts as soon as the
		build is done.
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
					// A swap that throws partway leaves some classes swapped. Polling goes on,
					// so the next build swaps in from where this one stopped.
					if (bundles.length > before)
						try {
							swap(bundles[bundles.length - 2], bundles[bundles.length - 1]);
						} catch (e:Dynamic) {
							log('reload: failed (${Std.string(e)}); save again to retry');
						}
					busy = false;
					Syntax.code("setTimeout({0}, 0)", ask);
				}, (e:Dynamic) -> {
					// A bundle that registered and then failed (a static initializer threw) is
					// dropped, and the enum constants it took get their indices back.
					if (bundles.length > before) {
						var failed:Dynamic = bundles.pop();
						for (a in (failed.adopted:Array<{value:Dynamic, index:Int}>))
							a.value._hx_index = a.index;
					}
					log('reload: cannot load ${info.url} ($e)');
					busy = false;
					Syntax.code("setTimeout({0}, 0)", ask);
				});
			}, (_:Dynamic) -> {
				// No DevServer yet, or none any more. Asks again in a while.
				busy = false;
				Syntax.code("setTimeout({0}, 1000)", ask);
			});
		}
		ask();
	}

	/**
		Asks the DevServer which served files changed, and tells the reloaders.

		This is a long poll of its own, so an asset never loads a bundle. The first answer only
		sets the starting point. Files changed before the program started were already loaded.
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
		Runs the new bundle beside this one.

		A page imports it, under a new URL each time. Node's module cache ignores a URL's query
		for a CommonJS file (a plain .js), so in node the bundle is read and run as a script.
	**/
	static function load(info:Dynamic):Dynamic {
		if (inBrowser())
			return Syntax.code("import({0})", info.url + "?v=" + info.version);
		return Syntax.code("new Promise(resolve => { const fs = process.getBuiltinModule('fs'); (0, eval)(fs.readFileSync({0}, 'utf8') + '\\n//# sourceURL=' + {0} + '?v=' + {1}); resolve(null); })", info.file, info.version);
	}

	static function log(message:String)
		Syntax.code("console.log({0})", "hotreload: " + message);

	/** Reports a reload hook, or a main class's callback, that threw. **/
	static function hookFailed(name:String, e:Dynamic)
		log('hook: $name failed (${Std.string(e)})');

	/** Makes the bundle `neu`'s classes the current ones, in place of `old`'s (see the class doc). **/
	static function swap(old:Dynamic, neu:Dynamic) {
		var start = haxe.Timer.stamp();
		var oldHooks:Dynamic = Reflect.field(old.classes, "hotreload.Hooks");
		if (oldHooks != null)
			oldHooks.runBefore(hookFailed);
		for (r in reloaders)
			if (r.beforeReload != null)
				try {
					r.beforeReload();
				} catch (e:Dynamic) {
					hookFailed("beforeReload", e);
				}

		// The classes both bundles have, and their methods, mapped old to new. The first
		// bundle's classes are included when it is not the old one. The main class, and
		// whatever else holds on to the first bundle's classes, calls through them. So they
		// forward to the new code directly, not through the bundles in between (which are released).
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
					if (Syntax.code("typeof {0}[{1}] == 'function'", n, key)) {
						var was:Dynamic = Reflect.field(o, key);
						if (was.__hot_impl__ != null) {
							// A static function passed as a value (Builder.lateStatics) stays the
							// same function, as the new code's, so the new code can remove it.
							var now:Dynamic = Reflect.field(n, key);
							was.__hot_impl__ = now.__hot_impl__ != null ? now.__hot_impl__ : now;
							Syntax.code("Object.defineProperty({0}, {1}, {value: {2}, writable: true, configurable: true})", n, key, was);
						} else
							functions.set(was, Reflect.field(n, key));
					}
				if (o.prototype != null && n.prototype != null)
					for (key in methods(o.prototype))
						if (key != "constructor" && Syntax.code("typeof {0}[{1}] == 'function'", n.prototype, key))
							functions.set(Reflect.field(o.prototype, key), Reflect.field(n.prototype, key));
			}

		// A bound method made before the reload (a hot build's `$bind`, Builder.lateBind)
		// follows each old method to the new one. The new one takes the old one's id, so
		// binding it again finds the same function. removeEventListener(CLICK, onClick) then
		// removes the listener added before the reload.
		Syntax.code("for (const [o, n] of {0}) { o.__hot_next__ = n; if (o.__id__ != null && n.__id__ == null) n.__id__ = o.__id__; }", functions);

		// The statics' values, and what they hold.
		var walker = new Walker(protos, classes, functions, old.enums, neu.enums, Reflect.field(neu.classes, "haxe.ds.EnumValueMap"));
		var kept = 0;
		var reset = 0;
		for (p in pairs) {
			if (!p.carry)
				continue; // The first bundle's statics already read the old bundle's.
			var was:Dynamic = Reflect.field(p.o, "__hot_statics__");
			var now:Dynamic = Reflect.field(p.n, "__hot_statics__");
			for (key in statics(p.o))
				if (!isMethod(p.n, key)) {
					var w:Dynamic = was == null ? null : Reflect.field(was, key);
					var n:Dynamic = now == null ? null : Reflect.field(now, key);
					var value:Dynamic = Reflect.field(p.o, key);
					var why = null;
					if (n != null && n.reset == true) {
						why = ""; // Every reload. Not reported.
					} else if (n != null && n.init != null && (w == null || w.init != n.init)) {
						why = 'initial value changed: ${w == null || w.text == null ? "none" : w.text} to ${n.text}';
					} else if (w != null && n != null && w.type != null && n.type != null && w.type != n.type) {
						// The new code declares another type. A value that still fits is carried over.
						if (sameKind(value, Reflect.field(p.n, key)))
							log('static: ${p.name}.$key kept (type changed: ${w.type} to ${n.type})');
						else
							why = 'type changed: ${w.type} to ${n.type}';
					}
					if (why != null) {
						// The new code's first value. A static with none is not emitted (Haxe also omits
						// a null first value), so it is set to null, not left undefined.
						if (!Syntax.code("Object.prototype.hasOwnProperty.call({0}, {1})", p.n, key))
							Reflect.setField(p.n, key, null);
						if (why != "")
							log('static: ${p.name}.$key reset ($why)');
						reset++;
						continue;
					}
					Reflect.setField(p.n, key, walker.visit(value));
					kept++;
				}
		}
		walker.finish();
		walker.sortEnumMaps();

		for (p in pairs)
			if (p.carry)
				compareCode(p.name, Reflect.field(p.o, "__hot_code__"), Reflect.field(p.n, "__hot_code__"));

		// The old classes forward to the new ones.
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

		// Only the current bundle is kept. The old one's code is released once nothing uses it.
		state.bundles = first == neu ? [neu] : [first, neu];

		var newHooks:Dynamic = Reflect.field(neu.classes, "hotreload.Hooks");
		if (newHooks != null)
			newHooks.runAfter(hookFailed);
		for (r in reloaders)
			if (r.afterReload != null)
				try {
					r.afterReload();
				} catch (e:Dynamic) {
					hookFailed("afterReload", e);
				}
		log('reload: done (${[for (p in pairs) if (p.carry) p].length} classes, $kept statics kept, $reset reset, ${walker.objects} objects, '
			+ '${Math.round((haxe.Timer.stamp() - start) * 1000)} ms)');
	}

	/**
		Reports the edits to a class that a reload cannot bring in.

		The build records each class's code as hashes (`__hot_code__`, Builder's `CodeInfo`).
		A changed main is reported because it does not run again. A changed constructor is
		reported because objects made before the reload are not constructed again. A changed
		field initializer or declared field type is reported because existing objects keep
		their values. A field removed while another is added is reported as a possible rename,
		since values are not moved. A changed closure is reported because instances made before
		the reload keep the old body.

		Closures are compared per method, as sets of hashes. A closure counts as changed only
		when as many hashes went as came, so an added closure is not taken for an edit.

		@param name  The class's full name.
		@param was  The running code's `__hot_code__`, or null.
		@param now  The new code's `__hot_code__`, or null.
	**/
	static function compareCode(name:String, was:Dynamic, now:Dynamic) {
		if (was == null || now == null)
			return;
		if (was.main != null && now.main != null && was.main != now.main)
			log('main: $name.main changed (not run again); use an @:afterHotReload hook');
		if (was.ctor != null && now.ctor != null && was.ctor != now.ctor)
			log('constructor: $name changed (existing objects not constructed again)');
		var removed = [for (f in Reflect.fields(was.fields)) if (!Reflect.hasField(now.fields, f)) '$name.$f'];
		var added = [];
		for (f in Reflect.fields(now.fields)) {
			var w:Dynamic = Reflect.field(was.fields, f);
			var n:Dynamic = Reflect.field(now.fields, f);
			if (w == null) {
				added.push('$name.$f');
				continue;
			}
			if (w.type != "" && n.type != "" && w.type != n.type)
				log('field: $name.$f type changed (${w.type} to ${n.type}, existing objects keep their values)');
			if (n.init != "" && w.init != n.init)
				log('field: $name.$f initializer changed (existing objects keep their values)');
		}
		if (removed.length > 0 && added.length > 0)
			log('field: ${removed.join(", ")} removed, ${added.join(", ")} added (values not moved)');
		for (method in Reflect.fields(now.closures)) {
			var before:Array<Dynamic> = Reflect.field(was.closures, method);
			if (before == null)
				continue;
			var gone = [for (c in before) c.hash];
			var came = [];
			for (c in (Reflect.field(now.closures, method):Array<Dynamic>))
				if (!gone.remove(c.hash))
					came.push(c);
			if (came.length == gone.length)
				for (c in came)
					log('closure: ${c.at} changed (in $name.$method, ones made before the reload run the old body)');
		}
	}

	/**
		Returns whether a value of one type can be carried over to another.

		It can when both are the same kind of value, or when the new type has no first value
		(null). This is the rule for a static whose type changed.
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

	/** Returns a class's (or prototype's) own methods, its functions that are not enumerable. **/
	static function methods(o:Dynamic):Array<String>
		return Syntax.code("Object.getOwnPropertyNames({0}).filter(k => { const d = Object.getOwnPropertyDescriptor({0}, k); return d && !d.enumerable && typeof d.value == 'function' && k != 'length' && k != 'name' && k != 'prototype' && !k.startsWith('__'); })", o);

	/** Returns a class's statics, its own enumerable properties, excluding Haxe's own (`__name__`). **/
	static function statics(o:Dynamic):Array<String>
		return Syntax.code("Object.keys({0}).filter(k => !k.startsWith('__'))", o);

	/** Returns whether a class has a method by that name (and so no static). **/
	static function isMethod(o:Dynamic, key:String):Bool
		return Syntax.code("(() => { const d = Object.getOwnPropertyDescriptor({0}, {1}); return d != null && !d.enumerable && typeof d.value == 'function'; })()", o, key);
}

/**
	Represents the walk that carries the statics' values over.

	Objects are re-prototyped in place, enum values are made again, and methods are re-pointed.
**/
private class Walker {
	var protos:Dynamic;
	var classes:Dynamic;
	var functions:Dynamic;
	var oldEnums:Dynamic;
	var newEnums:Dynamic;
	var enumMapClass:Dynamic;
	var enumMaps:Array<Dynamic> = [];
	var seen:Dynamic = Syntax.code("new Map()");
	var pending:Array<Dynamic> = [];
	var knownProtos:Dynamic = Syntax.code("new Set()");

	public var objects = 0;

	public function new(protos, classes, functions, oldEnums, newEnums, enumMapClass) {
		this.enumMapClass = enumMapClass;
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
			return v; // A closure. It runs the code it came from.
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
			// Its new fields receive their initializers, each class's, from the top down.
			Syntax.code("for (let p = {1}; p && p !== Object.prototype; p = Object.getPrototypeOf(p)) for (const k of Object.getOwnPropertyNames(p)) if (k.startsWith('__hot_init_') && typeof p[k] == 'function') p[k].call({0})", v, next);
		}
		pending.push(v);
		return v;
	}

	/** Walks what the visited objects hold, with a queue rather than recursion. **/
	public function finish() {
		while (pending.length > 0) {
			var v:Dynamic = pending.pop();
			if (Syntax.code("Array.isArray({0})", v)) {
				var a:Array<Dynamic> = v;
				for (i in 0...a.length)
					a[i] = visit(a[i]);
			} else if (Syntax.code("{0} instanceof Map", v)) {
				// The keys too: an object's new fields, an enum value made again
				Syntax.code("{ const entries = Array.from({0}); {0}.clear(); for (const [k, x] of entries) {0}.set({1}(k), {1}(x)); }", v, visit);
			} else if (Syntax.code("{0} instanceof Set", v)) {
				Syntax.code("{ const items = Array.from({0}); {0}.clear(); for (const x of items) {0}.add({1}(x)); }", v, visit);
			} else {
				if (enumMapClass != null && Syntax.code("{0} instanceof {1}", v, enumMapClass))
					enumMaps.push(v);
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
	/**
		Sorts again each enum-keyed map the walk reached (`Map<Mood, T>`, an EnumValueMap).

		Such a map is a tree ordered by constructor index. Its keys now have the new code's
		indices, so its entries are inserted again in a cleared tree.
	**/
	public function sortEnumMaps() {
		for (m in enumMaps)
			Syntax.code("{ const entries = []; const walk = n => { if (n == null) return; walk(n.left); entries.push([n.key, n.value]); walk(n.right); }; walk({0}.root); {0}.root = null; for (const [k, x] of entries) {0}.set(k, x); }", m);
	}


	/**
		Returns whether a value is worth walking into.

		Arrays, maps, plain objects and Haxe classes' objects are. The page's objects and the
		engine's buffers are not.
	**/
	function walkable(v:Dynamic):Bool {
		if (Syntax.code("Array.isArray({0}) || {0} instanceof Map || {0} instanceof Set", v))
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

	/** Returns an enum value made again from the new enum, by its constructor's name. **/
	function enumValue(v:Dynamic):Dynamic {
		var name:String = v.__enum__;
		var oldEnum:Dynamic = Reflect.field(oldEnums, name);
		var newEnum:Dynamic = Reflect.field(newEnums, name);
		// A constant with no arguments is already the new enum's (JsSwap.adoptEnums).
		if (oldEnum == null || newEnum == null || oldEnum == newEnum || (v._hx_name != null && Reflect.field(newEnum, v._hx_name) == v)) {
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
		// A new value met again is already the new enum's, so it is not made again.
		seen.set(result, result);
		return result;
	}
}
#end
