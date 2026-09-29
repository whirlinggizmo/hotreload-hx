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
		// a compilation server keeps a macro's statics from one build to the next
		mode = Off;
		mainClass = null;
		hotClasses = [];
		libraryDirs = [];
		libraryMain = null;
		configured = false;
		if (Context.defined("hotreload_library")) {
			mode = Library;
			libraryDirs = Context.definedValue("hotreload_dirs").split("|");
			libraryMain = Context.definedValue("hotreload_main");
			Compiler.define("dce", "no");
			// a compilation server notices a changed file by its time, in whole seconds, so
			// it would miss a save in the same second as the last build's: the reloader
			// names the files that changed since the last build started
			if (Context.defined("hotreload_invalidate"))
				try haxe.macro.CompilationServer.invalidateFiles(Context.definedValue("hotreload_invalidate").split("|")) catch (_) {}
		} else if (Context.defined("hotreload")) {
			if (!Context.defined("cpp") || Context.defined("cppia")) {
				// (an init macro's warning isn't shown)
				Sys.stderr().writeString("hotreload: only a cpp build reloads for now; this one builds without it\n");
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

		if (mode == Library && !cls.isInterface && !cls.isExtern && fileOf(cls.pos) != null) {
			var file = fileOf(cls.pos);
			if (inside(file, libraryDirs) && className != libraryMain) {
				var init = fieldInitializer(className, fields);
				if (init != null) {
					extra.push(init);
					changed = true;
				}
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
