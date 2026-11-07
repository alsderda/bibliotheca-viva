extends Node
## Dev checks that every script compiles, then text rules, TTS pacing, plugin helpers and each plugin's own checks:  godot --path . -- --profile=selftest --selftest

var failures := 0


func _ready() -> void:
	OS.low_processor_usage_mode = false
	_scripts_compile()
	TextRules.rules.clear()
	_rules()
	_sentences()
	_book_search()
	_sites()
	_versions()
	await _word_counts()
	await _fetch_manager()
	await _pacing()
	print("SELFTEST ", "PASSED" if failures == 0 else "FAILED (%d)" % failures)
	get_tree().quit(failures)


# Loads every script in the project, so one the app never opens (a dev script, a widget not in use yet) still has to compile.
func _scripts_compile() -> void:
	var files := PackedStringArray()
	_find_scripts("res://", files)
	var broken := PackedStringArray()
	for path in files:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			broken.append(path)
	check("all %d scripts compile" % files.size(), broken, PackedStringArray())


func _find_scripts(dir: String, out: PackedStringArray) -> void:
	if dir.trim_suffix("/") in ["res://.godot", "res://android", "res://export", "res://plugins"]:
		return
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_find_scripts(dir.path_join(sub), out)
	for file in DirAccess.get_files_at(dir):
		if file.get_extension() == "gd":
			out.append(dir.path_join(file))


func check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok   ", name)
	else:
		failures += 1
		print("  FAIL ", name, "\n       got:  ", got, "\n       want: ", want)


func _versions() -> void:
	var n := func(a, b): return UpdateCheck.newer(a, b)
	check("v0.3.0 is newer than 0.2.6", n.call("v0.3.0", "0.2.6"), true)
	check("0.2.10 is newer than 0.2.9", n.call("0.2.10", "0.2.9"), true)
	check("v0.2.6 is not newer than 0.2.6", n.call("v0.2.6", "0.2.6"), false)
	check("v0.2.0 is not newer than 0.2.6", n.call("v0.2.0", "0.2.6"), false)
	check("1.0 is newer than 0.9.9", n.call("1.0", "0.9.9"), true)
	check("v0.3.0-beta counts as 0.3.0", n.call("v0.3.0-beta", "0.2.9"), true)


func _book_search() -> void:
	var plain := BookSearch.compile("mana (blue)", false)
	check("plain search ignores case and special characters", BookSearch.find_all(plain, "Mana (Blue) and mana (blue)"), [Vector2i(0, 11), Vector2i(16, 27)])
	check("regex search keeps case", BookSearch.find_all(BookSearch.compile("\\bArm\\b", true), "arm Arm harm Arm."), [Vector2i(4, 7), Vector2i(13, 16)])
	check("bad regex", BookSearch.compile("(", true), null)
	check("empty query", BookSearch.compile("", false), null)
	check("empty matches skipped", BookSearch.find_all(BookSearch.compile("x*", true), "ab"), [])
	check("snippet marks the match", BookSearch.snippet("a [b] c", Vector2i(2, 5), "f00"), "a [b][color=f00][lb]b[rb][/color][/b] c")
	check("snippet cuts at spaces", BookSearch.snippet("one two three four five", Vector2i(8, 13), "f00", 5), "…two [b][color=f00]three[/color][/b] four…")
	var bb := "He [i]said[/i] [lb]hi[rb]"
	var text := ReaderPage._visible_text(bb)
	check("search text has no tags", text, "He said [hi]")
	var span: Vector2i = BookSearch.find_all(BookSearch.compile("said [hi", false), text)[0]
	check("match marked across tags", ReaderPage._mark_span(bb, span.x, span.y, "<", ">"), "He [i]<said>[/i]< [lb]hi>[rb]")


func _sites() -> void:
	check("other sites keep plain keys", Library.chapter_key("https://example.com/a/"), "example.com/a")
	check("page number ignored", SavedSearches.normalize("https://example.com/search?page=3&q=a"), SavedSearches.normalize("https://www.example.com/search?q=a"))
	check("blocked detection", SourcePlugin.is_blocked({"code": 403, "text": "<title>Just a moment...</title>"}), true)
	check("element finds nested div", SourcePlugin.element("<div id=\"x\"><div>a</div><p>b</p></div><p>c</p>", "<div[^>]*id=\"x\""), "<div>a</div><p>b</p>")
	check("versions compare by number", Plugins.compare_versions("1.10.0", "1.9"), 1)
	check("github page to raw files", Plugins.github_raw("https://github.com/someone/plugins"), "https://raw.githubusercontent.com/someone/plugins/HEAD")
	check("github folder to raw files", Plugins.github_raw("https://github.com/someone/plugins/tree/main/mysite/"), "https://raw.githubusercontent.com/someone/plugins/main/mysite")
	var sp := SourcePlugin.new()
	check("library filter matches extra", sp.library_filter_matches({"extra": {"status": "completed"}}, "status", "completed"), true)
	check("library filter matches list", sp.library_filter_matches({"extra": {"genre": ["a", "b"]}}, "genre", "b"), true)
	check("library filter without extra", sp.library_filter_matches({}, "status", "completed"), false)
	_epub_matching()
	_series_parts()
	check("tags cleaned from text", Library.clean_tags(" Fantasy, litrpg ,, fantasy,  Slow   burn "), ["Fantasy", "litrpg", "Slow burn"])
	check("tags cleaned from a list", Library.clean_tags(["A", "", "a", "B"]), ["A", "B"])
	check("tag match ignores case", Library.has_tag({"tags": ["LitRPG"]}, "litrpg"), true)
	check("tag missing", Library.has_tag({"tags": []}, "litrpg"), false)
	check("page script builds", WebExtract.script().contains("function register("), true)
	_site_rules()
	_bookmarks()
	_paragraph_bookmarks()
	_storage()
	print("  plugins loaded: ", ", ".join(Plugins.plugins.map(func(p): return p.id)))
	for e in Plugins.entries:
		if e.error != "":
			check("plugin %s loads" % e.id, e.error, "")
	Plugins.run_tests(check)


## Chapters of an EPUB (e.g. from WebToEpub) matched with a web book's chapters.
func _epub_matching() -> void:
	var book := {"chapters": [
		{"title": "Chapter 1 - Start", "url": "https://example.com/s/1/chapter/11"},
		{"title": "Chapter 2: Middle", "url": "https://example.com/s/1/chapter/12"},
		{"title": "Interlude", "url": "https://example.com/s/1/chapter/13"},
		{"title": "Interlude", "url": "https://example.com/s/1/chapter/14"},
	]}
	var by_link := Library.match_epub_chapters(book, [
		{"title": "Information", "url": "https://example.com/s/1"},
		{"title": "Renamed", "url": "https://www.example.com/s/1/chapter/12/"},
		{"title": "Chapter 1 - Start", "url": "https://example.com/s/1/chapter/99"},
	])
	check("epub chapters match by link", by_link.map(func(p): return p[0]), [1])
	var by_title := Library.match_epub_chapters(book, [
		{"title": "chapter 2 - middle", "url": ""},
		{"title": "Interlude", "url": ""},
		{"title": "CHAPTER 1: START!", "url": ""},
	])
	check("epub chapters match by title, not ambiguous ones", by_title.map(func(p): return p[0]), [1, 0])
	var numbered := {"chapters": [{"title": "1. Start", "url": "https://example.com/s/9/1/"}, {"title": "2. Chapter 2", "url": "https://example.com/s/9/2/"},
		{"title": "3. Fallen", "url": "https://example.com/s/9/3/"}, {"title": "Chapter 4 - End", "url": "https://example.com/s/9/4/"}, {"title": "Chapter 44", "url": "https://example.com/s/9/44/"}]}
	var by_numbered := Library.match_epub_chapters(numbered, [{"title": "Chapter 2", "url": ""}, {"title": "Start", "url": ""},
		{"title": "Chapter 3", "url": ""}, {"title": "chapter 4", "url": ""}, {"title": "Chapter 5", "url": ""}])
	check("epub chapters match numbered titles and placeholder titles", by_numbered.map(func(p): return p[0]), [1, 0, 2, 3])


## A later EPUB of an imported serial (c486-496 after c1-485) adds only its new chapters.
func _series_parts() -> void:
	check("chapter range dropped from title", Library.series_title("The Path of Ascension - c486-496"), "The Path of Ascension")
	check("chapters in brackets dropped", Library.series_title("Some Story (Chapters 1-50)"), "Some Story")
	check("number-only title kept", Library.series_title("1984"), "1984")
	var book := {"title": "The Path Of Ascension", "author": "", "chapters": []}
	check("same series without author", Library.same_series(book, {"title": "The Path of Ascension - c486-496", "author": "C. Mantis"}), true)
	check("other book isn't the same series", Library.same_series(book, {"title": "The Path of Something", "author": ""}), false)
	check("chapter number after the book's title", Library.number_key("The Path Of Ascension Chapter 485", "thepathofascension"), "|485")
	check("side story keeps its name", Library.number_key("Poa: Aster’s Adventures Chapter 1", "thepathofascension"), "poaastersadventures|1")
	check("chapter number at start", Library.number_key("12. A Title"), "|12")
	check("no chapter number", Library.number_key("Volume 6"), "")
	var long_a := "A paragraph long enough to tell this chapter apart from every other chapter in the book."
	var long_b := "Another paragraph long enough to tell this chapter apart from every other one in the book."
	var have := [{"title": "Front Page"}, {"title": "Book Chapter 1"}, {"title": "Book Chapter 2"}, {"title": "Aster Plushies!"}]
	var text := [["Front"], [long_a], ["short"], [long_b]]
	var incoming := [
		{"title": "Chapter 2", "paragraphs": ["different text"]},
		{"title": "Plushies", "paragraphs": ["“" + long_b + "”"]},
		{"title": "Front Page", "paragraphs": ["Front"]},
		{"title": "Chapter 3", "paragraphs": ["new"]},
		{"title": "Interlude", "paragraphs": ["new too"]},
	]
	incoming.append({"title": "Side Story Chapter 1", "paragraphs": ["side"]})
	check("only new chapters are added", Library.unseen_chapters(have, text, incoming, "book").map(func(c): return c.title), ["Chapter 3", "Interlude", "Side Story Chapter 1"])
	var split := [{"title": "Chapter 7 (1/2)"}, {"title": "Chapter 7 (2/2)"}]
	check("repeated numbers aren't used", Library.unseen_chapters(split, [[], []], [{"title": "Chapter 7", "paragraphs": [long_a]}]).size(), 1)
	var mine := [{"title": "a", "url": ""}, {"title": "b", "url": ""}]
	var longer := [{"title": "a", "url": ""}, {"title": "b", "url": ""}, {"title": "c", "url": ""}]
	check("sync takes a longer list of an imported book", Sync._extended_chapters(mine, [{"chapters": longer}]).size(), 3)
	check("sync keeps a list that differs", Sync._extended_chapters(mine, [{"chapters": [{"title": "x"}, {"title": "b"}, {"title": "c"}]}]).size(), 2)


## Saved searches as bookmarks: new works are found on pages you open.
func _site_rules() -> void:
	check("site of a link", SiteRules.host_of("https://www.Example.com:8080/a/b?c#d"), "example.com")
	check("site of a bare address", SiteRules.host_of("example.com/x"), "example.com")
	check("rule covers subdomains", SiteRules.matches("example.com", "read.example.com"), true)
	check("rule doesn't cover lookalikes", SiteRules.matches("example.com", "badexample.com"), false)
	check("rule needs a site", SiteRules.validate({"host": "", "content": "#text"}) != "", true)
	check("rule needs a selector", SiteRules.validate({"host": "example.com"}) != "", true)
	var before: Array = Settings.get_value("site_rules")
	Settings.set_value("site_rules", [])
	SiteRules.save(SiteRules.new_rule("example.com").merged({"content": " #text "}, true))
	SiteRules.save(SiteRules.new_rule("https://read.example.com/").merged({"skip": ".note"}, true))
	SiteRules.save(SiteRules.new_rule("example.com").merged({"title": "h1"}, true))
	check("one rule per site", SiteRules.all().size(), 2)
	check("saving replaces the site's rule", SiteRules.for_host("example.com").get("content", ""), "")
	check("longest site wins", SiteRules.for_host("https://a.read.example.com/x").get("skip", ""), ".note")
	check("parent site rule", SiteRules.for_host("www.example.com").get("title", ""), "h1")
	check("page script gets rules", WebExtract.script().contains("\"skip\":\".note\""), true)
	Settings.set_value("site_rules", before)


func _bookmarks() -> void:
	var keep: Array = Settings.get_value("saved_searches")
	Settings.set_value("saved_searches", [{"id": "bm1", "name": "test", "url": "https://example.com/list?q=a", "limit": 20, "added": 0}])
	var page1 := ["https://example.com/w/1", "https://example.com/w/2"]
	check("not opened yet", SavedSearches.last_opened("bm1"), 0.0)
	SavedSearches.mark_opened("bm1")  # pressing Open, before the page has loaded
	check("opening is timed", SavedSearches.last_opened("bm1") > 0, true)
	check("first opening only takes note", SavedSearches.page_seen("https://example.com/list?q=a", page1), [])
	check("nothing new on the same page", SavedSearches.page_seen("https://example.com/list?q=a", page1), [])
	var page1b := ["https://example.com/w/3", "https://example.com/w/1", "https://example.com/w/2"]
	check("a new work is found", SavedSearches.page_seen("https://example.com/list?q=a", page1b), ["https://example.com/w/3"])
	check("and stays new on a reload", SavedSearches.page_seen("https://example.com/list?q=a&page=1", page1b), ["https://example.com/w/3"])
	check("page 2 belongs to the same search", SavedSearches.page_seen("https://example.com/list?q=a&page=2", ["https://example.com/w/4"]), ["https://example.com/w/4"])
	check("other pages aren't compared", SavedSearches.page_seen("https://example.com/list?q=b", ["https://example.com/w/9"]), [])
	check("count of the last opening", SavedSearches.last_found("bm1"), 1)
	Settings.set_value("saved_searches", keep)


## library.json plus a meta file per book; an old library.json (everything in
## one file) is converted when it's read.
func _storage() -> void:
	Library.flush()
	var keep: Array = Library.books
	var keep_tombs: Dictionary = Library.tombstones
	var path := Settings.data_dir() + "/library.json"
	var old := {"version": 1, "tombstones": {"example.com/gone": 5.0}, "books": [{
		"id": "oldbook1", "title": "Old", "author": "", "kind": "web", "source": "web", "url": "https://example.com/old",
		"cover": "", "cover_url": "", "synopsis": "", "tags": [], "chapters": [{"title": "A", "url": "https://example.com/old/1"}],
		"progress": {"chapter": 0, "paragraph": 3}, "added": 1.0, "last_read": 2.0, "last_checked": 0.0}]}
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(old))
	Library.books = []
	Library.tombstones = {}
	Library._load()
	check("old library read", Library.get_book("oldbook1").get("title", ""), "Old")
	check("old library: modified filled in", Library.get_book("oldbook1").get("modified"), 1.0)
	var index: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check("old library converted", index.version, 2.0)
	check("index keeps only what changes often", index.books[0].keys(), ["id", "last_read", "progress"])  # JSON.stringify sorts keys
	check("details in their own file", FileAccess.file_exists(Library._meta_path("oldbook1")), true)
	Library.set_progress("oldbook1", 0, 9)
	Library.flush()
	Library.books = []
	Library.tombstones = {}
	Library._load()
	var b := Library.get_book("oldbook1")
	check("position read back", b.get("progress"), {"chapter": 0, "paragraph": 9})
	check("details read back", b.get("url"), "https://example.com/old")
	check("tombstones read back", Library.tombstones, {"example.com/gone": 5.0})
	Library.remove_book("oldbook1", false)
	Library.flush()
	check("removed book's file deleted", FileAccess.file_exists(Library._meta_path("oldbook1")), false)
	Library.books = keep
	Library.tombstones = keep_tombs
	Library.save()
	Library.flush()


## Each saved chapter's word count is kept with the chapter and moves with it.
func _word_counts() -> void:
	var paras := PackedStringArray([HtmlText.HEADING + "Chapter 1", "He [i]didn't[/i] go—well-known, 42 times… *** [lb]ok[rb]"])
	check("words counted", Library.word_count(paras), 9)
	var b := Library.add_book({"title": "Word test", "kind": "web", "url": "https://example.com/wtest",
		"chapters": [{"title": "A", "url": "https://example.com/w/1"}, {"title": "B", "url": "https://example.com/w/2"}]})
	Library.store_chapter(b.id, 1, "B", PackedStringArray(["one two three"]))
	Library.store_chapter(b.id, 0, "A", PackedStringArray(["a preview"]), true)
	check("count kept with the chapter", b.chapters[1].get("words"), 3)
	check("previews aren't counted", b.chapters[0].has("words"), false)
	Library.replace_chapters(b.id, [{"title": "B", "url": "https://example.com/w/2"}, {"title": "C", "url": "https://example.com/w/3"}])
	check("count moves with the chapter", Library.get_book(b.id).chapters[0].get("words"), 3)
	b.chapters[0].erase("words")
	await Library._count_missing_words()
	check("missing counts filled in from the saved text", b.chapters[0].get("words"), 3)
	check("saved words added up", Library.saved_words(b), {"words": 3, "chapters": 1})
	check("short count", [ReaderPage._short_count(950), ReaderPage._short_count(8400), ReaderPage._short_count(84321), ReaderPage._short_count(1200000)], ["950", "8.4k", "84k", "1.2M"])
	check("grouped count", ReaderPage._grouped(1234567), "1,234,567")
	Library.remove_book(b.id, false)


## Named bookmarks at paragraphs of a book, and merging them in sync.
func _paragraph_bookmarks() -> void:
	var b := Library.add_book({"title": "Bookmark test", "kind": "web", "url": "https://example.com/bmtest",
		"chapters": [{"title": "A", "url": "https://example.com/c/1"}, {"title": "B", "url": "https://example.com/c/2"}]})
	var m := Library.add_bookmark(b.id, 1, 4, " Fight ", "Some text")
	var other := Library.add_bookmark(b.id, 0, 7, "", "")
	check("bookmarks in reading order", Library.bookmarks(b).map(func(x): return x.id), [other.id, m.id])
	check("bookmark name trimmed", m.name, "Fight")
	check("bookmark found by paragraph", Library.bookmark_at(b, 1, 4).get("id", ""), m.id)
	Library.replace_chapters(b.id, [{"title": "Prologue", "url": "https://example.com/c/0"}] + b.chapters)
	check("bookmark follows its chapter", Library.bookmark_at(b, 2, 4).get("id", ""), m.id)

	var remote: Array = Sync._book_file(b).bookmarks.duplicate(true)
	for r in remote:
		r.chapter = 0  # the other device numbers chapters differently; the chapter id matches
		if r.id == m.id:
			r.name = "Boss fight"
			r.modified += 10
		else:
			r.deleted = true
			r.modified += 10
	remote.append({"id": "remote1", "chapter_id": Sync._chapter_id_of(b.chapters[1], 1), "chapter": 9, "paragraph": 2,
		"name": "From phone", "text": "", "created": 1, "modified": 1, "deleted": false})
	Library.set_bookmarks(b.id, Sync._merged_bookmarks(b, [{"bookmarks": remote}]))
	check("newer rename wins", Library.bookmark_at(b, 2, 4).get("name", ""), "Boss fight")
	check("removal syncs", Library.bookmark_at(b, 1, 7).is_empty(), true)
	check("new bookmark added by chapter id", Library.bookmark_at(b, 1, 2).get("name", ""), "From phone")
	var old: Array = [Library.bookmark_at(b, 2, 4).merged({"name": "Old name", "modified": 0})]
	check("older change loses", Sync._merged_bookmarks(b, [{"bookmarks": old}]) == b.bookmarks, true)
	Library.remove_book(b.id, false)


func _rules() -> void:
	TextRules.add_rule(TextRules.new_rule({"pattern": "HP", "replace": "health points", "whole_word": true, "scope": "tts"}))
	TextRules.add_rule(TextRules.new_rule({"pattern": "\\[[^\\]]+\\]", "replace": " ", "regex": true, "scope": "tts"}))
	TextRules.add_rule(TextRules.new_rule({"pattern": "Aisha", "replace": "Aysha", "scope": "display"}))
	TextRules.add_rule(TextRules.new_rule({"pattern": "\\[Note\\]", "replace": "", "regex": true, "scope": "display"}))
	TextRules.add_rule(TextRules.new_rule({"pattern": "(\\d+)%", "replace": "$1 percent", "regex": true, "scope": "both"}))
	TextRules.add_rule(TextRules.new_rule({"pattern": "ahab", "replace": "Ay-hab", "ignore_case": true, "book": "book-a", "scope": "tts"}))
	check("tts whole word", TextRules.apply_tts("HP and HPs"), "health points and HPs")
	check("tts regex removes brackets", TextRules.apply_tts("Hit [Skill: Bash] now"), "Hit   now")
	check("display keeps italics", TextRules.apply_display("[i]Aisha[/i] said"), "[i]Aysha[/i] said")
	check("display sees real brackets", TextRules.apply_display("[lb]Note[rb] hello"), " hello")
	check("display leaves tts-only rules alone", TextRules.apply_display("HP [lb]x[rb]"), "HP [lb]x[rb]")
	check("both scope + group ref (tts)", TextRules.apply_tts("50% done"), "50 percent done")
	check("both scope + group ref (display)", TextRules.apply_display("50% done"), "50 percent done")
	check("per-book rule applies to its book", TextRules.apply_tts("AHAB ran", "book-a"), "Ay-hab ran")
	check("per-book rule skips other books", TextRules.apply_tts("AHAB ran", "book-b"), "AHAB ran")
	check("plain mode escapes regex chars", TextRules.preview("a.b axb", TextRules.new_rule({"pattern": "a.b", "replace": "$", "scope": "tts"})).tts, "$ axb")
	check("invalid regex is reported", TextRules.validate(TextRules.new_rule({"pattern": "(", "regex": true})) != "", true)
	var json := TextRules.export_json()
	var before := TextRules.rules.size()
	check("import round trip", TextRules.import_json(json), before)
	TextRules.rules.clear()
	TextRules._commit()


func _sentences() -> void:
	check("sentence split", Array(Speech.split_sentences("Mr. Smith went home. He said “Hi!” Then J. R. left… Done")),
		["Mr. Smith went home.", "He said “Hi!”", "Then J. R. left…", "Done"])
	check("invisible filler paragraph is skipped", Array(Speech.split({"text": "ㅤ ​", "kind": "p"})), [])
	var bb := "One [i]two. Three[/i] [lb]4[rb]."
	check("visible text", ReaderPage._visible_text(bb), "One two. Three [4].")
	check("mark sentence across tags", ReaderPage._mark_span(bb, 9, 19, "<", ">"), "One [i]two. <Three>[/i]< [lb]4[rb].>")


func _pacing() -> void:
	if not Speech.is_supported():
		print("  skip pacing (no TTS)")
		return
	Settings.set_value("tts_volume", 0)
	Settings.set_value("tts_mode", "sentence")
	Settings.set_value("tts_pause_sentence", 400)
	Settings.set_value("tts_pause_paragraph", 800)
	Settings.set_value("tts_read_headings", false)
	var started: Array = []
	var cb := func(i): started.append(i)
	Speech.paragraph_started.connect(cb)
	var t0 := Time.get_ticks_msec()
	Speech.play([{"text": "Title", "kind": "title"}, {"text": "One. Two.", "kind": "p"}, {"text": "* * *", "kind": "p"}, {"text": "Three.", "kind": "p"}], 0)
	await Speech.reached_end
	var ms := Time.get_ticks_msec() - t0
	Speech.paragraph_started.disconnect(cb)
	check("all paragraphs visited", started, [0, 1, 2, 3])
	# one sentence gap (400) + paragraph gap after "Two." (800); title and "* * *" are skipped
	check("pauses add up (>= 1200 ms, took %d)" % ms, ms >= 1200, true)

	# zero pauses: utterances are queued ahead, every paragraph is still reported in order
	Settings.set_value("tts_mode", "paragraph")
	Settings.set_value("tts_pause_paragraph", 0)
	Settings.set_value("tts_pause_heading", 0)
	Settings.set_value("tts_read_headings", true)
	started.clear()
	Speech.paragraph_started.connect(cb)
	Speech.play([{"text": "Title", "kind": "title"}, {"text": "One. Two.", "kind": "p"}, {"text": "* * *", "kind": "p"}, {"text": "Three.", "kind": "p"}, {"text": "Four.", "kind": "p"}], 0)
	await Speech.reached_end
	Speech.paragraph_started.disconnect(cb)
	check("zero-pause paragraphs visited", started, [0, 1, 2, 3, 4])

	# Windows: clips are rendered ahead and trimmed, so zero pauses mean (almost) no gap
	if Speech._win:
		Settings.set_value("tts_mode", "sentence")
		Settings.set_value("tts_pause_sentence", 0)
		Speech._win.max_gap_ms = 0
		Speech._win._ended_at = 0
		Speech.play([{"text": "The rain had not stopped for three days. The river climbed the steps of the mill. Nobody said a word. Then the bell rang.", "kind": "p"}, {"text": "She ran.", "kind": "p"}], 0)
		await Speech.reached_end
		check("windows helper in use", Speech._win != null and not Speech._win.is_broken(), true)
		check("windows gap between clips < 60 ms (was %d)" % Speech._win.max_gap_ms, Speech._win.max_gap_ms < 60, true)

		# SAPI5 voices (e.g. RHVoice), which Godot doesn't list, are offered and play
		var sapi: Array = Speech._win.sapi_voices
		check("windows lists SAPI5 voices", sapi.size() > 0, true)
		if sapi.size() > 0:
			check("SAPI5 voices in voices()", Speech.voices().any(func(v): return v.id == sapi[0].id), true)
			var before = Settings.get_value("tts_voice")
			Settings.set_value("tts_voice", sapi[0].id)
			check("SAPI5 voice selectable", Speech.voice_id(), sapi[0].id)
			started.clear()
			Speech.paragraph_started.connect(cb)
			Speech.play([{"text": "A classic voice & <markup>.", "kind": "p"}, {"text": "Done.", "kind": "p"}], 0)
			await Speech.reached_end
			Speech.paragraph_started.disconnect(cb)
			Settings.set_value("tts_voice", before)
			check("SAPI5 voice %s plays" % sapi[0].name, started, [0, 1])
			check("windows helper still in use", Speech._win != null and not Speech._win.is_broken(), true)
			# Text a SAPI voice renders to no audio at all must not disable the helper
			Speech._win.speak("ㅤ", sapi[0].id, 0, 1.0, 1.0, 999)
			var ended_id = await Speech._win.ended
			check("SAPI5 silent clip plays", ended_id, 999)
			check("windows helper survives a silent clip", Speech._win != null and not Speech._win.is_broken(), true)


# --- fetch manager (Net) against a small local server ---------------------------

var _server: TCPServer
var _hits: Array = []        # [path, msec] in arrival order
var _busy_once := {}         # paths that answer 429 the first time


func _fetch_manager() -> void:
	_server = TCPServer.new()
	var port := 0
	for p in range(18431, 18451):
		if _server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	if port == 0:
		check("local test server starts", false, true)
		return
	_serve()
	var base := "http://127.0.0.1:%d" % port
	Net.set_sites({"127.0.0.1": 0.5})
	check("queue of a plugin's site", Net.lane_key(base + "/a"), "127.0.0.1")
	check("www shares the site's queue", Net.lane_key("https://www.Example.com/x"), "example.com")
	check("images on a plugin's site share its queue", Net.lane_key(base + "/a.png"), "127.0.0.1")
	check("images on other hosts share that host's queue", Net.lane_key("https://cdn.example/a.png"), "cdn.example")
	check("header read", Net.header(PackedStringArray(["Retry-After: 2"]), "retry-after"), "2")

	# Three requests at once go one after another, with the gap between them.
	_hits.clear()
	var results := []
	for path in ["/a", "/b", "/c"]:
		_collect(func(): return await Net.get_text(base + path), results)
	await _until(func(): return results.size() == 3)
	check("paced requests all succeed", results.all(func(r): return r.ok), true)
	check("one request at a time", _hits.map(func(h): return h[0]), ["/a", "/b", "/c"])
	check("gap between requests", _hits.size() == 3 and _hits[1][1] - _hits[0][1] >= 450 and _hits[2][1] - _hits[1][1] >= 450, true)

	# The same GET asked for twice at once is sent once.
	_hits.clear()
	results = []
	_collect(func(): return await Net.get_text(base + "/same"), results)
	_collect(func(): return await Net.get_text(base + "/same"), results)
	await _until(func(): return results.size() == 2)
	check("same GET shared", _hits.size(), 1)
	check("both callers get it", results.map(func(r): return r.text), ["ok /same", "ok /same"])

	# A busy reply pauses the site for its Retry-After, then the request is tried again.
	_hits.clear()
	_busy_once["/busy"] = true
	var t := Time.get_ticks_msec()
	var r: Dictionary = await Net.get_text(base + "/busy")
	check("busy site retried", [r.ok, _hits.size()], [true, 2])
	check("waited for Retry-After", Time.get_ticks_msec() - t >= 950, true)

	# An image asked for while pages are waiting goes ahead of them.
	await get_tree().create_timer(0.6).timeout
	_hits.clear()
	results = []
	for path in ["/p1", "/p2", "/p3"]:
		_collect(func(): return await Net.get_text(base + path), results)
	await get_tree().process_frame
	_collect(func(): return {"ok": await Net.get_image(base + "/i.png") == null}, results)
	await _until(func(): return results.size() == 4)
	check("image jumps the page queue", _hits.map(func(h): return h[0]), ["/p1", "/i.png", "/p2", "/p3"])

	# A bot check is remembered for the site.
	t = Time.get_ticks_msec()
	check("no bot check yet", Net.blocked_since(base + "/a", t), false)
	r = await Net.get_text(base + "/cf")
	check("bot check remembered", Net.blocked_since(base + "/other", t), true)

	# Images nobody wants any more aren't downloaded; unpaced requests skip the queue.
	_hits.clear()
	check("unwanted image dropped", await Net.get_image(base + "/x.png", func(): return false), null)
	check("nothing sent for it", _hits.size(), 0)
	await get_tree().create_timer(0.6).timeout
	t = Time.get_ticks_msec()
	await Net.get_text(base + "/u1", [], 30.0, false)
	await Net.get_text(base + "/u2", [], 30.0, false)
	check("unpaced requests don't wait", Time.get_ticks_msec() - t < 450, true)

	# A long Retry-After is honoured in full: the site's queue fails at once instead of waiting.
	await get_tree().create_timer(0.6).timeout
	_hits.clear()
	r = await Net.get_text(base + "/long")
	check("long break fails the request", [r.ok, r.code, _hits.size()], [false, 429, 1])
	t = Time.get_ticks_msec()
	r = await Net.get_text(base + "/after")
	check("nothing sent during a long break", [r.ok, _hits.size(), Time.get_ticks_msec() - t < 450], [false, 1, true])
	Net._lanes.erase("127.0.0.1")

	# With "http_keep_waits" on, a wait a site asked for holds after restarts; turned off, a restart clears it.
	DirAccess.remove_absolute(Net._waits_path())
	Settings.set_value("http_keep_waits", false)
	Net._keep_wait("waits.test", 300.0)
	check("setting off: wait not kept", FileAccess.file_exists(Net._waits_path()), false)
	Settings.set_value("http_keep_waits", true)
	Net._keep_wait("waits.test", 300.0)
	Net._restore_waits()
	var left: int = Net._lanes["waits.test"].next_start - Time.get_ticks_msec()
	check("kept wait holds after a restart", [left > 290000, left <= 300000], [true, true])
	Net._lanes.erase("waits.test")
	Net._restore_waits()
	check("and after another restart", Net._lanes.has("waits.test"), true)
	Net._lanes.erase("waits.test")
	Settings.set_value("http_keep_waits", false)
	Net._restore_waits()
	check("setting off: restart clears it", [Net._lanes.has("waits.test"), FileAccess.file_exists(Net._waits_path())], [false, false])
	Settings.set_value("http_keep_waits", Settings.DEFAULTS.http_keep_waits)

	# A page with an ETag is asked for again with If-None-Match; a 304 gives back the kept copy.
	var page := base + "/etag?%d" % Time.get_ticks_usec()
	_hits.clear()
	r = await Net.get_text(page)
	var again: Dictionary = await Net.get_text(page)
	check("kept page reused on 304", [r.text, again.ok, again.code, again.text], ["fresh", true, 200, "fresh"])
	check("asked with If-None-Match", _hits.map(func(h): return h[2]), [false, true])
	# Images (covers) are kept the same way, in their own folder.
	var img_url := base + "/etag-img?%d" % Time.get_ticks_usec()
	_hits.clear()
	r = await Net.request(img_url, ["Accept: image/*"], 20.0, HTTPClient.METHOD_GET, "", true, Callable(), true)
	again = await Net.request(img_url, ["Accept: image/*"], 20.0, HTTPClient.METHOD_GET, "", true, Callable(), true)
	check("kept image reused on 304", [again.ok, again.get("not_modified", false), again.body.get_string_from_utf8()], [true, true, "fresh"])
	check("image asked with If-None-Match", _hits.map(func(h): return h[2]), [false, true])
	check("image kept in its own folder", FileAccess.file_exists(Net._cache_path(img_url, ["Accept: image/*"], true) + ".bin"), true)
	Settings.set_value("http_revalidate", false)
	_hits.clear()
	await Net.get_text(page)
	check("setting off: plain request", _hits.map(func(h): return h[2]), [false])
	Settings.set_value("http_revalidate", true)
	check("conditional headers", Net.conditional_headers({"etag": "\"v1\"", "last_modified": ""}), PackedStringArray(["If-None-Match: \"v1\""]))

	# A site that isn't answering gets a break: requests fail at once, and the next break is longer.
	check("server error means down", [Net.site_down({"code": 502}), Net.site_down({"code": 503}), Net.site_down({"code": 404}),
		Net.site_down({"code": 0, "result": HTTPRequest.RESULT_TIMEOUT}), Net.site_down({"code": 0, "result": HTTPRequest.RESULT_CANT_RESOLVE})],
		[true, false, false, true, false])
	_hits.clear()
	r = await Net.get_text(base + "/down")
	t = Time.get_ticks_msec()
	var r2: Dictionary = await Net.get_text(base + "/after-down")
	check("down site: nothing sent during its break", [r.code, r2.ok, _hits.size(), Time.get_ticks_msec() - t < 450], [502, false, 1, true])
	check("next break is longer", Net._lanes["127.0.0.1"].down_wait, Net.DOWN_WAIT_FIRST * Net.DOWN_WAIT_GROWTH)
	Net.end_break(base + "/x")
	r = await Net.get_text(base + "/retry")
	check("retry ends the break", [r.ok, _hits.size()], [true, 2])
	Net._lanes.erase("127.0.0.1")
	_server.stop()
	_server = null
	Net.set_sites({})


func _collect(job: Callable, into: Array) -> void:
	into.append(await job.call())


func _until(cond: Callable, seconds := 10.0) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _serve() -> void:
	var open: Array[StreamPeerTCP] = []
	while _server != null:
		while _server.is_connection_available():
			open.append(_server.take_connection())
		for c: StreamPeerTCP in open.duplicate():
			c.poll()
			if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				open.erase(c)
				continue
			if c.get_available_bytes() == 0:
				continue
			var req: String = c.get_utf8_string(c.get_available_bytes())
			var path := req.get_slice(" ", 1)
			_hits.append([path, Time.get_ticks_msec(), "if-none-match:" in req.to_lower()])
			var reply := "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [("ok " + path).length(), "ok " + path]
			if path == "/long":
				reply = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3600\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbusy"
			elif path.begins_with("/etag"):
				if "if-none-match: \"v1\"" in req.to_lower():
					reply = "HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
				else:
					reply = "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nContent-Length: 5\r\nConnection: close\r\n\r\nfresh"
			elif path == "/down":
				reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndown"
			elif path == "/cf":
				reply = "HTTP/1.1 403 Forbidden\r\nContent-Length: 16\r\nConnection: close\r\n\r\nJust a moment..."
			if _busy_once.get(path, false):
				_busy_once.erase(path)
				reply = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbusy"
			c.put_data(reply.to_utf8_buffer())
			c.disconnect_from_host()
			open.erase(c)
		await get_tree().process_frame
