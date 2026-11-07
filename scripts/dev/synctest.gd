extends Node
## Two-device sync checks against a WebDAV server. Each step runs in its own
## process with its own profile; scripts/dev/synctest.sh runs them in order.
##   godot --headless --path . -- --profile=synctest_a --synctest=<step> --dav=<url> [--dav-user=u --dav-pass=p]

const RR := "https://example.com/fiction/111/test-story"

var failures := 0


func _ready() -> void:
	OS.low_processor_usage_mode = false
	var step := ""
	var url := ""
	var user := ""
	var password := ""
	for arg in OS.get_cmdline_user_args():
		match arg.get_slice("=", 0):
			"--synctest": step = arg.get_slice("=", 1)
			"--dav": url = arg.substr(6)
			"--dav-user": user = arg.get_slice("=", 1)
			"--dav-pass": password = arg.get_slice("=", 1)
	Sync.configure(url, user, password)
	Sync._state.enabled = true
	Sync._apply_enabled()
	await call(step)
	print("SYNCTEST %s %s" % [step, "PASSED" if failures == 0 else "FAILED (%d)" % failures])
	get_tree().quit(failures)


func check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok   ", name)
	else:
		failures += 1
		print("  FAIL ", name, "\n       got:  ", got, "\n       want: ", want)


func sync(label := "sync") -> void:
	var err := await Sync.sync_now()
	check(label + " has no error", err, "")


func web_book() -> Dictionary:
	return Library.find_by_url(RR)


func file_book() -> Dictionary:
	for b in Library.books:
		if b.title == "Local Epub":
			return b
	return {}


func chapter(n: int) -> Dictionary:
	return {"title": "Chapter %d" % n, "url": "https://example.com/fiction/111/test-story/chapter/%d/c%d" % [1000 + n, n], "date": 0}


## Install a tiny test plugin (as if from a folder) with the given version.
func install_test_plugin(version: String) -> void:
	var dir := OS.get_user_data_dir().path_join("synctest_plugin_src")
	DirAccess.make_dir_recursive_absolute(dir.path_join("lib"))
	var m := {"id": "synctestplugin", "name": "Sync test plugin", "version": version, "api": Plugins.API,
		"domains": ["synctest.example"], "files": ["source.gd", "lib/notes.txt"]}
	FileAccess.open(dir.path_join("plugin.json"), FileAccess.WRITE).store_string(JSON.stringify(m))
	FileAccess.open(dir.path_join("source.gd"), FileAccess.WRITE).store_string("extends SourcePlugin\n")
	FileAccess.open(dir.path_join("lib/notes.txt"), FileAccess.WRITE).store_string("version " + version)
	var r := Plugins.install_from_folder(dir)
	check("test plugin %s installed" % version, r.get("error", ""), "")


func test_plugin_version() -> String:
	var e := Plugins.get_entry("synctestplugin")
	return e.version if not e.is_empty() and e.plugin != null else ""


## The files in a folder on the server (names, without subfolders).
func server_files(path: String) -> Array:
	var l := await WebDav.new(Sync.server_url(), Sync.user_name(), Sync._password).list("bibliotheca-viva/" + path)
	return l.entries.filter(func(e): return not e.is_dir).map(func(e): return e["name"]) if l.ok else []


func paras(tag: String) -> PackedStringArray:
	return PackedStringArray(["%s first paragraph." % tag, "%s second paragraph." % tag])


# --- steps -------------------------------------------------------------------

func a_seed() -> void:
	var w := Library.add_book({"title": "Test Story", "source": "web", "url": RR, "chapters": [chapter(1), chapter(2), chapter(3), chapter(4)]})
	for i in 3:
		Library.store_chapter(w.id, i, "Chapter %d" % (i + 1), paras("web %d" % i))
	Library.store_chapter(w.id, 3, "Chapter 4", paras("rss preview"), true)
	Library.set_progress(w.id, 2, 5)
	var f := Library.add_book({"title": "Local Epub", "author": "Someone", "kind": "epub", "source": "file", "chapters": [{"title": "One", "url": ""}, {"title": "Two", "url": ""}]})
	Library.store_chapter(f.id, 0, "One", paras("epub 0"))
	Library.store_chapter(f.id, 1, "Two", paras("epub 1"))
	var img := Image.create(8, 12, false, Image.FORMAT_RGB8)
	img.fill(Color.CORNFLOWER_BLUE)
	Library.update_book(f.id, {"cover": Library.save_cover(f.id, img)})
	TextRules.add_rule(TextRules.new_rule({"name": "global", "pattern": "HP", "replace": "health"}))
	TextRules.add_rule(TextRules.new_rule({"name": "per book", "pattern": "Ahab", "replace": "Ay-hab", "book": w.id}))
	Settings.set_value("font_size", 24)
	Settings.set_value("tts_voice", "a-voice-only-here")
	install_test_plugin("1.0.0")
	# a device file left by an older version of this device
	var dav := WebDav.new(Sync.server_url(), Sync.user_name(), Sync._password)
	await dav.make_dir("bibliotheca-viva/")
	await dav.make_dir("bibliotheca-viva/devices/")
	await dav.put("bibliotheca-viva/devices/%s.json" % Sync.device_id(), "{}".to_utf8_buffer())
	await sync()
	check("index on the server", await server_files("devices/%s/" % Sync.device_id()), ["index.json"])
	check("a file per book", (await server_files("devices/%s/books/" % Sync.device_id())).size(), 2)
	check("old device file removed", (await server_files("devices/")).has(Sync.device_id() + ".json"), false)


func b_first() -> void:
	await sync()
	check("two books", Library.books.size(), 2)
	var w := web_book()
	var f := file_book()
	check("web book arrived", w.is_empty(), false)
	check("file book arrived", f.is_empty(), false)
	if w.is_empty() or f.is_empty():
		return
	check("web chapters", w.chapters.size(), 4)
	check("full chapters downloaded", [Library.has_full_chapter(w.id, 0), Library.has_full_chapter(w.id, 1), Library.has_full_chapter(w.id, 2)], [true, true, true])
	check("rss preview not synced", Library.has_chapter(w.id, 3), false)
	check("chapter text", Library.load_chapter(w.id, 1).paragraphs, ["web 1 first paragraph.", "web 1 second paragraph."])
	check("epub chapters", [Library.has_full_chapter(f.id, 0), Library.has_full_chapter(f.id, 1)], [true, true])
	check("cover downloaded", f.cover != "" and FileAccess.file_exists(f.cover), true)
	check("progress", w.progress, {"chapter": 2, "paragraph": 5})
	check("rules", TextRules.rules.map(func(r): return r.name), ["global", "per book"])
	check("per-book rule points at local book", TextRules.rules[1].book, w.id)
	check("setting synced", Settings.get_value("font_size"), 24)
	check("voice stays local", Settings.get_value("tts_voice"), "")
	check("one other device", Sync.devices.size(), 1)
	check("plugin arrived and runs", test_plugin_version(), "1.0.0")
	check("plugin's subfolder file arrived", FileAccess.get_file_as_string(Plugins.installed_dir().path_join("synctestplugin/lib/notes.txt")), "version 1.0.0")
	# read further and save a new chapter on this device
	w.chapters.append(chapter(5))
	Library.update_book(w.id, {"chapters": w.chapters})
	Library.store_chapter(w.id, 4, "Chapter 5", paras("web 4"))
	Library.set_progress(w.id, 4, 1)
	# pick a cover by hand: it replaces the other device's cover there
	var red := Image.create(8, 12, false, Image.FORMAT_RGB8)
	red.fill(Color.RED)
	check("cover picked by hand", Library.set_cover_from_bytes(f.id, red.save_png_to_buffer()), "")
	await sync("second sync")


func a_second() -> void:
	await sync()
	var w := web_book()
	check("new chapter in list", w.chapters.size(), 5)
	check("new chapter text", Library.has_full_chapter(w.id, 4), true)
	check("progress from other device", w.progress, {"chapter": 4, "paragraph": 1})
	var f := file_book()
	var img := Image.load_from_file(f.cover)
	check("cover picked on other device", img != null and img.get_pixel(0, 0).is_equal_approx(Color.RED), true)
	check("voice untouched", Settings.get_value("tts_voice"), "a-voice-only-here")
	Library.remove_book(file_book().id)
	Settings.set_value("font_size", 26)
	install_test_plugin("1.1.0")
	await sync("sync after removal")
	check("removed book's file gone", (await server_files("devices/%s/books/" % Sync.device_id())).size(), 1)


func b_second() -> void:
	await sync()
	check("removed book is gone", file_book().is_empty(), true)
	check("one book", Library.books.size(), 1)
	check("setting changed again", Settings.get_value("font_size"), 26)
	check("plugin updated", test_plugin_version(), "1.1.0")
	check("removed book's file gone here too", (await server_files("devices/%s/books/" % Sync.device_id())).size(), 1)
	# nothing changed: no book is listed, fetched or sent
	var before := WebDav.requests
	await sync("quiet sync")
	print("       requests: ", WebDav.requests - before)
	check("quiet sync makes few requests", WebDav.requests - before <= 10, true)
	# a new reading position sends only the index
	Library.set_progress(web_book().id, 1, 2)
	before = WebDav.requests
	await sync("position sync")
	print("       requests: ", WebDav.requests - before)
	check("position sync makes few requests", WebDav.requests - before <= 11, true)


## Run at the same time as b_parallel.
func a_parallel() -> void:
	Settings.set_value("line_spacing", 9)
	var w := web_book()
	# a newer chapter list (e.g. the fiction page was opened) on this device
	w.chapters.append(chapter(6))
	Library.update_book(w.id, {"chapters": w.chapters})
	Library.store_chapter(w.id, 5, "Chapter 6", paras("web 5"))
	await sync()


func b_parallel() -> void:
	Settings.set_value("column_width", 800)
	var b := Library.add_book({"title": "Second Story", "source": "web", "url": "https://example.com/fiction/222/second", "chapters": [chapter(1)]})
	Library.store_chapter(b.id, 0, "Chapter 1", paras("second"))
	var w := web_book()
	# a chapter saved only here, added after the other device's list
	w.chapters.append({"title": "Side story", "url": "https://example.com/side", "date": 0})
	Library.update_book(w.id, {"chapters": w.chapters})
	Library.store_chapter(w.id, 5, "Side story", paras("side"))
	await sync()


func both_final() -> void:
	await sync()
	check("both settings", [int(Settings.get_value("line_spacing")), int(Settings.get_value("column_width"))], [9, 800])
	check("both books", Library.books.size(), 2)
	var w := web_book()
	var titles: Array = w.chapters.map(func(c): return c.title)
	check("chapter lists combined", titles.has("Chapter 6") and titles.has("Side story") and titles.size() == 7, true)
	var all_full := true
	for i in w.chapters.size():
		if i != 3 and not Library.has_full_chapter(w.id, i):
			all_full = false
	check("all saved chapters present", all_full, true)


func a_big() -> void:
	var chapters := []
	for i in 600:
		chapters.append({"title": "Big %d" % i, "url": "https://example.com/big/%d" % i, "date": 0})
	var b := Library.add_book({"title": "Big Book", "source": "web", "url": "https://example.com/big", "chapters": chapters})
	for i in 600:
		Library.store_chapter(b.id, i, "Big %d" % i, paras("big %d" % i))
	await sync()  # the shell kills this process part way through


func a_resume() -> void:
	Plugins.remove("synctestplugin")
	await sync()
	var files := await server_files("books/%s/" % Sync._folder_name(Library.sync_key(big_book())))
	check("big book sent as packs", files.filter(func(n): return n.ends_with(".json.gz")).size() > 0, true)
	check("no chapter files of their own", files.filter(func(n): return not n.begins_with("pack-")).size(), 0)


func big_book() -> Dictionary:
	for b in Library.books:
		if b.title == "Big Book":
			return b
	return {}


func b_big() -> void:
	var before := WebDav.requests
	await sync()
	print("       requests: ", WebDav.requests - before)
	check("big book fetched in few requests", WebDav.requests - before < 100, true)
	var big := big_book()
	check("removed plugin is gone", Plugins.is_installed("synctestplugin"), false)
	check("big book arrived", big.is_empty(), false)
	if big.is_empty():
		return
	var n := 0
	for i in big.chapters.size():
		if Library.has_full_chapter(big.id, i) and Library.load_chapter(big.id, i).paragraphs[0] == "big %d first paragraph." % i:
			n += 1
	check("all 600 chapters, in the right places", n, 600)
	# a couple of new chapters later go up one by one
	for i in [600, 601]:
		big.chapters.append({"title": "Big %d" % i, "url": "https://example.com/big/%d" % i, "date": 0})
	Library.update_book(big.id, {"chapters": big.chapters})
	Library.store_chapter(big.id, 600, "Big 600", paras("big 600"))
	Library.store_chapter(big.id, 601, "Big 601", paras("big 601"))
	await sync("sync of two new chapters")
	var files := await server_files("books/%s/" % Sync._folder_name(Library.sync_key(big)))
	check("new chapters have files of their own", files.filter(func(n): return not n.begins_with("pack-")).size(), 2)


func a_big_after() -> void:
	await sync()
	var big := big_book()
	check("new chapters arrived", [Library.has_full_chapter(big.id, 600), Library.has_full_chapter(big.id, 601)], [true, true])
	# a book an older version sent chapter by chapter: its files are packed now
	var chapters := []
	for i in 30:
		chapters.append({"title": "Old %d" % i, "url": "https://example.com/old/%d" % i, "date": 0})
	var old := Library.add_book({"title": "Old Book", "source": "web", "url": "https://example.com/old", "chapters": chapters})
	var dav := WebDav.new(Sync.server_url(), Sync.user_name(), Sync._password)
	var folder := "bibliotheca-viva/books/%s/" % Sync._folder_name(Library.sync_key(old))
	await dav.make_dir(folder)
	for i in 30:
		Library.store_chapter(old.id, i, "Old %d" % i, paras("old %d" % i))
		await dav.put(folder + Sync._chapter_id_of(chapters[i], i) + ".json", FileAccess.get_file_as_bytes("%s/%d.json" % [Library.book_dir(old.id), i]))
	await sync("sync of an old book")
	var files := await server_files("books/%s/" % Sync._folder_name(Library.sync_key(old)))
	check("old book's chapters packed", files.filter(func(n): return n.ends_with(".json.gz")).size(), 1)


func b_old() -> void:
	var before := WebDav.requests
	await sync()
	print("       requests: ", WebDav.requests - before)
	check("old book fetched as a pack", WebDav.requests - before < 25, true)
	var old := {}
	for b in Library.books:
		if b.title == "Old Book":
			old = b
	var n := 0
	for i in old.get("chapters", []).size():
		if Library.has_full_chapter(old.id, i):
			n += 1
	check("all 30 old chapters", n, 30)


func race_book() -> Dictionary:
	for b in Library.books:
		if b.title == "Race Book":
			return b
	return {}


## A chapter saved while a sync is running, after its book was synced (or when
## the app is closed during a download): that sync mustn't tell other devices it
## has sent the chapter, or a device that checks the book before the chapter is
## sent, and finds nothing new then, never checks it again.
func a_race() -> void:
	var chapters := []
	for i in 3:
		chapters.append({"title": "Race %d" % i, "url": "https://example.com/race/%d" % i, "date": 0})
	var book := Library.add_book({"title": "Race Book", "source": "web", "url": "https://example.com/race", "chapters": chapters})
	Library.store_chapter(book.id, 0, "Race 0", paras("race 0"))
	Library.store_chapter(book.id, 1, "Race 1", paras("race 1"))
	await sync()


func b_race() -> void:
	await sync()
	await sync("second sync")  # nothing new: the book's check is remembered
	var book := race_book()
	check("race book arrived", [Library.has_full_chapter(book.id, 0), Library.has_full_chapter(book.id, 1)], [true, true])


func a_race_save() -> void:
	var result := {}
	var run := func(): result.err = await Sync.sync_now()
	run.call()
	while Sync.progress_text != "Saving…" and Sync.running:
		await get_tree().process_frame
	check("still syncing when the chapter is saved", Sync.running, true)
	Library.store_chapter(race_book().id, 2, "Race 2", paras("race 2"))
	while Sync.running:
		await get_tree().process_frame
	check("sync during the save has no error", result.get("err"), "")


func b_race_between() -> void:
	await sync()


func a_race_after() -> void:
	await sync()


func b_race_after() -> void:
	await sync()
	check("chapter saved during a sync arrived", Library.has_full_chapter(race_book().id, 2), true)


## Change something, then close the window: Sync should upload it before quitting.
func a_close() -> void:
	Settings.set_value("font_size", 30)
	get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	await get_tree().create_timer(30.0).timeout
	check("app quit after the final sync", false, true)


func b_after_close() -> void:
	await sync()
	check("change made just before closing arrived", int(Settings.get_value("font_size")), 30)


func offline() -> void:
	var before := Library.books.size()
	var err := await Sync.sync_now()
	check("reports an error", err != "", true)
	print("       error: ", err)
	check("library untouched", Library.books.size(), before)


## Not part of synctest.sh: syncs, then saves a screenshot of Settings → Sync
## (run without --headless):  --synctest=ui_shot --shot=/tmp/sync.png
func ui_shot() -> void:
	await sync()
	var main: Node = get_parent()
	main.navigate("settings")
	main.pages.settings.select_tab(SettingsPage.SYNC_TAB)
	main.pages.settings.header_changed.emit()
	for _i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "/tmp/sync_settings.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			path = arg.get_slice("=", 1)
	get_viewport().get_texture().get_image().save_png(path)
