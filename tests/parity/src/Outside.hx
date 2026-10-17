/**
	A class of the project's with nothing hot in its directory: natively it's compiled into
	the executable and never reloaded, yet its plain statics start over on each reload, as
	on JS, where the whole bundle reloads. The main class sets each; a reload starts it over
**/
class Outside {
	public static var count = 0;
	public static var tag:String; // no first value: null again
	public static var n:Int; // no first value: 0 again, on both (JS wouldn't emit it on its own)
	public static final list:Array<Int> = []; // a final: set, since it can't be assigned
}
