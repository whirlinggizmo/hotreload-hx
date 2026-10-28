import haxe.macro.Context;

/**
	the build-order test's build macros: a class that needs another's to have run first, as a
	library's facade over its service does
**/
class Mark {
	#if macro
	static var recorded = new Map<String, Bool>();
	#end

	macro public static function record():Array<haxe.macro.Expr.Field> {
		recorded[Context.getLocalClass().toString()] = true;
		return null;
	}

	macro public static function check(name:String):Array<haxe.macro.Expr.Field> {
		if (!recorded.exists(name))
			Context.error('$name was not recorded before ' + Context.getLocalClass().toString() + ' was built', Context.currentPos());
		return null;
	}
}
