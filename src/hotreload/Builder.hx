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
	Host;    // the executable's build: -D hotreload
	Library; // a reload's build, which the reloader starts: -D hotreload_library
	Js;       // a JS build: -D hotreload, which hotreload.DevServer serves and rebuilds
	JsReload; // a JS reload's build, which the DevServer starts: -D hotreload_reload
}
#end

/**
	What makes a build hot: `--macro hotreload.Builder.init()` (which `-lib hotreload-hx` adds)
	and `-D hotreload`. Without the define it does nothing, and the same sources build one
	ordinary program: `@:hot` and the reload hooks are ignored.

	In the executable's build (the host), it turns on what cppia needs (`-D scriptable`,
	`-dce no`, `-D dll_export`), finds the reloaded code, and writes down how to build it
	again (a resource the Reloader reads). The reloaded code is the classes in the
	directories of the classes with something hot in them, and below, but the main class.
	Their compiled copies in the executable are renamed (`_hot.Hello`), so that the cppia
	module's classes, under their own names, don't collide with them.

	In a reload's build (the library), the reloaded code is compiled to one cppia module,
	against the executable's classes (`-D dll_import`).

	A JS build reloads whole: the page loads the new bundle beside the old one, and the
	reloader (Reloader.js.hx) makes its classes the current ones, statics, objects and all.
	So `@:hot` means nothing there: every static and function reloads. What it takes from
	here: a guard that keeps a reloaded bundle's `main` from running again, each class's
	field initializers, for the objects a reload carries over (their new fields start
	from them), the reload hooks, and, for the DevServer, how to build it again.
**/
class Builder {
	/** what the executable's copy of a reloaded class is renamed to: `_hot.` and its path. A reload strips it again **/
	public static inline var HOST_PREFIX = "_hot.";

	#if macro
	static var mode = Off;
	static var mainClass:String;
	static var hotClasses:Array<{module:String, file:String}> = [];
	static var libraryDirs:Array<String> = [];
	static var libraryMain:String;
	static var configured = false;

	public static function init() {
		// once per build, however many times the build names the library
		if (Context.defined("hotreload_initialized"))
			return;
		Compiler.define("hotreload_initialized");
		// a compilation server keeps a macro's statics from one build to the next
		mode = Off;
		mainClass = null;
		hotClasses = [];
		libraryDirs = [];
		libraryMain = null;
		configured = false;
		std = null;
		if (Context.defined("hotreload_library")) {
			mode = Library;
			libraryDirs = Context.definedValue("hotreload_dirs").split("|");
			libraryMain = Context.definedValue("hotreload_main");
			Compiler.define("dce", "no");
			invalidate();
		} else if (Context.defined("hotreload") && Context.defined("js")) {
			mode = Context.defined("hotreload_reload") ? JsReload : Js;
			invalidate();
			initJs();
		} else if (Context.defined("hotreload")) {
			if (!Context.defined("cpp") || Context.defined("cppia")) {
				// (an init macro's warning isn't shown)
				Sys.stderr().writeString("hotreload: only a cpp or a JS build reloads; this one builds without it\n");
				Sys.stderr().flush();
				return;
			}
			mode = Host;
			initHost();
		} else {
			return;
		}
		Compiler.addGlobalMetadata("", "@:build(hotreload.Builder.build())", true, true, false);
	}

	static function initHost() {
		var args = Sys.args();
		if (args.contains("--next") || args.contains("--each"))
			Context.fatalError("hotreload: a hot build is one build: take --next and --each out of its hxml", Context.currentPos());
		var cppDir = null;
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "-main" | "--main" | "-m":
					mainClass = args[i + 1];
				case "-cpp" | "--cpp":
					cppDir = args[i + 1];
			}
			i++;
		}
		if (mainClass == null)
			Context.fatalError("hotreload: a hot build needs a main class (--main)", Context.currentPos());
		var cwd = Path.addTrailingSlash(Sys.getCwd());
		var buildDir = Path.normalize(Path.join([absolute(cwd, cppDir), "hotreload"]));
		if (!FileSystem.exists(buildDir))
			FileSystem.createDirectory(buildDir);

		// what cppia needs: the executable's classes whole (a reload may call what it never
		// did), reflection for them, and the list of them to compile against
		Compiler.define("scriptable");
		Compiler.define("dce", "no");
		Compiler.define("dll_export", buildDir + "/host.info");

		Context.onAfterTyping(types -> {
			if (configured)
				return;
			configured = true;
			configure(types, cwd, buildDir, libraryArgs(args));
		});
	}

	/**
		A compilation server notices a changed file by its time, in whole seconds, so it would
		miss a save in the same second as the last build's: the reloader writes the files
		that changed since the last build started to a file, which this names to the server.
		A file, not a define, since a define whose value changed each build would give the
		server a new context each time, and nothing cached
	**/
	static function invalidate() {
		if (!Context.defined("hotreload_invalidate"))
			return;
		var list = try sys.io.File.getContent(Context.definedValue("hotreload_invalidate")) catch (_) "";
		var files = [for (f in list.split("\n")) if (f != "") f];
		if (files.length > 0)
			try haxe.macro.CompilationServer.invalidateFiles(files) catch (_) {}
	}

	static function initJs() {
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
		if (mode == JsReload)
			return;
		if (args.contains("--next") || args.contains("--each"))
			Context.fatalError("hotreload: a hot build is one build: take --next and --each out of its hxml", Context.currentPos());
		var cwd = Path.addTrailingSlash(Sys.getCwd());
		var path = Context.defined("hotreload_config") ? Context.definedValue("hotreload_config") : absolute(cwd, js) + ".hotreload.json";
		Context.onAfterTyping(types -> {
			if (configured)
				return;
			configured = true;
			var mainFile = null;
			for (t in types)
				switch (t) {
					case TClassDecl(_.get() => c) if (fullName(c.pack, c.name) == mainClass):
						mainFile = fileOf(c.pos);
					default:
				}
			// the project's own class paths (inside its directory; not the standard library's or
			// a haxelib's), or else the main class's directory: watched, and below
			var dirs = [];
			var j = 0;
			while (j < args.length) {
				if ((args[j] == "-cp" || args[j] == "-p" || args[j] == "--class-path") && j + 1 < args.length) {
					var dir = Path.removeTrailingSlashes(Path.normalize(absolute(cwd, args[j + 1])));
					if (dir.startsWith(Path.removeTrailingSlashes(cwd)) && FileSystem.exists(dir) && !dirs.contains(dir))
						dirs.push(dir);
				}
				j++;
			}
			if (dirs.length == 0 && mainFile != null)
				dirs.push(Path.directory(mainFile));
			var config:JsConfig = {
				cwd: cwd,
				args: [for (a in args) a],
				dirs: dirs,
				js: Path.normalize(absolute(cwd, js)),
				mainClass: mainClass,
			};
			sys.io.File.saveContent(path, haxe.Json.stringify(config, "\t"));
		});
	}

	/** the executable's command line, for a reload's build: what it compiles and how, but not where to or what runs **/
	static function libraryArgs(args:Array<String>):Array<String> {
		var withValue = [
			"-main", "--main", "-m", "-cpp", "--cpp", "-js", "--js", "-hl", "--hl", "-neko", "--neko", "-lua", "--lua", "-python", "--python",
			"-php", "--php", "-jvm", "--jvm", "-java", "--java", "-cs", "--cs", "-swf", "--swf", "--cppia", "-x", "-cmd", "--cmd", "-dce", "--dce"
		];
		var result = [];
		var i = 0;
		while (i < args.length) {
			var arg = args[i];
			if (withValue.contains(arg)) {
				i += 2;
				continue;
			}
			if (arg == "--interp") {
				i++;
				continue;
			}
			if ((arg == "-D" || arg == "--define") && i + 1 < args.length && args[i + 1].startsWith("dll_export")) {
				i += 2;
				continue;
			}
			result.push(arg);
			i++;
		}
		return result;
	}

	static function configure(types:Array<ModuleType>, cwd:String, buildDir:String, args:Array<String>) {
		var mainFile = null;
		for (t in types)
			switch (t) {
				case TClassDecl(_.get() => c) if (fullName(c.pack, c.name) == mainClass):
					mainFile = fileOf(c.pos);
				default:
			}

		// the directories of the classes with something hot in them, each once, and none
		// inside another
		var dirs = [];
		for (h in hotClasses) {
			var dir = Path.directory(h.file);
			if (!dirs.contains(dir))
				dirs.push(dir);
		}
		dirs = dirs.filter(d -> !dirs.exists(other -> other != d && d.startsWith(other + "/")));

		// the executable's copies of the reloaded classes, renamed out of the modules' way
		for (t in types) {
			var base:BaseType = switch (t) {
				case TClassDecl(c): c.get();
				case TEnumDecl(e): e.get();
				default: null;
			}
			if (base == null || base.isExtern)
				continue;
			var file = fileOf(base.pos);
			if (file == mainFile || !inside(file, dirs))
				continue;
			if (base.meta.has(":native")) {
				Context.warning('hotreload: ${fullName(base.pack, base.name)} has @:native, so it can\'t be reloaded', base.pos);
				continue;
			}
			base.meta.add(":native", [macro $v{HOST_PREFIX + fullName(base.pack, base.name)}], base.pos);
		}

		var roots = [];
		for (h in hotClasses)
			if (!roots.contains(h.module))
				roots.push(h.module);

		var config:Config = {
			cwd: cwd,
			args: args,
			roots: roots,
			dirs: dirs,
			mainFile: mainFile,
			mainClass: mainClass,
			buildDir: buildDir,
			debug: Context.defined("debug"),
			compilationServer: Context.defined("hotreload_no_compilation_server") ? "off" : Context.defined("hotreload_compilation_server") ? Context.definedValue("hotreload_compilation_server") : null,
		};
		Context.addResource("hotreload.config", haxe.io.Bytes.ofString(haxe.Json.stringify(config)));
	}

	/**
		`@:build` on every class of a hot build: `@:hot` statics and functions, and the
		reload hooks, and in a reload's build, what a migrated object needs
	**/
	public static function build():Array<Field> {
		var ref = Context.getLocalClass();
		if (ref == null)
			return null;
		var cls = ref.get();
		var fields = Context.getBuildFields();
		var className = fullName(cls.pack, cls.name);
		if (mode == Js || mode == JsReload)
			return buildJs(cls, fields, className);
		var changed = false;
		var hasHot = false;
		var result = [];
		var extra = [];

		for (field in fields) {
			var hot = field.meta.exists(m -> m.name == ":hot");
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			if (!hot && hook == null) {
				result.push(field);
				continue;
			}
			if (mode == Host && isMain(cls))
				Context.error("@:hot and the reload hooks can't be used in the main class because the main class is never reloaded. "
					+ "Use them in the reloaded classes (for the main class's own, set reloader.beforeReload and reloader.afterReload)", field.pos);
			if (!field.access.contains(AStatic))
				Context.error("@:hot and the reload hooks are for statics: an instance is carried across a reload with its fields", field.pos);
			changed = true;
			hasHot = true;
			if (hook != null) {
				var fn = switch (field.kind) {
					case FFun(f): f;
					default: Context.error('@${hook.name}: a static function', field.pos);
				}
				if (fn.args.length > 0)
					Context.error('@${hook.name}: a function with no parameters', field.pos);
				result.push(field);
				var after = hook.name == ":afterHotReload";
				var name = field.name;
				extra.push(staticVar('__hot_hook_$name', macro:Bool, macro hotreload.Hooks.add($v{after}, $i{name}), field.pos));
				continue;
			}
			switch (field.kind) {
				case FVar(t, e):
					hotVar(className, field, t, e, result, extra);
				case FFun(f):
					hotFunction(className, field, f, result, extra);
				case FProp(_, _, _, _):
					Context.error("@:hot: a static var or function, not a property", field.pos);
			}
		}

		if (mode == Host && !cls.isExtern) {
			for (field in result)
				if (externNative(field))
					changed = true;
		}

		if (mode == Library && !cls.isInterface && !cls.isExtern && fileOf(cls.pos) != null) {
			var file = fileOf(cls.pos);
			// (an abstract's fields aren't an object's: no initializers for them)
			if (inside(file, libraryDirs) && className != libraryMain && !cls.kind.match(KAbstractImpl(_))) {
				var init = fieldInitializer(className, fields);
				if (init != null) {
					extra.push(init);
					changed = true;
				}
			} else if (!inside(file, libraryDirs) && !file.startsWith(stdDir())) {
				for (field in result)
					if (callHost(cls, field))
						changed = true;
			}
		}

		if (!changed)
			return null;
		if (mode == Host && hasHot && !hotClasses.exists(h -> h.module == Context.getLocalModule()))
			hotClasses.push({module: Context.getLocalModule(), file: fileOf(cls.pos)});
		return result.concat(extra);
	}

	/**
		`@:hot static var x:T = first`: a property whose storage is a Slot the executable
		keeps, by the class and name, which every module that loads is handed. Its first
		value is used once, when the slot is made
	**/
	static function hotVar(className:String, field:Field, t:ComplexType, e:Expr, result:Array<Field>, extra:Array<Field>) {
		var sig = null;
		if (t == null) {
			if (e == null)
				Context.error("@:hot: give it a type, or a first value", field.pos);
			var type = try Context.typeof(e) catch (_) null;
			if (type == null)
				Context.error("@:hot: give it a type (its first value's can't be found here)", field.pos);
			t = Context.toComplexType(type);
			sig = type.toString();
		} else {
			sig = try Context.resolveType(t, field.pos).toString() catch (_) t.toString();
		}
		var name = field.name;
		var slot = '__hot_$name';
		var key = className + "." + name;
		var first = e == null ? macro null : macro(($e : $t) : Dynamic);
		result.push({
			name: name,
			access: field.access.filter(a -> a != AFinal),
			kind: FProp("get", "set", t, null),
			pos: field.pos,
			doc: field.doc,
			meta: field.meta.filter(m -> m.name != ":hot"),
		});
		result.push(staticVar(slot, macro:hotreload.Slot, macro hotreload.Slots.get($v{key}, $v{sig}, () -> $first), field.pos));
		extra.push({
			name: 'get_$name',
			access: [AStatic, AInline, APrivate],
			meta: [{name: ":noCompletion", pos: field.pos}],
			kind: FFun({args: [], ret: t, expr: macro return $i{slot}.value}),
			pos: field.pos,
		});
		extra.push({
			name: 'set_$name',
			access: [AStatic, AInline, APrivate],
			meta: [{name: ":noCompletion", pos: field.pos}],
			kind: FFun({args: [{name: "v", type: t}], ret: t, expr: macro {
				$i{slot}.value = v;
				return v;
			}}),
			pos: field.pos,
		});
	}

	/**
		`@:hot static function f()`: a function the main class calls. In the executable, `f`
		calls through a variable that each reload points at the new module's `f`; the module
		has `f` as it is, and its signature, which the reloader checks first
	**/
	static function hotFunction(className:String, field:Field, f:Function, result:Array<Field>, extra:Array<Field>) {
		var name = field.name;
		if (f.params != null && f.params.length > 0)
			Context.error("@:hot: not a generic function", field.pos);
		var argTypes = [];
		for (a in f.args) {
			var t = a.type;
			if (t == null && a.value != null)
				t = try Context.toComplexType(Context.typeof(a.value)) catch (_) null;
			if (t == null)
				Context.error('@:hot: give ${a.name} a type: a reload checks it hasn\'t changed', field.pos);
			if (t.match(TPath({name: "Rest", pack: ["haxe"] | []})))
				Context.error("@:hot: not a function with rest arguments", field.pos);
			argTypes.push((a.opt ? "?" : "") + t.toString());
		}
		var ret = f.ret;
		if (ret == null) {
			if (returnsValue(f.expr))
				Context.error("@:hot: give it a return type: a reload checks it hasn't changed", field.pos);
			ret = macro:Void;
		}
		var sig = "(" + argTypes.join(", ") + ") -> " + ret.toString();
		extra.push({
			name: '__hot_sig_$name',
			access: [AStatic, APublic],
			meta: [{name: ":keep", pos: field.pos}, {name: ":noCompletion", pos: field.pos}],
			kind: FFun({args: [], ret: macro:String, expr: macro return $v{sig}}),
			pos: field.pos,
		});

		if (mode == Library) {
			result.push(field);
			return;
		}

		// the executable: the stub, by the function's name, the code it starts with, and
		// the variable between them
		var impl = '__hot_impl_$name';
		var target = '__hot_fn_$name';
		result.push({
			name: impl,
			access: [AStatic, APrivate],
			kind: FFun({args: f.args, ret: ret, expr: f.expr}),
			pos: field.pos,
		});
		result.push(staticVar(target, macro:Dynamic, macro $i{impl}, field.pos));
		var callArgs = [for (a in f.args) macro $i{a.name}];
		var call = macro $i{target}($a{callArgs});
		var body = ret.match(TPath({name: "Void", pack: []})) ? macro $call : macro return $call;
		result.push({
			name: name,
			access: field.access,
			doc: field.doc,
			meta: field.meta.filter(m -> m.name != ":hot"),
			kind: FFun({args: [for (a in f.args) {name: a.name, opt: a.opt, type: a.type, value: a.value}], ret: ret, expr: body}),
			pos: field.pos,
		});
		extra.push(staticVar('__hot_reg_$name', macro:Bool, macro hotreload.Hooks.proc($v{className}, $v{name}, $v{sig}, fn -> $i{target} = fn),
			field.pos));
	}

	/** a JS build's class: its hooks, its main's guard, its field initializers, and its statics' types **/
	static function buildJs(cls:ClassType, fields:Array<Field>, className:String):Array<Field> {
		var changed = false;
		var result = [];
		var extra = [];
		var types = [];
		for (field in fields) {
			// a static's type, as written (or its first value's): a reload that changes it
			// starts the static over, rather than carry a value of the old type into it
			if (field.access.contains(AStatic))
				switch (field.kind) {
					case FVar(t, e) | FProp(_, _, t, e):
						var sig = if (t != null) t.toString() else if (e != null) try Context.typeof(e).toString() catch (_) null else null;
						if (sig != null)
							types.push({field: field.name, expr: macro $v{sig}});
					default:
				}
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			if (hook != null) {
				var fn = switch (field.kind) {
					case FFun(f) if (field.access.contains(AStatic)): f;
					default: Context.error('@${hook.name}: a static function', field.pos);
				}
				if (fn.args.length > 0)
					Context.error('@${hook.name}: a function with no parameters', field.pos);
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
				inits.push(macro if (!std.Reflect.hasField(this, $v{name})) this.$name = $e);
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
		A reloaded class's field initializers, for an object a reload carries over: its new
		fields start from their initializers, as a new object's would
	**/
	static function fieldInitializer(className:String, fields:Array<Field>):Field {
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
				inits.push(macro if (!copied.contains($v{name})) this.$name = $e);
			}
		}
		if (inits.length == 0)
			return null;
		return {
			name: "__hot_init_" + className.replace(".", "_"),
			access: [APublic],
			meta: [{name: ":keep", pos: Context.currentPos()}, {name: ":noCompletion", pos: Context.currentPos()}],
			kind: FFun({args: [{name: "copied", type: macro:Array<String>}], ret: macro:Void, expr: macro $b{inits}}),
			pos: Context.currentPos(),
		};
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

	/** whether a function's body returns a value (not counting the functions inside it) **/
	static function returnsValue(e:Expr):Bool {
		var found = false;
		function visit(e:Expr) {
			if (found || e == null)
				return;
			switch (e.expr) {
				case EReturn(v) if (v != null):
					found = true;
				case EFunction(_, _):
				default:
					e.iter(visit);
			}
		}
		visit(e);
		return found;
	}

	/**
		`-D scriptable` gives every function of the executable a wrapper cppia calls it
		through, with its arguments and result as Dynamic, which a C pointer, struct, enum
		or function pointer can't be: the C++ doesn't compile (and Haxe ignores
		`@:unreflective` on a static for this). Such a function is a native binding's
		plumbing, which cppia could never call: an inline one is made `extern inline`,
		which has no compiled body, and so no wrapper. A non-inline one has to be in a
		private class, which gets no wrappers; that's the library's to do
	**/
	static function externNative(field:Field):Bool {
		if (!field.access.contains(AInline) || field.access.contains(AExtern) || field.access.contains(AMacro))
			return false;
		var f = switch (field.kind) {
			case FFun(f): f;
			default: return false;
		}
		if (!hasNativeType(f, field.pos))
			return false;
		field.access.push(AExtern);
		return true;
	}

	/** whether a function's parameters or result have a type that can't be Dynamic, as far as they're written out **/
	static function hasNativeType(f:Function, pos:Position):Bool {
		var types = f.args.map(a -> a.type);
		types.push(f.ret);
		for (t in types) {
			if (t == null)
				continue;
			var type = try Context.resolveType(t, pos) catch (_) null;
			if (type != null && isNative(type))
				return true;
		}
		return false;
	}

	/** whether a type can't be Dynamic: a C pointer, struct, enum or function pointer **/
	static function isNative(t:Type):Bool {
		var followed = Context.follow(t);
		return switch (followed) {
			case TInst(_.get() => c, _): c.isExtern && (c.meta.has(":unreflective") || c.meta.has(":structAccess"));
			case TAbstract(_.get() => a, _):
				if (a.meta.has(":callable"))
					true;
				else if (a.meta.has(":coreType"))
					false;
				else
					switch (Context.followWithAbstracts(followed, true)) {
						case TAbstract(_.get() => b, _) if (b.name == a.name && b.pack.join(".") == a.pack.join(".")): false;
						case underlying: isNative(underlying);
					}
			default: false;
		}
	}

	/**
		In a reload's build, a library's inline function is made a call to the executable's
		compiled copy instead, since its body, inlined into the module, may be what cppia
		can't run: a call to an extern, or C++ (a native binding's wrappers are all of
		that). What has to stay inline stays: an `extern inline` function (an overload,
		say; it has no compiled copy, so its body is inlined, and if cppia can't run it,
		the reload fails to load), a native one (the same), an abstract's constructor (an
		`inline var` may be made with it), and a function that assigns the abstract's `this`
	**/
	static function callHost(cls:ClassType, field:Field):Bool {
		if (!field.access.contains(AInline) || field.access.contains(AExtern) || field.access.contains(AMacro))
			return false;
		var f = switch (field.kind) {
			case FFun(f): f;
			default: return false;
		}
		if (f.expr == null)
			return false;
		var isAbstract = cls.kind.match(KAbstractImpl(_));
		if (isAbstract && (field.name == "new" || assignsThis(f.expr)))
			return false;
		// a native one has no compiled copy in the executable (see externNative), and
		// its body can't be compiled here either
		if (hasNativeType(f, field.pos)) {
			field.access.push(AExtern);
			return true;
		}
		field.access.remove(AInline);
		return true;
	}

	static function assignsThis(e:Expr):Bool {
		var found = false;
		function walk(e:Expr) {
			if (found || e == null)
				return;
			switch (e.expr) {
				case EBinop(OpAssign | OpAssignOp(_), {expr: EConst(CIdent("this"))}, _):
					found = true;
				case EUnop(OpIncrement | OpDecrement, _, {expr: EConst(CIdent("this"))}):
					found = true;
				default:
					haxe.macro.ExprTools.iter(e, walk);
			}
		}
		walk(e);
		return found;
	}

	static var std:String;

	/** the standard library's directory, whose inline functions are left alone **/
	static function stdDir():String {
		if (std == null)
			// StdTypes.hx is only at the standard library's root (Std.hx is overridden per target, in cpp/_std/, js/_std/)
			std = Path.addTrailingSlash(Path.directory(Path.normalize(FileSystem.absolutePath(Context.resolvePath("StdTypes.hx")))));
		return std;
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

	/** the bundle **/
	var js:String;

	var mainClass:String;
}

/** how the executable's build was made, for the Reloader to build the reloaded code again **/
typedef Config = {
	/** the build's directory, which its paths are from **/
	var cwd:String;

	/** its command line, but its target and main class **/
	var args:Array<String>;

	/** the modules with something hot in them: a reload's build compiles them, and what they use **/
	var roots:Array<String>;

	/** where the reloaded code is: watched, and below **/
	var dirs:Array<String>;

	/** the main class's file, which isn't watched **/
	var mainFile:String;

	var mainClass:String;

	/** where the modules go **/
	var buildDir:String;

	var debug:Bool;

	/**
		the compilation server the builds connect to: null to start one
		(`haxe --wait`), a port (or host:port) to use one that's running
		(-D hotreload_compilation_server=<port>), or "off" for none
		(-D hotreload_no_compilation_server)
	**/
	var compilationServer:Null<String>;
}
