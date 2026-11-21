extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).

## A plugin that offers its own tags, so the picker can prefer them.
class StubTags extends SourcePlugin:
	func library_tags(_book: Dictionary) -> Array:
		return ["Offered"]


func run(t: Node) -> void:
	await t.get_tree().process_frame
	_search(t)
	_novel(t)
	_chapter_text(t)
	_remove(t)
	_details(t)


func _search(t: Node) -> void:
	var good := Sources.norm_search({"results": [
		{"title": "T", "url": "https://example.com/1", "cover_url": "c", "info": "i"}], "error": ""}, "Plug")
	t.check("search keeps a good result", good,
		{"results": [{"title": "T", "url": "https://example.com/1", "cover_url": "c", "info": "i"}],
		"error": "", "blocked": false})
	var mixed := Sources.norm_search({"results": [
		{"title": "No link"}, "junk",
		{"title": "T2", "url": "https://example.com/2", "cover_url": 7}], "error": ""}, "Plug")
	t.check("search drops items without a link", mixed,
		{"results": [{"title": "T2", "url": "https://example.com/2", "cover_url": "7", "info": ""}],
		"error": "", "blocked": false})
	t.check("search keeps an error", Sources.norm_search({"error": "nope"}, "Plug"),
		{"results": [], "error": "nope", "blocked": false})
	t.check("broken search names the plugin", Sources.norm_search("junk", "Plug"),
		{"results": [], "error": "Plug returned a broken search response."})


func _novel(t: Node) -> void:
	var good := Sources.norm_novel({"title": "B", "author": "A", "url": "https://example.com/b",
		"cover_url": "", "synopsis": "S", "tags": ["x"], "extra": {"status": "done"}, "words": 42,
		"chapters": [{"title": "C1", "url": "https://example.com/b/1", "date": 7,
		"excerpt_html": "<p>hi</p>"}]}, "Plug", "https://example.com/fallback")
	t.check("novel keeps good data", good, {"novel": {"title": "B", "author": "A",
		"url": "https://example.com/b", "cover_url": "", "synopsis": "S", "tags": ["x"],
		"extra": {"status": "done"}, "words": 42, "chapters": [{"title": "C1",
		"url": "https://example.com/b/1", "date": 7, "excerpt_html": "<p>hi</p>"}]}})
	var mixed := Sources.norm_novel({"title": "B", "tags": "nope",
		"chapters": [{"title": "Lost"}, {"title": "C2", "url": "https://example.com/b/2", "date": "soon"}]},
		"Plug", "https://example.com/fallback")
	t.check("novel drops chapters without a link", mixed, {"novel": {"title": "B", "author": "",
		"url": "https://example.com/fallback", "cover_url": "", "synopsis": "", "tags": [],
		"words": 0, "chapters": [{"title": "C2", "url": "https://example.com/b/2", "date": 0}]}})
	t.check("novel without chapters names the plugin",
		Sources.norm_novel({"title": "B"}, "Plug"),
		{"error": "Plug returned a book without chapters."})
	t.check("novel without a title names the plugin",
		Sources.norm_novel({"chapters": [{"title": "C", "url": "https://example.com/b/1"}]}, "Plug"),
		{"error": "Plug returned a book without a title."})
	t.check("novel that isn't a book names the plugin", Sources.norm_novel([], "Plug"),
		{"error": "Plug returned a book without details."})
	t.check("chapter without a link is dropped", Sources.norm_chapter({"title": "x"}), {})


func _chapter_text(t: Node) -> void:
	t.check("chapter keeps good paragraphs",
		Sources.norm_chapter_text({"title": "C", "paragraphs": ["a", "b"], "error": ""}, "Plug"),
		{"title": "C", "paragraphs": PackedStringArray(["a", "b"]), "error": ""})
	t.check("chapter drops blank and non-text paragraphs",
		Sources.norm_chapter_text({"paragraphs": ["", "  ", 5, "ok"]}, "Plug"),
		{"title": "", "paragraphs": PackedStringArray(["ok"]), "error": ""})
	t.check("chapter keeps an error",
		Sources.norm_chapter_text({"error": "blocked"}, "Plug"),
		{"title": "", "paragraphs": PackedStringArray(), "error": "blocked"})
	t.check("broken chapter names the plugin", Sources.norm_chapter_text(42, "Plug"),
		{"title": "", "paragraphs": PackedStringArray(), "error": "Plug returned a broken chapter."})


## Hand-edited titles and tags of web books, and what the Tag picker offers.
func _details(t: Node) -> void:
	t.check("imported book edits title, author, description and tags",
		Library.editable_fields({"kind": "epub", "url": ""}), ["title", "author", "synopsis", "tags"])
	t.check("web book edits title and tags",
		Library.editable_fields({"kind": "web", "source": "selftest-stub", "url": "https://example.com/b/1"}), ["title", "tags"])
	t.check("other book edits nothing",
		Library.editable_fields({"kind": "txt", "url": "https://example.com/f"}), [])
	var b := Library.add_book({"title": "Edit test", "kind": "web", "source": "selftest-stub",
		"url": "https://example.com/b/1", "author": "Old", "synopsis": "Old S", "tags": ["A"]})
	t.check("web book title change works", Library.edit_details(b.id, {"title": "  New  "}), "")
	t.check("title trimmed", Library.get_book(b.id).get("title", ""), "New")
	t.check("empty title is an error", Library.edit_details(b.id, {"title": "  "}), "The title can't be empty")
	t.check("failed edit keeps the title", Library.get_book(b.id).get("title", ""), "New")
	Library.edit_details(b.id, {"author": "New A", "synopsis": "New S", "tags": ["B"]})
	b = Library.get_book(b.id)
	t.check("web book ignores the author", b.get("author", ""), "Old")
	t.check("web book ignores the description", b.get("synopsis", ""), "Old S")
	t.check("tag change marks them set by hand", [b.get("tags", []), b.get("tags_set", false)], [["B"], true])
	t.check("synced file keeps tags_set", Sync._book_file(b, "").get("tags_set", "missing"), true)
	var f := Library.add_book({"title": "File test", "kind": "epub", "url": "", "tags": ["A"]})
	Library.edit_details(f.id, {"tags": ["B"], "author": "Me"})
	f = Library.get_book(f.id)
	t.check("imported edit changes the tags", f.get("tags", []), ["B"])
	t.check("imported edit leaves tags_set alone", f.get("tags_set", false), false)
	Library.remove_book(b.id, false)
	Library.remove_book(f.id, false)
	t.check("no plugin means the book's tags", Library.picker_tags({"source": "selftest-ghost", "tags": ["Mine"], "tags_set": false}), ["Mine"])
	var stub := StubTags.new()
	stub.id = "selftest-stub"
	Plugins.plugins.append(stub)
	t.check("picker offers the plugin's tags", Library.picker_tags({"source": "selftest-stub", "tags": ["Mine"], "tags_set": false}), ["Offered"])
	t.check("hand-set tags win over the plugin's", Library.picker_tags({"source": "selftest-stub", "tags": ["Mine"], "tags_set": true}), ["Mine"])
	Plugins.plugins.erase(stub)


func _remove(t: Node) -> void:
	var keep: Dictionary = Plugins.records.duplicate(true)
	Plugins.remove("selftest-ghost")
	t.check("remove of a never-installed plugin writes no tombstone",
		Plugins.records.has("selftest-ghost"), false)
	DirAccess.make_dir_recursive_absolute(Plugins.installed_dir().path_join("selftest-ghost"))
	Plugins.remove("selftest-ghost")
	t.check("remove of an installed plugin writes a tombstone",
		Plugins.records.get("selftest-ghost", {}).get("removed", false), true)
	Plugins.records = keep
	Plugins._save_records()
