package hotreload;

#if sys
import sys.FileSystem;
import sys.io.File;

/**
	Files watched for saves, checked a few times a second: once some have changed, and a
	check finds nothing more changing (a save can touch a file twice, or several files),
	`check` gives the batch. The reloaders' sources and assets, and the DevServer's, are
	each one of these.

	`list` names the files: each by its key, as `check` gives it (a path, or the URL a file
	is served at), and its path on disk.
**/
class FileWatch {
	/** how many quiet checks an empty file is waited out for **/
	static inline var EMPTY_WAIT = 5;

	var list:() -> Map<String, String>;
	var stamps:Map<String, Stamp>;

	/** the files, by key, that changed since the batch started, and the stamps it started from **/
	var changed = new Array<String>();

	var before:Map<String, Stamp>;
	var settling = false;

	/** checks in a row that found nothing changing, while a batch settles **/
	var quiet = 0;

	public function new(list:() -> Map<String, String>) {
		this.list = list;
		stamps = stampAll();
	}

	/** what changed, by key, once a batch has settled; null before then **/
	public function check():Null<Array<String>> {
		var current = stampAll();
		var any = false;
		for (key => stamp in current)
			if (!stamps.exists(key) || stamp.differs(stamps.get(key))) {
				note(key);
				any = true;
			}
		for (key in stamps.keys())
			if (!current.exists(key)) {
				note(key);
				any = true;
			}
		if (any && !settling) {
			settling = true;
			before = stamps;
		}
		stamps = current;
		if (any) {
			quiet = 0;
			return null;
		}
		if (!settling)
			return null;
		// an empty file is one being saved (truncated, then written): wait for it, but not
		// for long, as a save takes moments and a file can be emptied on purpose
		quiet++;
		if (quiet < EMPTY_WAIT)
			for (key in changed)
				if (current.exists(key) && current.get(key).empty())
					return null;
		settling = false;
		quiet = 0;
		// a file made and gone within the batch (an editor's temporary one) was never there
		var batch = [for (key in changed) if (current.exists(key) || before.exists(key)) key];
		changed = [];
		before = null;
		batch.sort(Reflect.compare);
		return batch.length > 0 ? batch : null;
	}

	function note(key:String) {
		if (!changed.contains(key))
			changed.push(key);
	}

	function stampAll():Map<String, Stamp> {
		var now = Date.now().getTime();
		return [for (key => path in list()) key => Stamp.of(path, now)];
	}
}

/**
	When a file last changed. A file's time is in whole seconds, so two saves in one
	second, the same size, would look like one: a file changed in the last few seconds
	has its contents' hash too, if it's small enough to read that often (a source, a
	shader, a level; a large asset is written by a tool, not saved twice in a second)
**/
private class Stamp {
	static inline var HASH_LIMIT = 1 << 20;

	var mtime:Float;
	var size:Int;
	var hash:Null<Int>;

	function new(mtime, size, hash) {
		this.mtime = mtime;
		this.size = size;
		this.hash = hash;
	}

	public static function of(path:String, now:Float):Stamp {
		try {
			var stat = FileSystem.stat(path);
			var mtime = stat.mtime.getTime();
			var hash = now - mtime < 3000 && stat.size <= HASH_LIMIT ? haxe.crypto.Crc32.make(File.getBytes(path)) : null;
			return new Stamp(mtime, stat.size, hash);
		} catch (_) {
			return new Stamp(0, 0, null);
		}
	}

	public function empty():Bool {
		return size == 0;
	}

	public function differs(other:Stamp):Bool {
		return mtime != other.mtime || size != other.size || (hash != null && other.hash != null && hash != other.hash);
	}
}
#end
