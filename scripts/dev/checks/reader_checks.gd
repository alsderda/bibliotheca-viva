extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want) for each check.


const WORDS := ["alder", "birch", "cedar", "dune", "ember", "field", "grove", "harbor", "inlet", "junipers",
	"kestrel", "lantern", "meadow", "north", "orchard", "prairie", "quarry", "ridge", "summit",
	"trail", "upland", "valley", "willow", "yonder", "zephyr", "amber", "brook", "cliff"]


## 800 paragraphs of ~60 made-up words, as the Read tab would show them: a title,
## a heading, then body paragraphs (every 50th with inline markup, like real chapters).
static func _long_items() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var items := [{"kind": "title", "bb": "A Made-Up Chapter", "tts": "A Made-Up Chapter"},
		{"kind": "heading", "bb": "In which nothing happens", "tts": "In which nothing happens"}]
	for i in 798:
		var words := PackedStringArray()
		for k in 60:
			words.append(WORDS[rng.randi_range(0, WORDS.size() - 1)])
		var text := words[0].capitalize() + " " + " ".join(words.slice(1)) + "."
		var bb := text
		if i % 50 == 0:
			bb = "[i]" + words[0].capitalize() + "[/i] " + " ".join(words.slice(1)) + "."
		items.append({"kind": "p", "bb": bb, "tts": text})
	return items


func run(t: Node) -> void:
	var page := ReaderPage.new()
	t.add_child(page)
	page._items = _long_items()
	page._render()
	t.check("long chapter renders", page._text.get_paragraph_count() == 800, true)
	var plain := page._text.text

	# Paragraph highlight through the incremental path matches a full render.
	page.tts.set_highlight(5)
	var full := page._text.text
	page._render()
	t.check("paragraph highlight equals full render", page._text.text == full, true)

	# Sentence highlight, moved highlight and cleared highlight, all in sentence mode.
	var mode := Settings.get_value("tts_mode")
	Settings.set_value("tts_mode", "sentence")
	page.tts.set_highlight(5, 2)
	full = page._text.text
	page._render()
	t.check("sentence highlight equals full render", page._text.text == full, true)
	page.tts.set_highlight(250, 1)
	full = page._text.text
	page._render()
	t.check("moved highlight equals full render", page._text.text == full, true)
	page.tts.set_highlight(-1)
	t.check("cleared highlight restores text", page._text.text == plain, true)
	Settings.set_value("tts_mode", mode)

	# A highlight change stays fast on a long chapter, in both modes.
	var t0 := Time.get_ticks_usec()
	for k in 80:
		page.tts.set_highlight((k * 37) % 800)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 80.0
	t.check("paragraph highlight change under 20 ms", ms < 20.0, true)
	print("    long-chapter paragraph highlight change after: %.2f ms average over 80 changes" % ms)
	Settings.set_value("tts_mode", "sentence")
	t0 = Time.get_ticks_usec()
	for k in 80:
		page.tts.set_highlight((k * 37) % 800, k % 3)
	ms = (Time.get_ticks_usec() - t0) / 1000.0 / 80.0
	t.check("sentence highlight change under 20 ms", ms < 20.0, true)
	print("    long-chapter sentence highlight change after: %.2f ms average over 80 changes" % ms)
	Settings.set_value("tts_mode", mode)
	page.tts.set_highlight(-1)
	t.check("cleared highlight restores text again", page._text.text == plain, true)
	# Same chapter through a full render per change, for comparison with the
	# incremental path above (reported only).
	t0 = Time.get_ticks_usec()
	for k in 80:
		page.tts.highlight = (k * 37) % 800
		page._render()
	page.tts.highlight = -1
	page._render()
	ms = (Time.get_ticks_usec() - t0) / 1000.0 / 80.0
	print("    long-chapter full-render change: %.2f ms average over 80 changes" % ms)
	t.check("full render restores cleared text", page._text.text == plain, true)

	# Contents tab: a long chapter list is split into collapsible groups, with
	# only the current chapter's group expanded and the rest built on first open.
	var contents := ReaderPage.new()
	t.add_child(contents)
	var chapters := []
	for i in 230:
		chapters.append({"title": "Chapter %d" % (i + 1)})
	contents.book = {"id": "contents-check", "title": "Made-Up Serial", "author": "", "kind": "epub",
		"chapters": chapters, "progress": {"chapter": 120, "paragraph": 0}, "last_read": 1}
	contents.chapter = 120
	contents._build_contents()
	var titles := PackedStringArray()
	for c in chapters:
		titles.append(c.title)
	var groups := BookGroups.split(titles, int(Settings.get_value("contents_group_size")))
	var headers: Array = []
	var boxes: Array = []
	var rows := contents._contents_list.get_children()
	for i in rows.size():
		if rows[i] is Button and rows[i].has_meta("group_start"):
			headers.append(rows[i])
			boxes.append(rows[i + 1] if i + 1 < rows.size() else null)
	t.check("contents has one header per group", headers.size() == groups.size(), true)
	if groups.is_empty():
		var flat := 0
		for c in rows:
			if c is Button:
				flat += 1
		t.check("short contents stays flat", flat == 230, true)
	else:
		var cur := -1
		for h in groups.size():
			if int(groups[h].start) <= 120 and 120 < int(groups[h].end):
				cur = h
		var only_cur := cur >= 0
		var lazy := true
		for h in headers.size():
			var open: bool = boxes[h] != null and (boxes[h] as Control).visible
			if (h == cur) != open:
				only_cur = false
			var filled := (boxes[h] as VBoxContainer).get_child_count() if boxes[h] != null else -1
			if (filled > 0) != open or (open and filled != int(groups[h].end) - int(groups[h].start)):
				lazy = false
		t.check("contents expands only the current chapter's group", only_cur, true)
		t.check("contents builds collapsed groups lazily", lazy, true)
		if headers.size() > 1:
			var other := 0 if cur != 0 else 1
			var box := boxes[other] as VBoxContainer
			(headers[other] as Button).pressed.emit()
			t.check("toggling a group fills it in place", box.visible
				and box.get_child_count() == int(groups[other].end) - int(groups[other].start)
				and contents._contents_list.get_children().size() == rows.size()
				and (boxes[cur] as Control).visible, true)
			(headers[other] as Button).pressed.emit()
			t.check("toggling again collapses the group", not box.visible, true)

	# Touch selection bar: placement, actions and hiding.
	var bar := SelectionBar.new()
	t.add_child(bar)
	var bounds := Rect2(0, 0, 400, 800)
	bar.show_at(Vector2(200, 400), bounds, ReaderPage._selection_actions(true, false))
	t.check("selection bar opens above the anchor when there is room",
		bar.visible and bar.position.y + bar.size.y <= 400, true)
	t.check("selection bar stays inside bounds",
		bounds.encloses(Rect2(bar.position, bar.size)), true)
	bar.show_at(Vector2(200, 10), bounds, ReaderPage._selection_actions(true, false))
	t.check("selection bar opens below the anchor at the top edge", bar.position.y > 10, true)
	t.check("selection bar stays inside bounds at the top edge",
		bounds.encloses(Rect2(bar.position, bar.size)), true)
	var ids := ReaderPage._selection_actions(true, false).map(func(a): return a.id)
	t.check("selection actions are copy, bookmark and more",
		ids == [ReaderPage.SEL_COPY, ReaderPage.SEL_BOOKMARK, ReaderPage.SEL_MORE], true)
	var plain_ids := ReaderPage._selection_actions(false, false).map(func(a): return a.id)
	t.check("no-selection actions are bookmark and copy paragraph",
		plain_ids == [ReaderPage.SEL_BOOKMARK, ReaderPage.SEL_COPY_PARA], true)
	var marked: Dictionary = ReaderPage._selection_actions(true, true)[1]
	t.check("bookmarked paragraph offers editing",
		marked.text == "Edit bookmark" and marked.icon == "bookmark_fill", true)
	var fresh: Dictionary = ReaderPage._selection_actions(true, false)[1]
	t.check("plain paragraph offers bookmarking",
		fresh.text == "Bookmark" and fresh.icon == "bookmark", true)
	# A long press with no selection still pops the bar up (bookmark path).
	page._show_selection_bar(Vector2(20, 100))
	t.check("long press shows the bar without a selection", page._sel_bar.visible, true)
	t.check("long press without a selection offers bookmarking",
		page._sel_bar._row.get_child_count() == 2, true)
	page._on_scrolled(0.0)
	t.check("scrolling hides the selection bar", page._sel_bar.visible, false)
	bar.queue_free()
	contents.queue_free()
	page.queue_free()
	await t.get_tree().process_frame
