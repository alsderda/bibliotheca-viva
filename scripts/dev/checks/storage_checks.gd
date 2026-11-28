extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).

## Scratch folder for these checks, next to (never inside) the profile's files.
var _scratch := "user://storage-check-scratch"


func run(t: Node) -> void:
	await t.get_tree().process_frame
	_rm(_scratch)
	DirAccess.make_dir_recursive_absolute(_scratch + "/meta")
	_safefile(t)
	_ids(t)
	_replace(t)
	_add_chapter(t)
	_loader(t)
	_rm(_scratch)


func _ids(t: Node) -> void:
	var ids := []
	for i in 200:
		ids.append(Library._new_id())
	var seen := {}
	for id in ids:
		seen[id] = true
	t.check("200 new ids are all unique", seen.size(), 200)
	var hexed := true
	for id in ids:
		if str(id) == "" or str(id) != str(id).to_lower() or not str(id).is_valid_hex_number():
			hexed = false
	t.check("new ids are lowercase hex", hexed, true)
	var fresh := true
	for id in ids:
		if not Library.get_book(str(id)).is_empty():
			fresh = false
	t.check("new ids are not in use", fresh, true)


func _replace(t: Node) -> void:
	var b := Library.add_book({"title": "Replace test", "kind": "web", "url": "https://example.com/rtest",
		"chapters": [{"title": "A", "url": "https://example.com/r/a"}, {"title": "B", "url": "https://example.com/r/b"}, {"title": "C", "url": "https://example.com/r/c"}]})
	Library.store_chapter(b.id, 0, "A", PackedStringArray(["text A"]))
	Library.store_chapter(b.id, 1, "B", PackedStringArray(["text B"]))
	Library.store_chapter(b.id, 2, "C", PackedStringArray(["text C"]))
	# Swap the outer chapters and drop the middle one: each text follows its link.
	Library.replace_chapters(b.id, [{"title": "C", "url": "https://example.com/r/c"}, {"title": "A", "url": "https://example.com/r/a"}])
	t.check("swapped text follows its chapter", Library.load_chapter(b.id, 0).get("paragraphs", []), ["text C"])
	t.check("other swapped text follows its chapter", Library.load_chapter(b.id, 1).get("paragraphs", []), ["text A"])
	t.check("dropped chapter file is gone", Library.has_chapter(b.id, 2), false)
	t.check("count moves with the chapter", Library.get_book(b.id).chapters[0].get("words"), 2)
	t.check("no staging left behind", DirAccess.dir_exists_absolute(Library.book_dir(b.id) + "/staging"), false)
	Library.remove_book(b.id, false)
	_recover(t)


func _add_chapter(t: Node) -> void:
	var b := Library.add_book({"title": "Add chapter test", "kind": "web", "url": "https://example.com/atest",
		"chapters": [{"title": "A", "url": "https://example.com/a/a"}]})
	var before: float = b.modified
	b.modified = before - 10
	t.check("added chapter's index", Library.add_chapter(b.id, "B", "https://example.com/a/b"), 1)
	t.check("added chapter at the end", Library.get_book(b.id).chapters.map(func(c): return c.title), ["A", "B"])
	t.check("adding a chapter marks the book changed", Library.get_book(b.id).modified > before - 10, true)
	t.check("no chapter added to a missing book", Library.add_chapter("no-such-book", "X", "https://example.com/x"), -1)
	Library.remove_book(b.id, false)


## A kill mid-replace leaves staged files and maybe a manifest; the next call heals it.
func _recover(t: Node) -> void:
	var b := Library.add_book({"title": "Recovery test", "kind": "web", "url": "https://example.com/rrectest",
		"chapters": [{"title": "A", "url": "https://example.com/rr/a"}, {"title": "B", "url": "https://example.com/rr/b"}]})
	Library.store_chapter(b.id, 0, "A", PackedStringArray(["text A"]))
	Library.store_chapter(b.id, 1, "B", PackedStringArray(["text B"]))
	var dir := Library.book_dir(b.id)
	var orig := [{"title": "A", "url": "https://example.com/rr/a"}, {"title": "B", "url": "https://example.com/rr/b"}]
	var swapped := [{"title": "B", "url": "https://example.com/rr/b"}, {"title": "A", "url": "https://example.com/rr/a"}]
	# A kill after the first staging move: one kept file staged, no manifest yet.
	DirAccess.make_dir_recursive_absolute(dir + "/staging")
	DirAccess.rename_absolute(dir + "/0.json", dir + "/staging/0.json")
	Library.replace_chapters(b.id, orig)
	t.check("staged file without a plan moves back", Library.load_chapter(b.id, 0).get("paragraphs", []), ["text A"])
	t.check("unstaged file stays put", Library.load_chapter(b.id, 1).get("paragraphs", []), ["text B"])
	# A kill after staging, manifest written: the run is finished instead.
	DirAccess.make_dir_recursive_absolute(dir + "/staging")
	DirAccess.rename_absolute(dir + "/0.json", dir + "/staging/0.json")
	DirAccess.rename_absolute(dir + "/1.json", dir + "/staging/1.json")
	SafeFile.write_text(dir + "/staging/plan.json", JSON.stringify({"chapters": swapped, "staged": [0, 1]}))
	Library.replace_chapters(b.id, swapped)
	t.check("interrupted swap finishes at chapter 0", Library.load_chapter(b.id, 0).get("paragraphs", []), ["text B"])
	t.check("interrupted swap finishes at chapter 1", Library.load_chapter(b.id, 1).get("paragraphs", []), ["text A"])
	t.check("recovery leaves no staging", DirAccess.dir_exists_absolute(dir + "/staging"), false)
	Library.remove_book(b.id, false)


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
	t.check("ratio of a normalised book", BookStatus.progress_ratio(bare), 0.0)
	t.check("normalised book not finished", BookStatus.is_finished(bare), false)

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
