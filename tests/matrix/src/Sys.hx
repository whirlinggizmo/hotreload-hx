/** what the matrix's Game uses of Sys, which JS has none of: printing a line **/
class Sys {
	public static function println(v:Dynamic)
		js.Syntax.code("console.log({0})", Std.string(v));
}
