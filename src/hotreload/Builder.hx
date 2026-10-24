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
	module's classes, under their own names, don't collide with them. The project's other
	classes, outside the reloaded code, get a function that starts their plain statics over
	(`__hot_reset__`), which a reload calls: so a plain static of the project's starts over
	on every reload, wherever it is, as it does on JS.

	In a reload's build (the library), the reloaded code is compiled to one cppia module,
	against the executable's classes (`-D dll_import`).

	A JS build reloads whole: the page loads the new bundle beside the old one, and the
	reloader (Reloader.js.hx) makes its classes the current ones, objects and all. Its
	statics follow the same rule as native: of the project's classes, only the `@:hot`
	statics are carried over, and the rest start over; the main class's, the standard
	library's and a haxelib's are all kept, as they are natively, where they're never
	reloaded. What it takes from here: the project's classes and their `@:hot` statics (a
	resource), a guard that keeps a reloaded bundle's `main` from running again, each
	class's field initializers, for the objects a reload carries over (their new fields
	start from them), the reload hooks, and, for the DevServer, how to build it again.
**/
class Builder {
	/** what the executable's copy of a reloaded class is renamed to: `_hot.` and its path. A reload strips it again **/
	public static inline var HOST_PREFIX = "_hot.";

	/** a typed expression's type, as a string: a JS class's `__hot_types__` for a static with no type written **/
	public static macro function typeName(e:haxe.macro.Expr):haxe.macro.Expr {
		return macro $v{haxe.macro.Context.typeof(e).toString()};
	}

	#if macro
	static var mode = Off;
	static var mainClass:String;
	static var hotClasses:Array<{module:String, file:String}> = [];

	/** the project's own class paths: its code, whose plain statics start over on a reload, on both targets **/
	static var projectDirs:Array<String> = [];

	/** the main class's file, found from the class paths: never reloaded code **/
	static var mainFile:String;

	static var libraryDirs:Array<String> = [];
	static var libraryMain:String;
	static var configured = false;

	/**
		the calls the main class makes, as written (`game.Game.init`, `Game.update`): the
		static functions of your code among them are marked `@:hot` by the build, since the
		main class is what calls them after a reload. Read off the main class's fields as
		it's built, which is before any class it calls is
	**/
	static var mainCalls = new Map<String, Bool>();

	/**
		whether the main class was built in this compilation. A compilation server keeps it
		typed when neither it nor anything it calls changed, and then its build, and the
		reading of its calls, doesn't run: nothing it calls was built either, so there's
		nothing to mark or check
	**/
	static var mainBuilt = false;

	/** the functions marked that way, `game.Game.update`: told to a reload's build, which marks the same **/
	static var entries:Array<String> = [];

	public static function init() {
		// once per build, however many times the build names the library
		if (Context.defined("hotreload_initialized"))
			return;
		Compiler.define("hotreload_initialized");
		// a compilation server keeps a macro's statics from one build to the next
		mode = Off;
		mainClass = null;
		hotClasses = [];
		projectDirs = [];
		mainFile = null;
		libraryDirs = [];
		libraryMain = null;
		configured = false;
		mainCalls = new Map();
		mainBuilt = false;
		entries = [];
		std = null;
		own = null;
		if (Context.defined("hotreload_library")) {
			mode = Library;
			libraryDirs = Context.definedValue("hotreload_dirs").split("|");
			libraryMain = Context.definedValue("hotreload_main");
			if (Context.defined("hotreload_entries"))
				entries = Context.definedValue("hotreload_entries").split("|");
			Compiler.define("dce", "no");
			invalidate();
			Context.onAfterTyping(warnMethodValues);
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
		findProject(args, cwd);
		var buildDir = Path.normalize(Path.join([absolute(cwd, cppDir), "hotreload"]));
		if (!FileSystem.exists(buildDir))
			FileSystem.createDirectory(buildDir);

		// what cppia needs: the executable's classes whole (a reload may call what it never
		// did), reflection for them, and the list of them to compile against
		Compiler.define("scriptable");
		Compiler.define("dce", "no");
		Compiler.define("dll_export", buildDir + "/host.info");

		Context.onAfterTyping(types -> {
			warnMethodValues(types);
			checkMainCalls(types);
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
		Context.onAfterTyping(types -> {
			warnMethodValues(types);
			checkMainCalls(types);
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
				js: Path.normalize(absolute(cwd, js)),
				mainClass: mainClass,
			};
			// (the output's directory may not be there yet: the compiler makes it later)
			if (!sys.FileSystem.exists(Path.directory(path)))
				sys.FileSystem.createDirectory(Path.directory(path));
			sys.io.File.saveContent(path, haxe.Json.stringify(config, "\t"));
		});
	}

	/**
		The project: its own class paths (inside its directory; not the standard library's
		or a haxelib's), or else the main class's directory, and the main class's file. Its
		classes' plain statics start over on a reload; its sources are watched
	**/
	static function findProject(args:Array<String>, cwd:String) {
		mainFile = try Path.normalize(FileSystem.absolutePath(Context.resolvePath(mainClass.replace(".", "/") + ".hx"))) catch (_) null;
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
		projectDirs = dirs;
	}

	/** whether a class is the project's own code, but the main class: one whose plain statics start over on a reload **/
	static function isProject(c:ClassType):Bool {
		if (c.isExtern || c.isInterface || c.kind.match(KAbstractImpl(_)))
			return false;
		var file = fileOf(c.pos);
		return file != null && file != mainFile && inside(file, projectDirs) && !file.startsWith(stdDir()) && !file.startsWith(ownDir());
	}

	/** a class of your code, in whichever build: in a reload's build, the project's class paths aren't known, and the reloaded code stands in **/
	static function isYours(c:ClassType):Bool {
		if (mode != Library)
			return isProject(c);
		if (c.isExtern || c.isInterface || c.kind.match(KAbstractImpl(_)))
			return false;
		var file = fileOf(c.pos);
		return file != null && inside(file, libraryDirs) && fullName(c.pack, c.name) != libraryMain;
	}

	/**
		A method of your code passed as a value, `load(path, place)`, is a bound method or
		a static's closure, which no reload can re-point: it runs its old code, on both
		targets. A lambda that calls the method by name, `x -> place(x)`, reaches the new
		code (natively, through a `@:hot` function). Told, at each use, in every hot build,
		in your code and in the main class
	**/
	static function warnMethodValues(types:Array<ModuleType>) {
		for (t in types)
			switch (t) {
				// (the main class's too: `reloader.assetsChanged = Game.assetsChanged` is as stuck)
				case TClassDecl(_.get() => c) if (isYours(c) || fullName(c.pack, c.name) == mainClass):
					var fields = c.statics.get().concat(c.fields.get());
					if (c.constructor != null)
						fields.push(c.constructor.get());
					for (f in fields) {
						// this macro's own, but a `@:hot` function's body (`__hot_impl_f`): a
						// hook handed to the reloader, and the variable a stub calls through
						if (f.name.startsWith("__hot_") && !f.name.startsWith("__hot_impl_"))
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
						case FStatic(c, cf) | FInstance(c, _, cf) | FClosure({c: c}, cf) if (isYours(c.get())): cf.get();
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

	/** the main class's calls, as written: `a.b.c(...)` is "a.b.c" **/
	static function collectCalls(fields:Array<Field>) {
		mainBuilt = true;
		function walk(e:Expr) {
			switch (e.expr) {
				case ECall({expr: EField(target, name)}, _):
					var path = dotted(target);
					if (path != null)
						mainCalls.set(path + "." + name, true);
				default:
			}
			e.iter(walk);
		}
		for (f in fields)
			switch (f.kind) {
				case FFun(fn) if (fn.expr != null): walk(fn.expr);
				case FVar(_, e) | FProp(_, _, _, e) if (e != null): walk(e);
				default:
			}
	}

	static function dotted(e:Expr):Null<String> {
		return switch (e.expr) {
			case EConst(CIdent(s)): s;
			case EField(sub, name):
				var p = dotted(sub);
				p == null ? null : p + "." + name;
			default: null;
		}
	}

	/**
		A static function of your code that the main class calls (by the class's full name
		or its own; a call through an alias isn't seen, and checkMainCalls says so). In a
		reload's build, the ones the executable's build marked
	**/
	static function isEntry(cls:ClassType, className:String, field:Field):Bool {
		if (!field.access.contains(AStatic) || field.access.contains(AInline) || !field.kind.match(FFun(_)) || field.name == "main")
			return false;
		var full = className + "." + field.name;
		return switch (mode) {
			case Host: isProject(cls) && (mainCalls.exists(full) || mainCalls.exists(cls.name + "." + field.name));
			case Library: entries.contains(full);
			default: false;
		}
	}

	/** whether a `@:hot` was the build's own (isEntry), for the messages **/
	static function isAuto(field:Field):Bool {
		var hot = field.meta.find(m -> m.name == ":hot");
		return hot != null && hot.params != null && hot.params.length > 0;
	}

	/**
		The main class's calls into your code, typed: each is to a `@:hot` function, the
		build's own mark or the code's, or a native reload won't reach it, which is told.
		(Natively, the ones marked have a `__hot_sig_`; on JS, the metadata)
	**/
	static function checkMainCalls(types:Array<ModuleType>) {
		if (!mainBuilt)
			return;
		for (t in types)
			switch (t) {
				case TClassDecl(_.get() => c) if (fullName(c.pack, c.name) == mainClass):
					for (f in c.statics.get().concat(c.fields.get())) {
						var e = f.expr();
						if (e != null)
							mainCallsIn(e);
					}
				default:
			}
	}

	static function mainCallsIn(e:TypedExpr) {
		switch (e.expr) {
			case TCall({expr: TField(_, FStatic(cref, cfref))}, _):
				var c = cref.get();
				var cf = cfref.get();
				if (isProject(c) && cf.kind.match(FMethod(MethNormal))) {
					var full = fullName(c.pack, c.name) + "." + cf.name;
					var marked = cf.meta.has(":hot") || mainCalls.exists(full) || mainCalls.exists(c.name + "." + cf.name)
						|| c.statics.get().exists(s -> s.name == "__hot_sig_" + cf.name);
					if (!marked)
						Context.warning('hotreload: the main class calls ${c.name}.${cf.name} in a way the build can\'t see (through an alias?), so it isn\'t @:hot: '
							+ "mark it yourself, or a native reload won't reach it", e.pos);
				}
			default:
		}
		e.iter(mainCallsIn);
	}

	/** the directories of the classes with something hot in them: the reloaded code, natively; each once, and none inside another **/
	static function hotDirs():Array<String> {
		var dirs = [];
		for (h in hotClasses) {
			var dir = Path.directory(h.file);
			if (!dirs.contains(dir))
				dirs.push(dir);
		}
		return dirs.filter(d -> !dirs.exists(other -> other != d && d.startsWith(other + "/")));
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
		var dirs = hotDirs();

		// the executable's copies of the reloaded classes, renamed out of the modules' way,
		// and the project's other classes, whose plain statics a reload starts over
		var resetClasses = [];
		for (t in types) {
			switch (t) {
				case TClassDecl(_.get() => c) if (isProject(c) && !inside(fileOf(c.pos), dirs)):
					resetClasses.push(fullName(c.pack, c.name));
				default:
			}
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
			sourceDirs: projectDirs,
			resetClasses: resetClasses,
			entries: entries,
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
		if (isMain(cls))
			collectCalls(fields);
		if (mode == Js || mode == JsReload)
			return buildJs(cls, fields, className);
		var changed = false;
		var hasHot = false;
		var result = [];
		var extra = [];

		for (field in fields) {
			var hot = field.meta.exists(m -> m.name == ":hot");
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			if (!hot && hook == null && isEntry(cls, className, field)) {
				// a static function the main class calls: `@:hot`, as if written, and said so
				field.meta.push({name: ":hot", params: [macro "main"], pos: field.pos});
				hot = true;
				if (mode == Host)
					entries.push(className + "." + field.name);
			}
			if (!hot && hook == null) {
				result.push(field);
				continue;
			}
			checkHot(cls, field, hook);
			changed = true;
			hasHot = true;
			if (hook != null) {
				result.push(field);
				var after = hook.name == ":afterHotReload";
				var name = field.name;
				extra.push(staticVar('__hot_hook_$name', macro:Bool, macro hotreload.Hooks.add($v{after}, $i{name}), field.pos));
				continue;
			}
			switch (field.kind) {
				case FVar(t, e) | FProp("default", _, t, e):
					hotVar(className, field, t, e, result, extra);
				case FFun(f):
					hotFunction(className, field, f, result, extra);
				case FProp(_, _, _, _):
			}
		}

		if (mode == Host && !cls.isExtern) {
			for (field in result)
				if (externNative(field))
					changed = true;
			if (isProject(cls)) {
				var reset = staticReset(cls, fields);
				if (reset != null) {
					extra.push(reset);
					changed = true;
				}
			}
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
		What `@:hot` and the reload hooks can be on, the same for both targets: a static
		var or function of a class other than the main class (which a native build never
		reloads); a hook, a static function with no parameters; a `@:hot` var, one with a
		type or a first value (its type, which a reload compares)
	**/
	static function checkHot(cls:ClassType, field:Field, hook:MetadataEntry) {
		if (isMain(cls))
			Context.error("@:hot and the reload hooks can't be used in the main class because the main class is never reloaded. "
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
			// (a native hot build gives it accessors, which can't keep others from writing it:
			// every other build of the same code compiles it as written, and says so)
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
			Context.error("@:hot: give it a type (its first value doesn't say it: a literal, `new T()` or a cast would)", field.pos);
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

	/**
		`@:hot static var x:T = first`: a property whose storage is a Slot the executable
		keeps, by the class and name, which every module that loads is handed. Its first
		value is used once, when the slot is made
	**/
	static function hotVar(className:String, field:Field, t:ComplexType, e:Expr, result:Array<Field>, extra:Array<Field>) {
		var typed = hotType(field, t, e);
		t = typed.t;
		var sig = typed.sig;
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
		`@:hot static function f()`: a function the main class calls, or a callback made
		before a reload. Wherever `f` is compiled, in the executable or in a module, `f`
		calls through a variable that each reload points at the new module's `__hot_impl_f`,
		the function as written: so a call to `f` from any code, however old, reaches the
		newest. The class registers the variable (Hooks.proc) as it starts; the module has
		`f`'s signature too, which the reloader checks first
	**/
	static function hotFunction(className:String, field:Field, f:Function, result:Array<Field>, extra:Array<Field>) {
		var name = field.name;
		// (the main class calls it, so a reload checks its signature, as for one marked by hand)
		var why = isAuto(field) ? '$name is called by the main class, so it\'s @:hot: ' : "@:hot: ";
		if (f.params != null && f.params.length > 0)
			Context.error(why + "not a generic function", field.pos);
		var argTypes = [];
		for (a in f.args) {
			var t = a.type;
			if (t == null)
				t = writtenType(a.value);
			if (t == null)
				Context.error(why + 'give ${a.name} a type: a reload checks it hasn\'t changed', field.pos);
			if (t.match(TPath({name: "Rest", pack: ["haxe"] | []})))
				Context.error(why + "not a function with rest arguments", field.pos);
			argTypes.push((a.opt ? "?" : "") + t.toString());
		}
		var ret = f.ret;
		if (ret == null) {
			if (returnsValue(f.expr))
				Context.error(why + "give it a return type: a reload checks it hasn't changed", field.pos);
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

		// the stub, by the function's name, the code it starts with, and the variable
		// between them
		var impl = '__hot_impl_$name';
		var target = '__hot_fn_$name';
		result.push({
			name: impl,
			access: [AStatic, APublic],
			meta: [{name: ":noCompletion", pos: field.pos}],
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
			var hot = field.meta.exists(m -> m.name == ":hot");
			var hook = field.meta.find(m -> m.name == ":beforeHotReload" || m.name == ":afterHotReload");
			if (hot || hook != null)
				checkHot(cls, field, hook);
			// a static's type, as written (or its first value's): a reload that changes it
			// carries the value over only when it's still the same kind (Slot.sameKind). A
			// `@:hot` one's as the native build has it, so the two say the same
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
						// a plain static with no first value: 0 or false for a number or a bool, as
						// natively (JS wouldn't emit it, and a reload would leave it undefined; a null
						// one is left out either way, and the swap gives it null)
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
				// a final field can't be assigned past its constructor, but can be set
				var set = f.access.contains(AFinal) ? macro std.Reflect.setField(this, $v{name}, $e) : macro this.$name = $e;
				inits.push(macro if (!copied.contains($v{name})) $set);
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

	/**
		`__hot_reset__`: starts a class's plain statics over, from their first values (or
		their types' defaults), for a reload to call on a class of the project's that isn't
		in the cppia module (Reloader): so a plain static starts over on every reload
		wherever it is, as on JS, where the new bundle makes them again. A `@:hot` static is
		left alone (its Slot), as is an inline one (a constant)
	**/
	static function staticReset(cls:ClassType, fields:Array<Field>):Field {
		var path = cls.pack.concat([cls.name]);
		var resets = [];
		for (f in fields) {
			if (!f.access.contains(AStatic) || f.access.contains(AInline) || f.meta.exists(m -> m.name == ":hot"))
				continue;
			var te = switch (f.kind) {
				case FVar(t, e) | FProp("default", "default" | "null" | "never", t, e): {t: t, e: e};
				default: null;
			}
			if (te == null)
				continue;
			var e = te.e != null ? te.e : defaultOf(te.t, f.pos);
			if (e == null)
				continue;
			var name = f.name;
			// a final can't be assigned, but can be set
			resets.push(f.access.contains(AFinal) ? macro std.Reflect.setField($p{path}, $v{name}, $e) : macro $p{path}.$name = $e);
		}
		if (resets.length == 0)
			return null;
		return {
			name: "__hot_reset__",
			access: [AStatic, APublic],
			meta: [{name: ":keep", pos: cls.pos}, {name: ":noCompletion", pos: cls.pos}],
			kind: FFun({args: [], ret: macro:Void, expr: macro $b{resets}}),
			pos: cls.pos,
		};
	}

	/**
		A static's value when it has no first value: 0 for a number, false for a bool (what
		hxcpp gives them), null otherwise; or null when the type can't be found here. On JS a
		static with no first value isn't emitted at all, so the build gives it this as its
		first value, and the two targets agree
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

	/** the project's own class paths: an edit outside the reloaded code needs a restart, which is said **/
	var sourceDirs:Array<String>;

	/** the project's classes outside the reloaded code: a reload starts their plain statics over (`__hot_reset__`) **/
	var resetClasses:Array<String>;

	/** the static functions the main class calls, `game.Game.update`, which the build marked `@:hot`: a reload's build marks the same **/
	var entries:Array<String>;

	/** the main class's file, which isn't reloaded **/
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
