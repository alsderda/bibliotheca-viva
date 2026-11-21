extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).

## A plugin with controllable quick and full results that counts its calls.
class Fake extends SourcePlugin:
	var latest: Variant = {}
	var novel: Variant = {}
	var latest_calls := 0
	var novel_calls := 0
	func fetch_latest(_url: String) -> Dictionary:
		latest_calls += 1
		return latest
	func fetch_novel(_url: String) -> Dictionary:
		novel_calls += 1
		return novel


## A plugin without fetch_latest (the base default {} = not supported).
class NoQuick extends SourcePlugin:
	var novel: Variant = {}
	var novel_calls := 0
	func fetch_novel(_url: String) -> Dictionary:
		novel_calls += 1
		return novel


func run(t: Node) -> void:
	await t.get_tree().process_frame
	_latest(t)
	_due(t)
	_back(t)
	await _no_quick(t)
	await _quick_reaches(t)
	await _quick_gap(t)
	await _rss_gap(t)
	await _stale_full(t)
	await _empty_or_never(t)
	await _blocked(t)
	await _malformed(t)


func _ch(n: int) -> Dictionary:
	return {"title": "C%d" % n, "url": "https://example.com/b/%d" % n, "date": 1000 + n}


func _novel(chapters: Array, extra := {}, words := 0, rss_only := false) -> Dictionary:
	var d := {"novel": {"title": "B", "author": "A", "url": "https://example.com/b",
		"chapters": chapters}, "error": ""}
	if not extra.is_empty():
		(d.novel as Dictionary).extra = extra
	if words > 0:
		(d.novel as Dictionary).words = words
	if rss_only:
		d.rss_only = true
	return d


func _book(chapters: Array, last_full_check: float, extra := {}, words := 0) -> Dictionary:
	return Library.add_book({"title": "Update test", "kind": "web", "source": "selftest-update",
		"url": "https://example.com/b", "chapters": chapters, "extra": extra,
		"total_words": words, "last_full_check": last_full_check,
		"last_checked": Time.get_unix_time_from_system() - 100})


func _latest(t: Node) -> void:
	t.check("latest keeps good chapters", Sources.norm_latest({"chapters": [
		{"title": "C1", "url": "https://example.com/b/1", "date": 7, "excerpt_html": "<p>hi</p>"},
		{"title": "C2", "url": "https://example.com/b/2"}]}, "Plug"), {"chapters": [
		{"title": "C1", "url": "https://example.com/b/1", "date": 7, "excerpt_html": "<p>hi</p>"},
		{"title": "C2", "url": "https://example.com/b/2", "date": 0}]})
	t.check("latest refuses a non-dictionary", Sources.norm_latest("junk", "Plug"), {})
	t.check("latest refuses emptiness", Sources.norm_latest({}, "Plug"), {})
	t.check("latest refuses a plain error", Sources.norm_latest({"error": "down"}, "Plug"), {})
	t.check("latest keeps a block", Sources.norm_latest({"error": "turned away", "blocked": true}, "Plug"),
		{"error": "turned away", "blocked": true})
	t.check("latest refuses an empty list", Sources.norm_latest({"chapters": []}, "Plug"), {})
	t.check("latest refuses chapters that aren't a list",
		Sources.norm_latest({"chapters": "nope"}, "Plug"), {})
	t.check("latest refuses a list with a chapter without a link", Sources.norm_latest({"chapters": [
		{"title": "C1", "url": "https://example.com/b/1"}, {"title": "Lost"}]}, "Plug"), {})


func _due(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var ch := [{"url": "https://example.com/b/1"}]
	t.check("full check due without chapters", Sources.full_check_due({"chapters": []}, now), true)
	t.check("full check due when never checked",
		Sources.full_check_due({"chapters": ch, "last_full_check": 0}, now), true)
	t.check("full check due when the stamp is missing",
		Sources.full_check_due({"chapters": ch}, now), true)
	t.check("full check due after a week", Sources.full_check_due(
		{"chapters": ch, "last_full_check": now - 7.0 * 86400.0 - 60.0}, now), true)
	t.check("full check not due just before a week", Sources.full_check_due(
		{"chapters": ch, "last_full_check": now - 7.0 * 86400.0 + 3600.0}, now), false)
	t.check("full check not due when fresh", Sources.full_check_due(
		{"chapters": ch, "last_full_check": now - 60.0}, now), false)


func _back(t: Node) -> void:
	var book := {"chapters": [{"url": "https://example.com/b/1"}, {"url": "https://example.com/b/2"}]}
	t.check("quick list reaching back", Sources.reaches_back(book,
		[{"url": "https://example.com/b/2"}, {"url": "https://example.com/b/3"}]), true)
	t.check("quick list with a gap", Sources.reaches_back(book,
		[{"url": "https://example.com/b/9"}]), false)
	t.check("empty quick list reaches nowhere", Sources.reaches_back(book, []), false)
	t.check("quick list against an empty book",
		Sources.reaches_back({"chapters": []}, [{"url": "https://example.com/b/1"}]), false)


## 1. A plugin without fetch_latest gets fetch_novel called, same as today.
func _no_quick(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := NoQuick.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.novel = _novel([_ch(1), _ch(2), _ch(3), _ch(4)], {"status": "done"}, 42)
	var b := _book([_ch(1), _ch(2)], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("no quick list calls fetch_novel", fake.novel_calls, 1)
	t.check("no quick list adds new chapters", r.get("new", -1), 2)
	t.check("no quick list reports first_new", r.get("first_new", -1), 2)
	b = Library.get_book(b.id)
	t.check("no quick list keeps every chapter",
		b.chapters.map(func(c): return c.title), ["C1", "C2", "C3", "C4"])
	t.check("no quick list stores extra", b.get("extra", {}), {"status": "done"})
	t.check("no quick list stores total_words", b.get("total_words", 0), 42)
	t.check("no quick list stamps the full check", b.get("last_full_check", 0) >= now, true)
	t.check("no quick list clears a gap", b.get("possible_gap", true), false)
	Library.remove_book(b.id, false)


## 2. A quick list whose oldest chapter is known appends only the new ones.
func _quick_reaches(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [_ch(3), _ch(4), _ch(5)], "error": ""}
	fake.novel = {"error": "must not be called"}
	var b := _book([_ch(1), _ch(2), _ch(3)], now, {"status": "old"}, 7)
	var before: float = b.get("last_checked", 0)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("quick check leaves fetch_novel alone", fake.novel_calls, 0)
	t.check("quick check finds the new chapters", r.get("new", -1), 2)
	t.check("quick check reports first_new", r.get("first_new", -1), 3)
	b = Library.get_book(b.id)
	t.check("quick check appends only the new ones",
		b.chapters.map(func(c): return c.title), ["C1", "C2", "C3", "C4", "C5"])
	t.check("quick check leaves extra alone", b.get("extra", {}), {"status": "old"})
	t.check("quick check leaves total_words alone", b.get("total_words", 0), 7)
	t.check("quick check leaves last_full_check alone", b.get("last_full_check", -1), now)
	t.check("quick check stamps last_checked", b.get("last_checked", 0) > before, true)
	Library.remove_book(b.id, false)


## 3. A quick list whose oldest chapter is unknown triggers fetch_novel.
func _quick_gap(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [_ch(9), _ch(10)], "error": ""}
	var full := [_ch(1), _ch(2), _ch(3), _ch(4), _ch(5), _ch(6), _ch(7), _ch(8), _ch(9), _ch(10)]
	fake.novel = _novel(full, {"status": "done"}, 100)
	var b := _book([_ch(1), _ch(2)], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("gapped quick list calls fetch_novel", fake.novel_calls, 1)
	t.check("gapped quick list adds the missing chapters", r.get("new", -1), 8)
	b = Library.get_book(b.id)
	t.check("gapped quick list keeps every chapter", b.chapters.size(), 10)
	t.check("full check after a gap stamps the full check", b.get("last_full_check", 0) >= now, true)
	t.check("full check after a gap clears a gap", b.get("possible_gap", true), false)
	Library.remove_book(b.id, false)


## 4. A short rss_only fallback with a gap flags it and isn't a full check.
func _rss_gap(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [_ch(9), _ch(10)], "error": ""}
	fake.novel = _novel([_ch(9), _ch(10)], {}, 0, true)
	var b := _book([_ch(1), _ch(2)], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("rss fallback merges its chapters", r.get("new", -1), 2)
	b = Library.get_book(b.id)
	t.check("rss fallback keeps every chapter",
		b.chapters.map(func(c): return c.title), ["C1", "C2", "C9", "C10"])
	t.check("rss fallback flags a gap", b.get("possible_gap", false), true)
	t.check("rss fallback leaves last_full_check alone", b.get("last_full_check", -1), now)
	Library.remove_book(b.id, false)
	var reaching := Fake.new()
	reaching.id = "selftest-update"
	reaching.name = "UpdatePlug"
	reaching.latest = {}
	reaching.novel = _novel([_ch(2), _ch(3)], {}, 0, true)
	var g := Library.add_book({"title": "Update test", "kind": "web", "source": "selftest-update",
		"url": "https://example.com/b", "chapters": [_ch(1), _ch(2)],
		"last_full_check": now, "possible_gap": true,
		"last_checked": Time.get_unix_time_from_system() - 100})
	r = await Sources._refresh(reaching, g, true)
	g = Library.get_book(g.id)
	t.check("rss fallback reaching back leaves the flag alone", g.get("possible_gap", "missing"), true)
	t.check("rss fallback reaching back leaves last_full_check alone", g.get("last_full_check", -1), now)
	Library.remove_book(g.id, false)


## 5. A stale last_full_check triggers the full check even with no gap.
func _stale_full(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [_ch(3), _ch(4)], "error": ""}
	fake.novel = _novel([_ch(1), _ch(2), _ch(3), _ch(4)])
	var b := _book([_ch(1), _ch(2), _ch(3)], now - 8.0 * 86400.0)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("stale full check reads the whole list", fake.novel_calls, 1)
	t.check("stale full check adds the new chapter", r.get("new", -1), 1)
	b = Library.get_book(b.id)
	t.check("stale full check stamps the full check again", b.get("last_full_check", 0) >= now, true)
	Library.remove_book(b.id, false)


## 6. A book with no chapters, or never fully checked, gets the full check.
func _empty_or_never(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [_ch(1)], "error": ""}
	fake.novel = _novel([_ch(1), _ch(2)])
	var b := _book([], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("empty book calls fetch_novel", fake.novel_calls, 1)
	t.check("empty book gains the full list", r.get("new", -1), 2)
	b = Library.get_book(b.id)
	t.check("empty book keeps every chapter",
		b.chapters.map(func(c): return c.title), ["C1", "C2"])
	t.check("empty book stamps the full check", b.get("last_full_check", 0) >= now, true)
	Library.remove_book(b.id, false)
	var quick := Fake.new()
	quick.id = "selftest-update"
	quick.name = "UpdatePlug"
	quick.latest = {"chapters": [_ch(2), _ch(3)], "error": ""}
	quick.novel = _novel([_ch(1), _ch(2), _ch(3)])
	var n := _book([_ch(1), _ch(2)], 0)
	r = await Sources._refresh(quick, n, true)
	t.check("never-checked book calls fetch_novel despite no gap", quick.novel_calls, 1)
	t.check("never-checked book adds the new chapter", r.get("new", -1), 1)
	n = Library.get_book(n.id)
	t.check("never-checked book stamps the full check", n.get("last_full_check", 0) >= now, true)
	Library.remove_book(n.id, false)


## 7. A blocked quick result returns the error without calling fetch_novel.
func _blocked(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"error": "turned away", "blocked": true}
	fake.novel = {"error": "must not be called"}
	var b := _book([_ch(1)], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("blocked quick check returns its error", r.get("error", ""), "turned away")
	t.check("blocked quick check adds nothing", r.get("new", -1), 0)
	t.check("blocked quick check skips fetch_novel", fake.novel_calls, 0)
	b = Library.get_book(b.id)
	t.check("blocked quick check adds no chapters", b.chapters.size(), 1)
	t.check("blocked quick check flags no gap", b.get("possible_gap", true), false)
	t.check("blocked quick check leaves last_full_check alone", b.get("last_full_check", -1), now)
	Library.remove_book(b.id, false)


## 8. A malformed quick result falls back to fetch_novel.
func _malformed(t: Node) -> void:
	var now := Time.get_unix_time_from_system()
	var fake := Fake.new()
	fake.id = "selftest-update"
	fake.name = "UpdatePlug"
	fake.latest = {"chapters": [{"title": "Lost"}, {"title": "C3", "url": "https://example.com/b/3"}]}
	fake.novel = _novel([_ch(1), _ch(2), _ch(3)])
	var b := _book([_ch(1), _ch(2)], now)
	var r: Dictionary = await Sources._refresh(fake, b, true)
	t.check("malformed quick list calls fetch_novel", fake.novel_calls, 1)
	t.check("malformed quick list adds the new chapter", r.get("new", -1), 1)
	b = Library.get_book(b.id)
	t.check("malformed quick list stamps the full check", b.get("last_full_check", 0) >= now, true)
	Library.remove_book(b.id, false)
