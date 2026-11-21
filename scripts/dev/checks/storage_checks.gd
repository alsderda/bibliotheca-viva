extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).

## Scratch folder for these checks, next to (never inside) the profile's files.
var _scratch := "user://storage-check-scratch"


func run(t: Node) -> void:
	await t.get_tree().process_frame
	_rm(_scratch)
	DirAccess.make_dir_recursive_absolute(_scratch + "/meta")
	_safefile(t)
	_loader(t)
	_rm(_scratch)


func _safefile(t: Node) -> void:
	t.check("safefile writes text", SafeFile.write_text(_scratch + "/a.txt", "hello"), true)
	t.check("safefile text reads back", FileAccess.get_file_as_string(_scratch + "/a.txt"), "hello")
	t.check("safefile replaces the file", SafeFile.write_text(_scratch + "/a.txt", "world"), true)
	t.check("replaced text reads back", FileAccess.get_file_as_string(_scratch + "/a.txt"), "world")
	t.check("no tmp file left", FileAccess.file_exists(_scratch + "/a.txt.tmp"), false)
	var bytes := PackedByteArray([0, 1, 2, 250, 255])
	t.check("safefile writes bytes", SafeFile.write_bytes(_scratch + "/a.bin", bytes), true)
	t.check("safefile bytes read back", FileAccess.get_file_as_bytes(_scratch + "/a.bin"), bytes)
	t.check("safefile text fails without a directory", SafeFile.write_text("user://no-such-dir-anywhere/a.txt", "x"), false)
	t.check("safefile bytes fail without a directory", SafeFile.write_bytes("user://no-such-dir-anywhere/a.bin", bytes), false)


func _loader(t: Node) -> void:
	var keep_books: Array = Library.books
	var keep_tombs: Dictionary = Library.tombstones
	var keep_rev: Dictionary = Library.revisions
	var keep_dirty: Dictionary = Library._dirty
	var keep_kept: Array = Library._kept
	var keep_index: bool = Library._index_dirty
	var keep_queued: bool = Library._flush_queued
	Library._dirty = {}
	Library._index_dirty = false
	Library._flush_queued = false

	var good := {"id": "good1", "title": "Good",
		"chapters": [{"title": "A", "url": "https://example.com/a"}],
		"progress": {"chapter": 0, "paragraph": 2}, "added": 1.0, "last_read": 2.0}
	SafeFile.write_text(_scratch + "/meta/good1.json", JSON.stringify(good))
	SafeFile.write_text(_scratch + "/library.json", JSON.stringify({"version": 2,
		"books": [{"id": "good1", "progress": {"chapter": 0, "paragraph": 2}, "last_read": 2.0},
			{"id": "gone1", "progress": {"chapter": 3, "paragraph": 0}, "last_read": 5.0}],
		"tombstones": {}}))
	Library._load_from(_scratch)
	t.check("readable entry loads from scratch", Library.get_book("good1").get("title", ""), "Good")
	t.check("unreadable entry stays out of books", Library.get_book("gone1"), {})
	Library._index_dirty = true
	Library.flush(_scratch)
	var back: Variant = JSON.parse_string(FileAccess.get_file_as_string(_scratch + "/library.json"))
	var ids := (back.books as Array).map(func(e): return e.get("id", ""))
	t.check("unreadable entry kept through a flush", ids.has("gone1") and ids.has("good1"), true)
	t.check("no tmp files left after a flush", _tmps(), [])

	SafeFile.write_text(_scratch + "/meta/dmg1.json", "{damaged")
	SafeFile.write_text(_scratch + "/library.json", JSON.stringify({"version": 2,
		"books": [{"id": "dmg1", "progress": {"chapter": 0, "paragraph": 0}}], "tombstones": {}}))
	Library._load_from(_scratch)
	t.check("damaged meta stays out of books", Library.get_book("dmg1"), {})
	t.check("damaged meta keeps a bad copy", _dmg("meta/dmg1.json"), "{damaged")
	Library._index_dirty = true
	Library.flush(_scratch)
	back = JSON.parse_string(FileAccess.get_file_as_string(_scratch + "/library.json"))
	t.check("damaged entry kept through a flush", (back.books as Array).map(func(e): return e.get("id", "")), ["dmg1"])

	SafeFile.write_text(_scratch + "/library.json", "{broken")
	Library._load_from(_scratch)
	t.check("corrupt index loads empty", Library.books, [])
	t.check("corrupt index keeps a bad copy", _dmg("library.json"), "{broken")

	SafeFile.write_text(_scratch + "/meta/bare1.json", JSON.stringify({"id": "bare1", "title": "Bare",
		"progress": "lost", "chapters": "oops", "bookmarks": [{"chapter": 1}, "junk", {"chapter": 1, "paragraph": 2}]}))
	SafeFile.write_text(_scratch + "/library.json", JSON.stringify({"version": 2,
		"books": [{"id": "bare1", "last_read": 0}], "tombstones": {}}))
	Library._load_from(_scratch)
	var bare := Library.get_book("bare1")
	t.check("wrong-type progress starts at zero", bare.get("progress"), {"chapter": 0, "paragraph": 0})
	t.check("wrong-type chapters read as none", bare.get("chapters"), [])
	t.check("malformed bookmarks are dropped", bare.get("bookmarks"), [{"chapter": 1, "paragraph": 2}])
	t.check("ratio of a normalised book", Library.progress_ratio(bare), 0.0)
	t.check("normalised book not finished", Library.is_finished(bare), false)

	Library.books = keep_books
	Library.tombstones = keep_tombs
	Library.revisions = keep_rev
	Library._dirty = keep_dirty
	Library._kept = keep_kept
	Library._index_dirty = keep_index
	Library._flush_queued = keep_queued


## Every *.tmp file left under the scratch folder, recursively.
func _tmps() -> Array:
	var out := []
	_tmps_in(_scratch, out)
	return out


func _tmps_in(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".tmp"):
			out.append(dir + "/" + f)
	for s in d.get_directories():
		_tmps_in(dir + "/" + s, out)


## Content of the `.bad-` copy kept for a damaged scratch file, or "".
## `rel` is relative to the scratch folder, e.g. "library.json" or "meta/dmg1.json".
func _dmg(rel: String) -> String:
	var folder := _scratch + "/" + rel.get_base_dir().trim_suffix("/")
	var d := DirAccess.open(folder)
	if d == null:
		return ""
	for f in d.get_files():
		if f.begins_with(rel.get_file() + ".bad-"):
			return FileAccess.get_file_as_string(folder + "/" + f)
	return ""


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for s in d.get_directories():
		_rm(path + "/" + s)
	DirAccess.remove_absolute(path)
