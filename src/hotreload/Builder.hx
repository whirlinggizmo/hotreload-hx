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
	Js;       // A hot build (-D hotreload), which hotreload.DevServer serves and rebuilds.
	JsReload; // A reload's build (-D hotreload_reload), which the DevServer starts.
}
#end

/**
	Provides the build macro that makes a JS build hot.

	A build is hot with `--macro hotreload.Builder.init()` (which `-lib hotreload-hx` adds) and
	`-D hotreload`, on a JS target. Without the define the macro does nothing. The same sources
	then build one ordinary program, and the reload metadata is ignored.

	A hot build reloads whole. The page loads the new bundle beside the old one, and the
	reloader (Reloader, JsSwap) makes the new bundle's classes the current ones, objects
	included. Every static keeps its value, except one whose first value was edited (it starts
	over from the new value) and one marked `@:resetOnHotReload`.

	The macro adds each class's statics' types and first values, as written
	(`__hot_statics__`). It adds a guard that keeps a reloaded bundle's `main` from running
	again. It adds each class's field initializers, from which the new fields of an object a
	reload carries over start. It registers the reload hooks. It replaces `$bind` with one that
	follows a bound method to its new code, and does the same for a static function passed as a
	value. It also records, for the DevServer, how to build the bundle again.
**/
class Builder {
	#if macro
	static var mode = Off;
	static var mainClass:String;
	/** The project's own class paths, which hold its code and are watched. **/
	static var projectDirs:Array<String> = [];

	/** The class paths inside the project's directory excluded from it (its local repository's libraries). **/
	static var excludedDirs:Array<String> = [];

	/** The main class's file, found from the class paths. **/
	static var mainFile:String;

	static var configured = false;

	public static function init() {
		// Once per build, however many times the build names the library.
		if (Context.defined("hotreload_initialized"))
			return;
		Compiler.define("hotreload_initialized");
		// A compilation server keeps a macro's statics from one build to the next.
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
			// (An init macro's warning is not shown.)
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
		// A reload's swap fails on ES5 output ("newHooks.runAfter is not a function"). js-es
		// cannot be set from here, because the compiler has already read it (an ES5
		// constructor's `this` before `super()` would stay). The library's extraParams.hxml
		// sets it on the command line instead.
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
			// (A reload's build writes the config too when asked. The DevServer watches its class
			// paths, which an edited hxml changes.)
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
			// (The output's directory may not exist yet. The compiler creates it later.)
			if (!sys.FileSystem.exists(Path.directory(path)))
				sys.FileSystem.createDirectory(Path.directory(path));
			sys.io.File.saveContent(path, haxe.Json.stringify(config, "\t"));
		});
	}

	/**
		The `$bind` function of a hot JS build.

		It looks up the method each time it is called, so a bound method made before a reload
		runs the new code.
	**/
	static inline var LATE_BIND = "function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; "
		+ "if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { "
		+ "f = function() { var g = f.method; while( g.__hot_next__ != null ) g = f.method = g.__hot_next__; return g.apply(o,arguments); }; "
		+ "f.method = m; o.hx__closures__[m.__id__] = f; } return f; }";

	/**
		Replaces the output's `$bind` with one that follows a bound method to its newest code.

		A bound method (`addEventListener(CLICK, onClick)`) is Haxe's `$bind`, which binds the
		method as it is (`m.bind(o)`). One made before a reload would run the old code. The
		replacement follows the method through `__hot_next__`, which a swap sets (JsSwap). It
		stays on the original's single line, so no line moves for the source map. A bundle with
		no bound method has no `$bind`, and is left unchanged.
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
		Makes each static function passed as a value late-bound in the output.

		A static function passed as a value (`addEventListener("keydown", Game.onKey)`) is the
		function itself. One passed before a reload would run the old code. The new code's
		`Game.onKey` is another function, so removing it removes nothing. Each one that
		findStaticValues finds is replaced by a function that calls it (`__hot_impl__`). The
		replacement is added on its class's closing line, so no line moves for the source map.
		A swap keeps that function and points it to the new code (JsSwap). A function whose
		class is not in the output as Haxe writes it is reported as a warning.
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
		Finds the project's own class paths and the main class's file.

		The project's own class paths are those inside its directory. The standard library's
		and a haxelib's are not, and neither is a local repository's (`.haxelib/`), even though
		it is inside the directory. Without any, the main class's directory is used. The
		project's sources are watched.
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
		The static functions passed as values (`addEventListener("keydown", Game.onKey)`), by
		their classes' JS names.

		Each holds the position of its first use, reported when its class is not found in the
		output. findStaticValues fills it, and lateStatics makes each function late-bound.
	**/
	static var staticValues:Map<String, {cls:String, names:Map<String, Position>}>;

	/**
		Finds the static functions the code passes as values, anywhere but in the standard
		library and this one.

		lateStatics makes them late-bound. A method of an object passed as a value is Haxe's
		`$bind`, which lateBind makes late-bound.
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

	/** Returns whether a class belongs to the standard library or to this one, which are never reloaded. **/
	static function isLibraryOwn(c:ClassType):Bool {
		var file = fileOf(c.pos);
		return file == null || file.startsWith(stdDir()) || file.startsWith(ownDir());
	}

	/**
		Returns a class's name in the JS output, as Haxe's genjs writes it.

		The name is the class's flat path. An abstract's implementation takes the abstract's.
	**/
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

	/**
		Builds every class of a hot build (`@:build`).

		It adds the class's statics' types and first values, the reload hooks, and what an
		object carried across a reload needs.
	**/
	public static function build():Array<Field> {
		var ref = Context.getLocalClass();
		if (ref == null)
			return null;
		var cls = ref.get();
		return buildJs(cls, Context.getBuildFields(), fullName(cls.pack, cls.name));
	}

	/**
		Checks that the reload metadata is on a field it applies to.

		A hook (`@:beforeHotReload`, `@:afterHotReload`) must be a static function with no
		parameters. `@:resetOnHotReload` must be on a static var that holds a value. `@:hot`,
		which kept a static on the hxcpp branch, does nothing, since every static is kept. It is
		warned about where it is written.
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

	/** Returns a first value as written, shortened for a message (`3.0`, `"seven"`, `new Map()`). **/
	static function shortText(e:Expr):String {
		var text = ~/\s+/g.replace(e.toString(), " ");
		return text.length > 40 ? text.substr(0, 37) + "..." : text;
	}

	/** Adds a class's hooks, its main's guard, its field initializers, and its statics' types and first values. **/
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
			// A static's type and first value, as written, which a reload compares (JsSwap). A
			// static whose first value was edited starts over from the new one. A static whose
			// type changed keeps its value when the value is still the same kind. (A property
			// with no storage, `(get, never)`, holds no value, so there is nothing to keep.)
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
						// A reloaded bundle's classes replace the running ones. Its main must not
						// start the program a second time.
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
		Returns a JS class's field initializer function, for an object a reload carries over.

		Each field the object does not have (a new one) starts from its initializer.

		@return  The function, or null if no field has an initializer.
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
				// A final field cannot be assigned outside its constructor, but it can be set.
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
		Returns whether a var or property holds a value.

		A var holds one. A property holds one when either side is `default` or `null`, or when
		it has `@:isVar`. A property such as `(get, never)` or `(get, set)` holds none. Its value
		comes from its accessors.
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

	/** Returns the standard library's directory, which is never the project's. **/
	static function stdDir():String {
		if (std == null)
			// StdTypes.hx is only at the standard library's root. (Std.hx is overridden per target,
			// in cpp/_std/ and js/_std/.)
			std = Path.addTrailingSlash(Path.directory(Path.normalize(FileSystem.absolutePath(Context.resolvePath("StdTypes.hx")))));
		return std;
	}

	static var own:String;

	/**
		Returns this library's own class path (its src/), which is never the project's.

		Wherever the library is, the reloader's statics are not started over, and its code is
		not warned about.
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
	each method's closures, and each instance field's declared type. The hash of a closure, a main or a constructor leaves out the
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
			case FVar(t, e) | FProp(_, _, t, e) if (!isStatic && Builder.hasStorage(field)):
				var info = macro {init: $v{e == null ? "" : hash(e)}, type: $v{t == null ? "" : t.toString()}};
				fields.push({field: field.name, expr: info});
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

/** Represents how a JS hot build was made, for the DevServer to build it again. **/
typedef JsConfig = {
	/** Gets or sets the build's directory, which its paths are relative to. **/
	var cwd:String;

	/**
		Gets or sets the build's whole command line.

		A reload's build uses it, so it writes the same bundle.
	**/
	var args:Array<String>;

	/**
		Gets or sets the project's own class paths, which hold the sources.

		The DevServer watches them and everything below them.
	**/
	var dirs:Array<String>;

	/**
		Gets or sets the class paths inside the project's directory that are not its own (its
		local repository's libraries, in .haxelib/).
	**/
	var ?excluded:Array<String>;

	/** Gets or sets the path of the bundle. **/
	var js:String;

	var mainClass:String;
}

