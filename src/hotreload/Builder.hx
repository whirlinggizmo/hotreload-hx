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
	hooks, a `$bind` that follows a bound method to its new code, the same for a static
	function passed as a value, and, for the DevServer, how to build it again.
**/
class Builder {
	#if macro
	static var mode = Off;
	static var mainClass:String;
	/** the project's own class paths: its code, watched **/
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
		staticValues = null;
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
		Context.onAfterGenerate(() -> {
			lateBind(output);
			lateStatics(output);
		});
		Context.onAfterTyping(types -> {
			findStaticValues(types);
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
		A static function passed as a value (`addEventListener("keydown", Game.onKey)`) is
		the function itself: one passed before a reload would run the old code, and the new
		code's `Game.onKey` is another function, which removes nothing. Each one found
		(findStaticValues) is made a function that calls it (`__hot_impl__`), on its class's
		closing line, so no line moves for the source map; a swap keeps that function, and
		points it to the new code (JsSwap). One whose class isn't in the output as Haxe
		writes it is told
	**/
	static function lateStatics(output:String) {
		if (staticValues == null || !staticValues.keys().hasNext() || !FileSystem.exists(output))
			return;
		var text = sys.io.File.getContent(output);
		var changed = false;
		for (name => entry in staticValues) {
			var start = text.indexOf('\nclass $name ');
			var end = start < 0 ? -1 : text.indexOf("\n}", start + 1);
			var names = [for (n in entry.names.keys()) n];
			names.sort(Reflect.compare);
			if (end < 0) {
				for (n in names)
					Context.warning('hotreload: ${entry.cls}.$n passed as a value keeps its old code after a reload ($name not found in the output); call it from a lambda, x -> $n(x)', entry.names.get(n));
				continue;
			}
			end += 2;
			var line = ' for (const k of ${haxe.Json.stringify(names)}) { const f = $name[k], w = function() { return w.__hot_impl__.apply(this,arguments); }; w.__hot_impl__ = f; $name[k] = w; }';
			if (text.substr(end, line.length) == line)
				continue;
			text = text.substring(0, end) + line + text.substring(end);
			changed = true;
		}
		if (changed)
			sys.io.File.saveContent(output, text);
	}

	/**
		The project: its own class paths (inside its directory; not the standard library's
		or a haxelib's, a local repository's, `.haxelib/`, inside it too), or else the main
		class's directory, and the main class's file. Its sources are watched
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

	/**
		The static functions passed as values (`addEventListener("keydown", Game.onKey)`),
		by their classes' JS names: each one's position, for when its class isn't found in
		the output. Found by findStaticValues, made late-bound by lateStatics
	**/
	static var staticValues:Map<String, {cls:String, names:Map<String, Position>}>;

	/**
		The static functions the code passes as values, anywhere but in the standard
		library and this one: they're made late-bound (lateStatics). A method of an object
		passed as a value is Haxe's `$bind`, made late-bound by lateBind
	**/
	static function findStaticValues(types:Array<ModuleType>) {
		staticValues = [];
		for (t in types)
			switch (t) {
				case TClassDecl(_.get() => c) if (!c.isExtern && !isLibraryOwn(c)):
					var fields = c.statics.get().concat(c.fields.get());
					if (c.constructor != null)
						fields.push(c.constructor.get());
					for (f in fields) {
						var e = f.expr();
						if (e != null)
							valuesIn(e, false);
					}
				default:
			}
	}

	static function valuesIn(e:TypedExpr, called:Bool) {
		switch (e.expr) {
			case TCall(callee, args):
				valuesIn(callee, true);
				for (a in args)
					valuesIn(a, false);
			case TParenthesis(x) | TMeta(_, x):
				valuesIn(x, called);
			case TField(sub, FStatic(_.get() => c, _.get() => cf)) if (!called && cf.kind.match(FMethod(MethNormal)) && !c.isExtern && !isLibraryOwn(c)):
				var name = jsName(c);
				var entry = staticValues.get(name);
				if (entry == null)
					staticValues.set(name, entry = {cls: fullName(c.pack, c.name), names: []});
				if (!entry.names.exists(cf.name))
					entry.names.set(cf.name, e.pos);
				valuesIn(sub, false);
			default:
				e.iter(x -> valuesIn(x, false));
		}
	}

	/** a class of the standard library's or this one's: never reloaded **/
	static function isLibraryOwn(c:ClassType):Bool {
		var file = fileOf(c.pos);
		return file == null || file.startsWith(stdDir()) || file.startsWith(ownDir());
	}

	/** a class's name in the JS output (Haxe's genjs: its flat path, an abstract's implementation by the abstract's) **/
	static function jsName(c:ClassType):String {
		var native = c.meta.extract(":native");
		if (native.length > 0 && native[0].params.length > 0)
			switch (native[0].params[0].expr) {
				case EConst(CString(s)):
					return flatPath(s.split("."));
				default:
			}
		var path = switch (c.kind) {
			case KAbstractImpl(_.get() => a): a.pack.concat([a.name]);
			default: c.pack.concat([c.name]);
		}
		return flatPath(path);
	}

	static function flatPath(path:Array<String>):String
		return [for (part in path) part.split("_").join("_$")].join("_");

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
		var code = new CodeInfo();
		for (field in fields) {
			code.add(field, isMain(cls));
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
			var info = code.expr(cls.pos);
			if (info != null && !file.startsWith(ownDir())) {
				extra.push(staticVar("__hot_code__", macro:Dynamic, info, cls.pos));
				changed = true;
			}
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
	public static function hasStorage(field:Field):Bool {
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
	#end
}

#if macro
/**
	Represents a class's code as written, for a reload to compare (`JsSwap.compareCode`).

	Holds hashes of the main function, the constructor, each instance field's initializer and
	each method's closures. The hash of a closure, a main or a constructor leaves out the
	closures inside it. An edit is therefore reported once, at the closure where it was made.
**/
private class CodeInfo {
	var main:String;
	var ctor:String;
	var fields:Array<ObjectField> = [];
	var closures:Array<ObjectField> = [];

	public function new() {}

	/**
		Records a field's code.

		@param field  The field, before the build changes it.
		@param mainClass  True when the field's class is the main class.
	**/
	public function add(field:Field, mainClass:Bool) {
		var isStatic = field.access.contains(AStatic);
		switch (field.kind) {
			case FFun(f) if (f.expr != null):
				if (field.name == "new")
					ctor = hash(f.expr);
				else if (field.name == "main" && isStatic && mainClass)
					main = hash(f.expr);
				var found = [];
				closuresIn(f.expr, found);
				if (found.length > 0)
					closures.push({field: field.name, expr: macro $a{found}});
			case FVar(_, e) | FProp(_, _, _, e) if (!isStatic && Builder.hasStorage(field)):
				fields.push({field: field.name, expr: macro $v{e == null ? "" : hash(e)}});
			default:
		}
	}

	/**
		Returns the class's `__hot_code__` value.

		@param pos  The class's position.
		@return  The value, or null when the class has nothing to compare.
	**/
	public function expr(pos:Position):Expr {
		if (main == null && ctor == null && fields.length == 0 && closures.length == 0)
			return null;
		var info:Array<ObjectField> = [];
		if (main != null)
			info.push({field: "main", expr: macro $v{main}});
		if (ctor != null)
			info.push({field: "ctor", expr: macro $v{ctor}});
		info.push({field: "fields", expr: {expr: EObjectDecl(fields), pos: pos}});
		info.push({field: "closures", expr: {expr: EObjectDecl(closures), pos: pos}});
		return {expr: EObjectDecl(info), pos: pos};
	}

	/** Adds each closure in an expression, with its hash and its position, to a list. **/
	static function closuresIn(e:Expr, found:Array<Expr>) {
		switch (e.expr) {
			case EFunction(kind, f) if (f.expr != null):
				var whole = {expr: EFunction(kind, {args: f.args, ret: f.ret, params: f.params, expr: f.expr}), pos: e.pos};
				var loc = haxe.macro.PositionTools.toLocation(e.pos);
				found.push(macro {hash: $v{hash(whole, true)}, at: $v{loc.file.toString() + ":" + loc.range.start.line}});
				closuresIn(f.expr, found);
			default:
				e.iter(x -> closuresIn(x, found));
		}
	}

	/**
		Returns an expression's hash, as written, with the closures inside it left out.

		@param e  The expression.
		@param self  Optional. True when `e` is the closure being hashed, whose own body is kept.
	**/
	static function hash(e:Expr, self = false):String {
		function strip(x:Expr):Expr
			return switch (x.expr) {
				case EFunction(_, _): macro __closure__;
				default: x.map(strip);
			}
		var stripped = switch (e.expr) {
			case EFunction(kind, f) if (self): {expr: EFunction(kind, {args: f.args, ret: f.ret, params: f.params, expr: strip(f.expr)}), pos: e.pos};
			default: strip(e);
		}
		return haxe.crypto.Md5.encode(stripped.toString());
	}
}
#end

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

