extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).

func run(t: Node) -> void:
	await t.get_tree().process_frame
	var key_of := func(url: String) -> String: return url
	_decisions(t, key_of)
	_validation(t)
	_plugin_complete(t)
	_names(t)
	_safe_writes(t)
	await _limits(t)


## Merge decisions on hand-made data, without a server.
func _decisions(t: Node, key_of: Callable) -> void:
	var a := {"key": "k", "modified": 10.0, "last_read": 5.0}
	var b := {"key": "k", "modified": 20.0, "last_read": 7.0}
	t.check("newer modified wins", SyncMerge.newest_by([a, b], "modified"), b)
	t.check("newer last_read wins", SyncMerge.newest_by([a, b], "last_read"), b)
	var tied := a.duplicate()
	tied.last_read = 99.0
	t.check("a tie keeps the first", SyncMerge.newest_by([a, tied], "modified"), a)
	t.check("nothing newer is empty", SyncMerge.newest_by([], "modified"), {})
	t.check("tombstone newer than activity removes", SyncMerge.tombstone_removes(10.0, 7.0), true)
	t.check("tombstone at activity removes", SyncMerge.tombstone_removes(7.0, 7.0), true)
	t.check("older tombstone keeps", SyncMerge.tombstone_removes(5.0, 7.0), false)
	t.check("activity reads the newest stamp", SyncMerge.activity_of({"modified": 3.0, "last_read": 9.0, "added": 1.0}), 9.0)
	var grouped := SyncMerge.group_by_key([{"books": [a, b]}, {"books": [a]}])
	t.check("grouping picks winners", [grouped.k.meta, grouped.k.pos], [b, b])
	t.check("grouping keeps every entry", grouped.k.all.size(), 3)
	var novel := {"key": "n", "modified": 1.0, "cover": "old.png", "cover_set": 0.0}
	var picked := {"key": "n", "modified": 2.0, "cover": "new.png", "cover_set": 9.0}
	t.check("a cover picked by hand wins", SyncMerge.pick_cover([novel, picked]), {"name": "new.png", "set": 9.0})
	t.check("else the newest cover wins", SyncMerge.pick_cover([novel, {"key": "n", "modified": 3.0, "cover": "late.png"}]), {"name": "late.png", "set": 0.0})

	var local := {"last_read": 4.0, "progress": {"chapter": 0, "paragraph": 1},
		"chapters": [{"title": "A", "url": "u1"}, {"title": "B", "url": ""}],
		"bookmarks": [{"id": "m1", "chapter": 0, "chapter_id": "x", "paragraph": 1, "name": "One",
			"text": "", "created": 1.0, "modified": 2.0, "deleted": false}]}
	var entry := {"last_read": 8.0, "progress": {"id": "???", "chapter": 99, "paragraph": 40}}
	var moving := SyncMerge.newer_progress(local, entry, key_of)
	t.check("newer position moves", [moving.progress.chapter, moving.last_read], [1, 8.0])
	t.check("older position stays", SyncMerge.newer_progress(local, {"last_read": 2.0}, key_of), {})
	var remote := [{"bookmarks": [
		{"id": "m1", "chapter": 4, "chapter_id": "zzz", "paragraph": 2, "name": "Renamed",
			"text": "", "created": 1.0, "modified": 5.0, "deleted": false},
		{"id": "m2", "chapter": 0, "chapter_id": "u1", "paragraph": 0, "name": "New",
			"text": "", "created": 2.0, "modified": 3.0, "deleted": false}]}]
	var marks := SyncMerge.merged_bookmarks(local, remote, key_of)
	t.check("bookmarks merge", marks.size(), 2)
	var first: Dictionary = marks.filter(func(m): return m.id == "m1")[0]
	t.check("newer rename wins", [first.name, first.paragraph], ["Renamed", 2])
	t.check("unknown chapter id falls back to the chapter", marks.filter(func(m): return m.id == "m2")[0].chapter, 0)
	t.check("older change loses", SyncMerge.merged_bookmarks(local, [{"bookmarks": [
		{"id": "m1", "paragraph": 9, "modified": 1.0}]}], key_of), local.bookmarks)

	var mine := [{"title": "a", "url": ""}, {"title": "b", "url": ""}]
	t.check("longer imported list wins", SyncMerge.extended_chapters(mine, [{"chapters": mine + [{"title": "c", "url": ""}]}]).size(), 3)
	t.check("different imported list loses", SyncMerge.extended_chapters(mine, [{"chapters": [{"title": "x"}, {"title": "b"}, {"title": "c"}]}]).size(), 2)
	var web := [{"title": "A", "url": "u1"}]
	var merged := SyncMerge.combined_chapters(web, [{"chapters": [{"title": "A", "url": "u1"}, {"title": "B", "url": "u2"}]}], key_of)
	t.check("web lists combine", merged.map(func(c): return c.title), ["A", "B"])
	t.check("detail fields take the newest", SyncMerge.detail_fields({"modified": 1.0, "title": "Old", "last_checked": 1.0},
		{"modified": 2.0, "title": "New", "last_checked": 0.0}), {"modified": 2.0, "title": "New", "last_checked": 1.0,
		"last_full_check": 0.0, "possible_gap": false})
	var tagged := SyncMerge.detail_fields({"modified": 1.0, "tags": ["A"], "tags_set": false, "last_checked": 1.0},
		{"modified": 2.0, "tags": ["B"], "tags_set": true, "last_checked": 0.0})
	t.check("detail fields take tags_set from the newer entry", [tagged.get("tags"), tagged.get("tags_set")], [["B"], true])
	t.check("detail fields keep this device's when newer", SyncMerge.detail_fields({"modified": 3.0, "tags_set": true, "last_checked": 1.0},
		{"modified": 2.0, "tags_set": false, "last_checked": 0.0}).has("tags_set"), false)
	var gap_local := SyncMerge.detail_fields({"modified": 1.0, "last_full_check": 9.0, "possible_gap": false},
		{"modified": 2.0, "last_full_check": 3.0, "possible_gap": true})
	t.check("detail fields keep the newer last_full_check", gap_local.get("last_full_check"), 9.0)
	t.check("detail fields clear the gap with the newer full check", gap_local.get("possible_gap"), false)
	var gap_remote := SyncMerge.detail_fields({"modified": 3.0, "last_full_check": 2.0, "possible_gap": false},
		{"modified": 2.0, "last_full_check": 8.0, "possible_gap": true})
	t.check("detail fields take the newer last_full_check", gap_remote.get("last_full_check"), 8.0)
	t.check("detail fields take the gap with the newer full check", gap_remote.get("possible_gap"), true)
	t.check("detail fields keep a gap flag on a tied full check", SyncMerge.detail_fields(
		{"modified": 1.0, "last_full_check": 5.0, "possible_gap": false},
		{"modified": 2.0, "last_full_check": 5.0, "possible_gap": true}).get("possible_gap"), true)

	# An update check stamps `modified` on every book it checks; an archive made
	# on another device before that must still win.
	var checked_here := {"modified": 50.0, "last_checked": 50.0}
	var archived_there := {"modified": 40.0, "archived": true, "status_set": {"archived": 30.0}}
	var won := SyncMerge.detail_fields(checked_here, archived_there, [archived_there])
	t.check("a newer status change wins over a newer update check", [won.get("archived"), won.get("status_set")], [true, {"archived": 30.0}])
	var unarchived_here := {"modified": 20.0, "archived": false, "status_set": {"archived": 35.0}}
	t.check("an older status change loses", SyncMerge.detail_fields(unarchived_here, archived_there, [archived_there]).has("archived"), false)
	t.check("a status set before the stamps beats one never set", SyncMerge.status_fields(checked_here, [{"modified": 10.0, "archived": true}]), {"archived": true})
	t.check("unstamped statuses on both sides follow the newer version", SyncMerge.status_fields(
		{"modified": 50.0, "favorite": false}, [{"modified": 10.0, "favorite": true}]), {})
	var three := SyncMerge.status_fields({}, [{"modified": 9.0, "favorite": false, "status_set": {"favorite": 2.0}},
		{"modified": 1.0, "favorite": true, "status_set": {"favorite": 5.0}, "archived": true}])
	t.check("the newest status change of any device wins", [three.get("favorite"), three.get("archived"), three.get("status_set")],
		[true, true, {"favorite": 5.0}])

	var docs := [{"settings": {"v": {"v": 1, "t": 5.0}}}, {"settings": {"v": {"v": 2, "t": 9.0}, "w": {"v": 1, "t": 3.0}}}]
	t.check("newest setting wins", SyncMerge.winning_settings(docs, {}), {"v": {"v": 2, "t": 9.0}, "w": {"v": 1, "t": 3.0}})
	t.check("older setting loses", SyncMerge.winning_settings(docs, {"v": 10.0}), {"w": {"v": 1, "t": 3.0}})
	var with_rules := [{"rules": {"modified": 4.0, "list": [{"name": "old"}]}}, {"rules": {"modified": 6.0, "list": [{"name": "new"}]}}]
	t.check("newest rules win", SyncMerge.newest_rules(with_rules, 0.0), {"modified": 6.0, "list": [{"name": "new"}]})
	t.check("older rules lose", SyncMerge.newest_rules(with_rules, 9.0), {})
	var with_plugins := [{"plugins": {"p": {"v": "1.0", "t": 2.0}}}, {"plugins": {"p": {"v": "1.1", "t": 7.0}}}]
	t.check("newest plugin record wins", SyncMerge.newest_plugin_records(with_plugins), {"p": {"v": "1.1", "t": 7.0}})


## Malformed device docs are cut down without errors.
func _validation(t: Node) -> void:
	t.check("no doc is unusable", SyncMerge.sanitize_device_doc("junk").doc.is_empty(), true)
	t.check("books must be a list", SyncMerge.sanitize_device_doc({"books": {}}).doc.is_empty(), true)
	var good := {"key": "k", "md5": "m", "modified": 1.0, "last_read": 2.0}
	var doc := {"books": [good, {"md5": "m", "modified": 1.0, "last_read": 1.0}, "junk",
		{"key": 7, "md5": "m", "modified": 1.0, "last_read": 1.0},
		{"key": "x", "md5": "m", "modified": "soon", "last_read": 1.0},
		{"key": "x", "md5": "m", "modified": 1.0},
		{"key": "x", "modified": 1.0, "last_read": 1.0}],
		"tombstones": {"gone": 5.0, "bad": "soon", "worse": []},
		"rules": {"modified": "soon", "list": []},
		"settings": {"keep": {"v": 1, "t": 2.0}, "bad": {"v": 1}, "worse": 7},
		"plugins": {"keep": {"v": "1.0", "t": 1.0}, "bad": {"v": "1.0"}},
		"missing": {"keep": ["a"], "bad": "a"},
		"device": "junk"}
	var checked := SyncMerge.sanitize_device_doc(doc)
	t.check("only well-formed entries stay", checked.doc.books, [good])
	t.check("tombstones keep numbers", checked.doc.tombstones, {"gone": 5.0})
	t.check("bad rules go", checked.doc.rules, {})
	t.check("bad settings go", checked.doc.settings, {"keep": {"v": 1, "t": 2.0}})
	t.check("bad plugin records go", checked.doc.plugins, {"keep": {"v": "1.0", "t": 1.0}})
	t.check("bad missing goes", checked.doc.missing, {"keep": ["a"]})
	t.check("dropped entries are counted", checked.dropped, 13)


## Names from other devices that end up in server or local paths.
func _names(t: Node) -> void:
	t.check("plain plugin id is safe", Sync._safe_name("mysite"), true)
	t.check("dotted version is safe", Sync._safe_name("1.10.0"), true)
	t.check("cover name is safe", Sync._safe_name("cover-abc123def456.png"), true)
	t.check("parent escape is unsafe", Sync._safe_name("../x"), false)
	t.check("subfolder is unsafe", Sync._safe_name("a/b"), false)
	t.check("drive is unsafe", Sync._safe_name("c:"), false)
	t.check("backslash is unsafe", Sync._safe_name("a\\b"), false)
	t.check("hidden name is unsafe", Sync._safe_name(".hidden"), false)
	t.check("empty name is unsafe", Sync._safe_name(""), false)


## State and cache saves go through a temp file, so a crash can't leave a
## half-written file behind.
func _safe_writes(t: Node) -> void:
	var path := Settings.data_dir() + "/selftest_sync_state.json"
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".tmp")
	t.check("safe write lands", SafeFile.write_text(path, "{\"a\": 1}"), true)
	t.check("safe write reads back whole", FileAccess.get_file_as_string(path), "{\"a\": 1}")
	t.check("safe write leaves no temp file", FileAccess.file_exists(path + ".tmp"), false)
	DirAccess.remove_absolute(path)
	Sync._save_state()
	t.check("state save leaves no temp file", FileAccess.file_exists(Sync._state_path() + ".tmp"), false)
	Sync._save_cache()
	t.check("cache save leaves no temp file", FileAccess.file_exists(Sync._cache_path() + ".tmp"), false)


## Oversized replies fail instead of filling memory; offline, with a pre-read reply.
func _limits(t: Node) -> void:
	t.check("responses are capped at 64 MiB", WebDav.MAX_BODY, 67108864)
	var huge := WebDav.new("https://example.com/dav/")
	huge._buf = "HTTP/1.1 200 OK\r\nContent-Length: 100000000\r\nConnection: close\r\n\r\n".to_utf8_buffer()
	var r: Dictionary = await huge._receive("GET")
	t.check("oversized content-length fails", r.ok, false)
	t.check("oversized content-length says too much data", r.error.contains("too much"), true)
	var chunks := WebDav.new("https://example.com/dav/")
	chunks._buf = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n40000000\r\n".to_utf8_buffer()
	var c: Dictionary = await chunks._receive("GET")
	t.check("oversized chunk fails", c.ok, false)
	t.check("oversized chunk says too much data", c.error.contains("too much"), true)


## A version counts as uploaded only when the manifest is listed in its folder.
func _plugin_complete(t: Node) -> void:
	t.check("manifest listed is complete", SyncMerge.version_complete([{"name": "plugin.json", "is_dir": false}, {"name": "source.gd", "is_dir": false}], "plugin.json"), true)
	t.check("folder alone is not complete", SyncMerge.version_complete([{"name": "source.gd", "is_dir": false}], "plugin.json"), false)
	t.check("nothing listed is not complete", SyncMerge.version_complete([], "plugin.json"), false)
	t.check("a folder named like the manifest is not complete",
		SyncMerge.version_complete([{"name": "plugin.json", "is_dir": true}], "plugin.json"), false)
