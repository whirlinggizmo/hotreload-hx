/** listeners by identity, as an event dispatcher keeps them **/
class Dispatcher {
	var listeners:Array<() -> Void> = [];

	public function new() {}

	public function add(listener:() -> Void)
		listeners.push(listener);

	public function remove(listener:() -> Void):Bool
		return listeners.remove(listener);

	public function count():Int
		return listeners.length;

	public function dispatch()
		for (listener in listeners.copy())
			listener();
}
