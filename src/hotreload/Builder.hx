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
	sources build one ordinary program: the reload metadata is ignored.

	A hot build reloads whole: the page loads the new bundle beside the old one, and the
	reloader (Reloader, JsSwap) makes its classes the current ones, objects and all. Every
	static keeps its value, but one whose first value was edited, which starts over from
	the new one, and one marked `@:resetOnHotReload`. What it takes from here: each
	class's statics' types and first values, as written (`__hot_statics__`), a guard that
	keeps a reloaded bundle's `main` from running again, each class's field initializers,
	for the objects a reload carries over (their new fields start from them), the reload
	hooks, a `$bind` that follows a bound method to its new code, and, for the DevServer,
	how to build it again.
**/
class Builder {
	#if macro
	static var mode = Off;
	static var mainClass:String;
	/** the project's own class paths: its code, watched, and warned about **/
	static var projectDirs:Array<String> = [];

	/** the class paths inside the project's directory left out of it: its local repository's libraries **/
	static var excludedDirs:Array<String> = [];

	/** the main class's file, found from the class paths **/
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

	/** whether a class is the project's own code, but the main class: one the build warns about **/
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

	/** `@:build` on every class of a hot build: its statics' types and first values, the reload hooks, and what a carried object needs **/
	public static function build():Array<Field> {
		var ref = Context.getLocalClass();
		if (ref == null)
			return null;
		var cls = ref.get();
		return buildJs(cls, Context.getBuildFields(), fullName(cls.pack, cls.name));
	}

	/**
		What the reload metadata can be on: a hook (`@:beforeHotReload`, `@:afterHotReload`),
		a static function with no parameters; `@:resetOnHotReload`, a static var that holds a
		value. `@:hot`, which kept a static on the hxcpp branch, does nothing, and is warned
		about where it's written: every static is kept
	**/
	static function checkMeta(field:Field, hook:MetadataEntry, reset:Bool) {
		if (!field.access.contains(AStatic))
			Context.error("the reload hooks and @:resetOnHotReload are for statics: an instance is carried across a reload with its fields",
				field.pos);
		if (hook != null) {
			var fn = switch (field.kind) {
				case FFun(f): f;
				default: Context.error('@${hook.name}: a static function', field.pos);
			}
			if (fn.args.length > 0)
				Context.error('@${hook.name}: a function with no parameters', field.pos);
		}
		if (reset && (field.kind.match(FFun(_)) || field.access.contains(AInline) || !hasStorage(field)))
			Context.error("@:resetOnHotReload: a static var that holds a value", field.pos);
	}

	/** a first value as written, shortened for a message: `3.0`, `"seven"`, `new Map()` **/
	static function shortText(e:Expr):String {
		var text = ~/\s+/g.replace(e.toString(), " ");
		return text.length > 40 ? text.substr(0, 37) + "..." : text;
	}

	/** a class: its hooks, its main's guard, its field initializers, and its statics' types and first values **/
	static function buildJs(cls:ClassType, fields:Array<Field>, className:String):Array<Field> {
		var changed = false;
		var result = [];
		var extra = [];
		var statics = [];
		for (field in fields) {
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			var reset = field.meta.exists(m -> m.name == ":resetOnHotReload");
			if (hook != null || reset)
				checkMeta(field, hook, reset);
			var hot = field.meta.find(m -> m.name == ":hot");
			if (hot != null && mode == Js)
				Context.warning("hotreload: @:hot is deprecated: every static is kept now. "
					+ "Remove it, or use @:resetOnHotReload to reset a static on every reload.", hot.pos);
			// a static's type and first value, as written, which a reload compares (JsSwap): a
			// first value edited starts it over from the new one; a type changed keeps the value
			// when it's still the same kind. (A property with no storage, `(get, never)`,
			// holds no value: nothing to keep)
			if (field.access.contains(AStatic) && !field.access.contains(AInline))
				switch (field.kind) {
					case FVar(t, e) | FProp(_, _, t, e) if (hasStorage(field)):
						var info:Array<ObjectField> = [];
						if (t != null)
							info.push({field: "type", expr: macro $v{t.toString()}});
						if (e != null) {
							info.push({field: "init", expr: macro $v{haxe.crypto.Md5.encode(e.toString())}});
							info.push({field: "text", expr: macro $v{shortText(e)}});
						}
						if (reset)
							info.push({field: "reset", expr: macro true});
						if (info.length > 0)
							statics.push({field: field.name, expr: {expr: EObjectDecl(info), pos: field.pos}});
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
		if (statics.length > 0 && !cls.isInterface && !cls.isExtern && !abstractImpl && file != null && !file.startsWith(stdDir())) {
			extra.push(staticVar("__hot_statics__", macro:Dynamic, {expr: EObjectDecl(statics), pos: cls.pos}, cls.pos));
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

