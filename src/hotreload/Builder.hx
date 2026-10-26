package hotreload;

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sys.FileSystem;

using Lambda;
using StringTools;
using haxe.macro.Tools;

private enum Mode {
	Off;
	Js;       // a hot build: -D hotreload, which hotreload.DevServer serves and rebuilds
	JsReload; // a reload's build, which the DevServer starts: -D hotreload_reload
}
#end

/**
	What makes a build hot: `--macro hotreload.Builder.init()` (which `-lib hotreload-hx` adds)
	and `-D hotreload`, on a JS build. Without the define it does nothing, and the same
	sources build one ordinary program: `@:hot` and the reload hooks are ignored.

	A hot build reloads whole: the page loads the new bundle beside the old one, and the
	reloader (Reloader, JsSwap) makes its classes the current ones, objects and all. Of the
	project's classes, only the `@:hot` statics are carried over, and the rest start over;
	the main class's, the standard library's and a haxelib's are all kept. What it takes
	from here: the project's classes and their `@:hot` statics (a resource), a guard that
	keeps a reloaded bundle's `main` from running again, each class's field initializers,
	for the objects a reload carries over (their new fields start from them), the reload
	hooks, a `$bind` that follows a bound method to its new code, and, for the DevServer,
	how to build it again.
**/
class Builder {
	/** a typed expression's type, as a string: a JS class's `__hot_types__` for a static with no type written **/
	public static macro function typeName(e:haxe.macro.Expr):haxe.macro.Expr {
		return macro $v{haxe.macro.Context.typeof(e).toString()};
	}

	#if macro
	static var mode = Off;
	static var mainClass:String;
	/** the project's own class paths: its code, whose plain statics start over on a reload **/
	static var projectDirs:Array<String> = [];

	/** the class paths inside the project's directory left out of it: its local repository's libraries **/
	static var excludedDirs:Array<String> = [];

	/** the main class's file, found from the class paths: never reloaded code **/
	static var mainFile:String;

	static var configured = false;

	public static function init() {
		// once per build, however many times the build names the library
		if (Context.defined("hotreload_initialized"))
			return;
		Compiler.define("hotreload_initialized");
		// a compilation server keeps a macro's statics from one build to the next
		mode = Off;
		mainClass = null;
		projectDirs = [];
		mainFile = null;
		configured = false;
		std = null;
		own = null;
		if (!Context.defined("hotreload"))
			return;
		if (!Context.defined("js")) {
			// (an init macro's warning isn't shown)
			Sys.stderr().writeString("hotreload: build: not hot (only a JS build reloads)\n");
			Sys.stderr().flush();
			return;
		}
		mode = Context.defined("hotreload_reload") ? JsReload : Js;
		invalidate();
		initJs();
		Compiler.addGlobalMetadata("", "@:build(hotreload.Builder.build())", true, true, false);
	}

	static function invalidate() {
		if (!Context.defined("hotreload_invalidate"))
			return;
		var list = try sys.io.File.getContent(Context.definedValue("hotreload_invalidate")) catch (_) "";
		var files = [for (f in list.split("\n")) if (f != "") f];
		if (files.length > 0)
			try haxe.macro.CompilationServer.invalidateFiles(files) catch (_) {}
	}

	static function initJs() {
		// a reload's swap fails on ES5 output ("newHooks.runAfter is not a function"). js-es
		// can't be set from here: the compiler has read it already (an ES5 constructor's
		// `this` before `super()` would stay), so it's set on the command line, by the library's extraParams.hxml
		var es = Context.definedValue("js-es");
		if (es == null || Std.parseInt(es) == null || Std.parseInt(es) < 6)
			Context.fatalError("hotreload: a hot JS build needs -D js-es=6 (-lib hotreload-hx sets it; something set it lower)", Context.currentPos());
		var args = Sys.args();
		var js = null;
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "-main" | "--main" | "-m":
					mainClass = args[i + 1];
				case "-js" | "--js":
					js = args[i + 1];
			}
			i++;
		}
		if (mode == Js && (args.contains("--next") || args.contains("--each")))
			Context.fatalError("hotreload: a hot build is one build: take --next and --each out of its hxml", Context.currentPos());
		var cwd = Path.addTrailingSlash(Sys.getCwd());
		findProject(args, cwd);
		var path = Context.defined("hotreload_config") ? Context.definedValue("hotreload_config") : absolute(cwd, js) + ".hotreload.json";
		var output = absolute(cwd, js);
		Context.onAfterGenerate(() -> lateBind(output));
		Context.onAfterTyping(types -> {
			warnMethodValues(types);
			if (configured)
				return;
			configured = true;
			// the project's classes and their `@:hot` statics: the only statics of theirs a
			// swap carries over (JsSwap). Read off the typed classes, every build (a reload's
			// too), since a compilation server doesn't run a cached module's build macro
			// again; and a resource, the bundle's own
			var statics = new haxe.DynamicAccess<Array<String>>();
			for (t in types)
				switch (t) {
					case TClassDecl(_.get() => c) if (isProject(c)):
						statics.set(fullName(c.pack, c.name), [for (f in c.statics.get()) if (f.meta.has(":hot") && f.kind.match(FVar(_, _))) f.name]);
					default:
				}
			Context.addResource("hotreload.statics", haxe.io.Bytes.ofString(haxe.Json.stringify(statics)));
			// (a reload's build says it too when asked: the DevServer watches its class paths, which an edited hxml changes)
			if (mode == JsReload && !Context.defined("hotreload_config"))
				return;

			var config:JsConfig = {
				cwd: cwd,
				args: [for (a in args) a],
				dirs: projectDirs,
				excluded: excludedDirs,
				js: Path.normalize(absolute(cwd, js)),
				mainClass: mainClass,
			};
			// (the output's directory may not be there yet: the compiler makes it later)
			if (!sys.FileSystem.exists(Path.directory(path)))
				sys.FileSystem.createDirectory(Path.directory(path));
			sys.io.File.saveContent(path, haxe.Json.stringify(config, "\t"));
		});
	}

	/** a bound method's function, in a hot JS build: its method looked up as it's called, so one made before a reload runs the new code **/
	static inline var LATE_BIND = "function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; "
		+ "if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { "
		+ "f = function() { var g = f.method; while( g.__hot_next__ != null ) g = f.method = g.__hot_next__; return g.apply(o,arguments); }; "
		+ "f.method = m; o.hx__closures__[m.__id__] = f; } return f; }";

	/**
		A bound method (`addEventListener(CLICK, onClick)`) is Haxe's `$bind`, which binds the
		method as it is (`m.bind(o)`): one made before a reload would run the old code. The
		output's `$bind` is replaced by one that follows the method to its newest code
		(`__hot_next__`, which a swap sets: JsSwap), on its one line, so no line moves for the
		source map. A bundle with no bound method has no `$bind`
	**/
	static function lateBind(output:String) {
		if (!FileSystem.exists(output))
			return;
		var text = sys.io.File.getContent(output);
		var start = text.indexOf("\nfunction $bind(o,m) {");
		if (start < 0)
			return;
		var end = text.indexOf("\n", start + 1);
		if (end < 0)
			end = text.length;
		if (text.substring(start + 1, end) != LATE_BIND)
			sys.io.File.saveContent(output, text.substring(0, start + 1) + LATE_BIND + text.substring(end));
	}

	/**
		The project: its own class paths (inside its directory; not the standard library's
		or a haxelib's, a local repository's, `.haxelib/`, inside it too), or else the main
		class's directory, and the main class's file. Its classes' plain statics start over on
		a reload; its sources are watched
	**/
	static function findProject(args:Array<String>, cwd:String) {
		mainFile = try Path.normalize(FileSystem.absolutePath(Context.resolvePath(mainClass.replace(".", "/") + ".hx"))) catch (_) null;
		var dirs = [];
		var excluded = [];
		var j = 0;
		while (j < args.length) {
			if ((args[j] == "-cp" || args[j] == "-p" || args[j] == "--class-path") && j + 1 < args.length) {
				var dir = Path.removeTrailingSlashes(Path.normalize(absolute(cwd, args[j + 1])));
				var library = (dir + "/").contains("/.haxelib/");
				if (dir.startsWith(Path.removeTrailingSlashes(cwd)) && FileSystem.exists(dir) && !dirs.contains(dir) && !excluded.contains(dir))
					(library ? excluded : dirs).push(dir);
			}
			j++;
		}
		if (dirs.length == 0 && mainFile != null)
			dirs.push(Path.directory(mainFile));
		projectDirs = dirs;
		excludedDirs = excluded;
	}

	/** whether a class is the project's own code, but the main class: one whose plain statics start over on a reload **/
	static function isProject(c:ClassType):Bool {
		if (c.isExtern || c.isInterface || c.kind.match(KAbstractImpl(_)))
			return false;
		var file = fileOf(c.pos);
		return file != null && file != mainFile && inside(file, projectDirs) && !file.startsWith(stdDir()) && !file.startsWith(ownDir());
	}

	/**
		A method of your code passed as a value, `load(path, place)`: a static's closure
		that nothing a static holds leads to runs its old code after a reload. A lambda that
		calls the method by name, `x -> place(x)`, reaches the new code. Told, at each use,
		in every hot build, in your code and in the main class
	**/
	static function warnMethodValues(types:Array<ModuleType>) {
		for (t in types)
			switch (t) {
				// (the main class's too: `reloader.assetsChanged = Game.assetsChanged` is as stuck)
				case TClassDecl(_.get() => c) if (isProject(c) || fullName(c.pack, c.name) == mainClass):
					var fields = c.statics.get().concat(c.fields.get());
					if (c.constructor != null)
						fields.push(c.constructor.get());
					for (f in fields) {
						// this macro's own: a hook handed to the reloader
						if (f.name.startsWith("__hot_"))
							continue;
						var e = f.expr();
						if (e != null)
							methodValues(e, false);
					}
				default:
			}
	}

	static function methodValues(e:TypedExpr, called:Bool) {
		switch (e.expr) {
			case TCall(callee, args):
				methodValues(callee, true);
				for (a in args)
					methodValues(a, false);
			case TParenthesis(x) | TMeta(_, x):
				methodValues(x, called);
			case TField(sub, access):
				if (!called) {
					var method = switch (access) {
						case FStatic(c, cf) | FInstance(c, _, cf) | FClosure({c: c}, cf) if (isProject(c.get())): cf.get();
						default: null;
					}
					if (method != null && method.kind.match(FMethod(MethNormal)))
						Context.warning('hotreload: ${method.name} passed as a value keeps its old code after a reload; call it from a lambda, x -> ${method.name}(x)', e.pos);
				}
				methodValues(sub, false);
			default:
				e.iter(x -> methodValues(x, false));
		}
	}

	/** `@:build` on every class of a hot build: `@:hot` statics, the reload hooks, and what a carried object needs **/
	public static function build():Array<Field> {
		var ref = Context.getLocalClass();
		if (ref == null)
			return null;
		var cls = ref.get();
		return buildJs(cls, Context.getBuildFields(), fullName(cls.pack, cls.name));
	}

	/**
		What `@:hot` and the reload hooks can be on: a static var or function of a class
		other than the main class; a hook, a static function with no parameters; a `@:hot`
		var, one with a type or a first value (its type, which a reload compares)
	**/
	static function checkHot(cls:ClassType, field:Field, hook:MetadataEntry) {
		if (isMain(cls))
			Context.error("@:hot and the reload hooks cannot be used in the main class because the main class is never reloaded. "
				+ "Use them in the reloaded classes (for the main class's own, set reloader.beforeReload and reloader.afterReload)", field.pos);
		if (!field.access.contains(AStatic))
			Context.error("@:hot and the reload hooks are for statics: an instance is carried across a reload with its fields", field.pos);
		if (hook != null) {
			var fn = switch (field.kind) {
				case FFun(f): f;
				default: Context.error('@${hook.name}: a static function', field.pos);
			}
			if (fn.args.length > 0)
				Context.error('@${hook.name}: a function with no parameters', field.pos);
			return;
		}
		switch (field.kind) {
			case FVar(null, null) | FProp(_, _, null, null):
				Context.error("@:hot: give it a type, or a first value", field.pos);
			case FProp("default", "default" | "null" | "never", _, _):
			case FProp(_, _, _, _):
				Context.error("@:hot: a static var or function, or a (default, null) or (default, never) one; not a property with accessors", field.pos);
			default:
		}
	}

	/**
		a `@:hot` var's type, and that type as a reload compares it: the one written, or else
		the one its first value says (`writtenType`)
	**/
	static function hotType(field:Field, t:ComplexType, e:Expr):{t:ComplexType, sig:String} {
		if (t == null)
			t = writtenType(e);
		if (t == null)
			Context.error("@:hot: give it a type (its first value does not say it: a literal, `new T()` or a cast would)", field.pos);
		return {t: t, sig: try Context.resolveType(t, field.pos).toString() catch (_) t.toString()};
	}

	/**
		the type an expression says as written: a literal's, `new T()`'s, a cast's or a check's
		(`(e : T)`), an array of them; else null. Not typed: typing an expression while a class
		is built (Context.typeof) builds the classes it reaches early, before this one has its
		fields and its other build macros have run, which breaks theirs
	**/
	static function writtenType(e:Expr):ComplexType {
		if (e == null)
			return null;
		return switch (e.expr) {
			case EConst(CInt(_)): macro:Int;
			case EConst(CFloat(_)): macro:Float;
			case EConst(CString(_)): macro:String;
			case EConst(CRegexp(_)): macro:EReg;
			case EConst(CIdent("true" | "false")): macro:Bool;
			case EParenthesis(e) | EMeta(_, e) | EUnop(OpNeg, false, e): writtenType(e);
			case ENew(tp, _): TPath(tp);
			case ECheckType(_, t) | ECast(_, t) if (t != null): t;
			case EArrayDecl(values) if (values.length > 0):
				var t = writtenType(values[0]);
				if (t == null || values.exists(v -> writtenType(v) == null || writtenType(v).toString() != t.toString()))
					null;
				else
					TPath({pack: [], name: "Array", params: [TPType(t)]});
			default: null;
		}
	}

	/** a class: its hooks, its main's guard, its field initializers, and its statics' types **/
	static function buildJs(cls:ClassType, fields:Array<Field>, className:String):Array<Field> {
		var changed = false;
		var result = [];
		var extra = [];
		var types = [];
		for (field in fields) {
			var hot = field.meta.exists(m -> m.name == ":hot");
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			if (hot || hook != null)
				checkHot(cls, field, hook);
			// a static's type, as written (or its first value's): a reload that changes it
			// carries the value over only when it's still the same kind (JsSwap.sameKind)
			if (field.access.contains(AStatic))
				switch (field.kind) {
					case FVar(t, e) | FProp("default", _, t, e) if (hot):
						types.push({field: field.name, expr: macro $v{hotType(field, t, e).sig}});
					// (a property with no storage, `(get, never)`, holds no value: nothing to compare,
					// and no first value to give it: Haxe refuses one)
					case FVar(t, e) | FProp(_, _, t, e) if (hasStorage(field)):
						// (one with no type written: its own, once it's typed, not its first value's now: see writtenType)
						if (t != null)
							types.push({field: field.name, expr: macro $v{t.toString()}});
						else if (e != null)
							types.push({field: field.name, expr: macro hotreload.Builder.typeName($i{field.name})});
						// a plain static with no first value: 0 or false for a number or a bool (JS
						// wouldn't emit it, and a reload would leave it undefined; a null one is left
						// out either way, and the swap gives it null)
						if (e == null && !field.access.contains(AInline) && isProject(cls)) {
							var def = defaultOf(t, field.pos);
							if (def != null && !def.expr.match(EConst(CIdent("null")))) {
								field.kind = switch (field.kind) {
									case FVar(t, _): FVar(t, def);
									case FProp(g, s, t, _): FProp(g, s, t, def);
									default: field.kind;
								}
								changed = true;
							}
						}
					default:
				}
			if (hook != null) {
				var after = hook.name == ":afterHotReload";
				var name = field.name;
				extra.push(staticVar('__hot_hook_$name', macro:Bool, macro hotreload.Hooks.add($v{after}, $i{name}), field.pos));
				changed = true;
			} else if (field.name == "main" && field.access.contains(AStatic) && isMain(cls)) {
				switch (field.kind) {
					case FFun(f):
						// a reloaded bundle's classes replace the running ones: its main mustn't
						// start the program a second time
						f.expr = macro {
							if (hotreload.Reloader.isReload())
								return;
							${f.expr};
						}
						changed = true;
					default:
				}
			}
			result.push(field);
		}
		var file = fileOf(cls.pos);
		var abstractImpl = cls.kind.match(KAbstractImpl(_)) || Context.getLocalType().match(TAbstract(_, _));
		if (types.length > 0 && !cls.isInterface && !cls.isExtern && !abstractImpl && file != null && !file.startsWith(stdDir())) {
			extra.push(staticVar("__hot_types__", macro:Dynamic, {expr: EObjectDecl(types), pos: cls.pos}, cls.pos));
			changed = true;
		}
		if (!cls.isInterface && !cls.isExtern && !abstractImpl && file != null && !file.startsWith(stdDir())) {
			var init = jsFieldInitializer(className, fields);
			if (init != null) {
				extra.push(init);
				changed = true;
			}
		}
		return changed ? result.concat(extra) : null;
	}

	/**
		A JS class's field initializers, for an object a reload carries over: each of its
		fields that the object doesn't have (a new one) starts from its initializer
	**/
	static function jsFieldInitializer(className:String, fields:Array<Field>):Field {
		var inits = [];
		for (f in fields) {
			if (f.access.contains(AStatic))
				continue;
			var e = switch (f.kind) {
				case FVar(_, e) if (e != null): e;
				case FProp("default" | "null", "default" | "null" | "never", _, e) if (e != null): e;
				default: null;
			}
			if (e != null) {
				var name = f.name;
				// a final field can't be assigned past its constructor, but can be set
				var set = f.access.contains(AFinal) ? macro std.Reflect.setField(this, $v{name}, $e) : macro this.$name = $e;
				inits.push(macro if (!std.Reflect.hasField(this, $v{name})) $set);
			}
		}
		if (inits.length == 0)
			return null;
		return {
			name: "__hot_init_" + className.replace(".", "_"),
			access: [APublic],
			meta: [{name: ":keep", pos: Context.currentPos()}, {name: ":noCompletion", pos: Context.currentPos()}],
			kind: FFun({args: [], ret: macro:Void, expr: macro $b{inits}}),
			pos: Context.currentPos(),
		};
	}

	/**
		A static's value when it has no first value: 0 for a number, false for a bool, null
		otherwise; or null when the type can't be found here. A static with no first value
		isn't emitted at all, so the build gives it this as its first value, and a reload
		that starts it over gives it this, not undefined
	**/
	static function defaultOf(t:ComplexType, pos:Position):Expr {
		if (t == null)
			return null;
		var type = try Context.resolveType(t, pos) catch (_) return null;
		return switch (Context.follow(type)) {
			case TAbstract(_.get() => a, _) if (a.name == "Null" && a.pack.length == 0): macro null;
			case followed:
				switch (Context.followWithAbstracts(followed)) {
					case TAbstract(_.get() => a, _) if (a.pack.length == 0 && (a.name == "Int" || a.name == "Float")): macro cast 0;
					case TAbstract(_.get() => a, _) if (a.pack.length == 0 && a.name == "Bool"): macro cast false;
					default: macro null;
				}
		}
	}

	/**
		whether a var or property holds a value: a var, or a property with `default` or `null`
		on either side, or `@:isVar`; not `(get, never)` or `(get, set)`, which are their accessors
	**/
	static function hasStorage(field:Field):Bool {
		return switch (field.kind) {
			case FVar(_, _): true;
			case FProp(get, set, _, _):
				get == "default" || get == "null" || set == "default" || set == "null" || field.meta.exists(m -> m.name == ":isVar");
			default: false;
		}
	}

	static function staticVar(name:String, t:ComplexType, e:Expr, pos:Position):Field {
		return {
			name: name,
			access: [AStatic, APrivate],
			meta: [{name: ":keep", pos: pos}, {name: ":noCompletion", pos: pos}],
			kind: FVar(t, e),
			pos: pos,
		};
	}

	static var std:String;

	/** the standard library's directory: never the project's **/
	static function stdDir():String {
		if (std == null)
			// StdTypes.hx is only at the standard library's root (Std.hx is overridden per target, in cpp/_std/, js/_std/)
			std = Path.addTrailingSlash(Path.directory(Path.normalize(FileSystem.absolutePath(Context.resolvePath("StdTypes.hx")))));
		return std;
	}

	static var own:String;

	/**
		this library's own class path (its src/), never the project's, wherever it is: the
		reloader's statics aren't started over, nor its code warned about
	**/
	static function ownDir():String {
		if (own == null)
			own = Path.addTrailingSlash(Path.directory(Path.directory(Path.normalize(FileSystem.absolutePath(Context.resolvePath("hotreload/Builder.hx"))))));
		return own;
	}

	static function isMain(cls:ClassType):Bool {
		return mainClass != null && Context.getLocalModule() == mainClass;
	}

	static function fullName(pack:Array<String>, name:String):String {
		return pack.length == 0 ? name : pack.join(".") + "." + name;
	}

	static function fileOf(pos:Position):String {
		var file = Context.getPosInfos(pos).file;
		if (file == null || file == "" || file.startsWith("?"))
			return null;
		return Path.normalize(FileSystem.absolutePath(file));
	}

	static function absolute(cwd:String, path:String):String {
		return Path.isAbsolute(path) ? path : Path.join([cwd, path]);
	}

	static function inside(file:String, dirs:Array<String>):Bool {
		return file != null && dirs.exists(d -> file.startsWith(d + "/"));
	}
	#end
}

/** how a JS hot build was made, for the DevServer to build it again **/
typedef JsConfig = {
	/** the build's directory, which its paths are from **/
	var cwd:String;

	/** its command line, whole: a reload's build writes the same bundle **/
	var args:Array<String>;

	/** where the sources are: the project's own class paths, watched, and below **/
	var dirs:Array<String>;

	/** the class paths inside the project's directory that aren't its own: its local repository's libraries (.haxelib/) **/
	var ?excluded:Array<String>;

	/** the bundle **/
	var js:String;

	var mainClass:String;
}

