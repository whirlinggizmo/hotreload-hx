/** what the matrix's Game uses of Sys, for JS (which has none): printing a line **/
class Sys {
	public static function println(v:Dynamic)
		js.Syntax.code("console.log({0})", Std.string(v));
}
