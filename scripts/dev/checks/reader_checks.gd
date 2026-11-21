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
	page.size = Vector2(800, 1200)
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	t.check("reader text has room to lay out", page._text.size.x > 700.0, true)
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

	# The highlight overlay: the main text stays plain while the overlay shows
	# the marked paragraph, lined up over it.
	page.tts.set_highlight(5)
	t.check("main text stays plain under highlight", page._text.text == plain, true)
	t.check("overlay shows for highlight", page._hl_label.visible, true)
	t.check("overlay marks the paragraph", page._hl_label.text.contains("[bgcolor="), true)
	await t.get_tree().process_frame
	_overlay_matches(t, page, 5)
	page.tts.set_highlight(250, 1)
	await t.get_tree().process_frame
	_overlay_matches(t, page, 250)
	page.tts.set_highlight(-1)
	t.check("overlay hides with the highlight", page._hl_label.visible, false)

	# A highlight change moves neither the scroll nor a running smooth scroll.
	page._text.get_v_scroll_bar().value = 500.0
	page.tts.set_highlight(42)
	t.check("highlight keeps the scroll pixel", page._text.get_v_scroll_bar().value, 500.0)
	page.smooth_scroll_to(900.0)
	page.tts.set_highlight(43)
	t.check("highlight keeps the smooth scroll", page.is_smooth_scrolling(), true)
	page.stop_smooth_scroll()
	page.tts.set_highlight(-1)

	# Every highlight style marks, or hides the overlay when it adds no tags.
	for style in ["background", "underline", "color"]:
		Settings.set_value("tts_highlight", style)
		page.tts.set_highlight(7)
		t.check("overlay marks in %s mode" % style, _hl_has_mark(page), true)
	Settings.set_value("tts_highlight", "none")
	page.tts.set_highlight(7)
	t.check("overlay hides when highlighting is off", page._hl_label.visible, false)
	Settings.set_value("tts_highlight", "background")
	page.tts.set_highlight(-1)

	# Geometry readers see right after refresh_highlight is already current:
	# no re-layout, so a highlight plus the follow-scroll math stays cheap.
	t0 = Time.get_ticks_usec()
	for k in 80:
		var i := (k * 37) % 800
		page.tts.set_highlight(i)
		var start := page.tts._paragraph_char(i)
		page._text.get_character_line(start)
		page._text.get_line_offset(page._text.get_character_line(start))
		page._text.get_paragraph_offset(i)
	ms = (Time.get_ticks_usec() - t0) / 1000.0 / 80.0
	t.check("highlight plus follow math under 20 ms", ms < 20.0, true)
	print("    long-chapter highlight plus follow math: %.2f ms average over 80 changes" % ms)
	page.tts.set_highlight(-1)
	t.check("cleared highlight restores text at the end", page._text.text == plain, true)

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
	contents.queue_free()
	page.queue_free()
	await t.get_tree().process_frame
	await run_follow_checks(t)


## The overlay covers exactly its paragraph's lines in the main label.
static func _overlay_matches(t: Node, page: ReaderPage, para: int) -> void:
	var start := page.tts._paragraph_char(para)
	t.check("highlight paragraph found in text", start >= 0, true)
	var total := page._text.get_total_character_count()
	var lo := 0
	var hi := total
	while lo < hi:
		var mid := (lo + hi) / 2
		if page._text.get_character_paragraph(mid) < para + 1:
			lo = mid + 1
		else:
			hi = mid
	var first := page._text.get_character_line(start)
	var last := page._text.get_character_line(maxi(lo - 1, 0))
	t.check("overlay wraps like its paragraph", page._hl_label.get_line_count(), last - first + 1)
	var top: float = page._text.get_theme_stylebox("normal").content_margin_top
	var want := top + page._text.get_paragraph_offset(para) - page._text.get_v_scroll_bar().value
	t.check("overlay sits on its paragraph", absf(page._hl_label.position.y - want) < 1.0, true)


static func _hl_has_mark(page: ReaderPage) -> bool:
	var text := page._hl_label.text
	return page._hl_label.visible and (text.contains("[bgcolor=") or text.contains("[u]") or text.contains("[color="))


## Agent B: follow-along scroll decisions and chunk mapping. The spoken words must
## stay on screen in both modes, so the "does this need a scroll and to where"
## rule and the chunk-to-paragraph mapping are tested directly here.
func run_follow_checks(t: Node) -> void:
	var text := "Alder grove meadow. Birch field harbor inlet."
	var chunks := PackedStringArray(["Alder grove meadow.", "Birch field harbor inlet."])
	t.check("chunk 0 starts at 0", Speech.chunk_offset(text, chunks, 0) == 0, true)
	t.check("chunk 1 starts after chunk 0", Speech.chunk_offset(text, chunks, 1) == 20, true)
	t.check("chunk past the end is -1", Speech.chunk_offset(text, chunks, 2) == -1, true)
	t.check("negative chunk is -1", Speech.chunk_offset(text, chunks, -1) == -1, true)
	t.check("missing chunk text is -1", Speech.chunk_offset("Nothing alike here.", chunks, 1) == -1, true)
	t.check("para char maps into chunk", Speech.para_char(text, chunks, 1, 6) == 26, true)
	t.check("para char clamps to text length", Speech.para_char(text, chunks, 1, 999) == text.length(), true)
	t.check("para char of missing chunk is -1", Speech.para_char("Nothing alike here.", chunks, 1, 0) == -1, true)
	# Repeated sentences map in order: the second chunk starts after the first.
	var twice := "Dune ridge. Dune ridge."
	var two := PackedStringArray(["Dune ridge.", "Dune ridge."])
	t.check("repeated chunk maps in order", Speech.chunk_offset(twice, two, 1) == 12, true)
	# Long-paragraph split: sentences of a >1200-char paragraph still map.
	var long_text := "Alder grove. " + "Birch field harbor inlet. ".repeat(60) + "Summit."
	var long_chunks := Speech.split_sentences(long_text)
	t.check("long paragraph splits", long_chunks.size() > 2, true)
	var off := Speech.chunk_offset(long_text, long_chunks, long_chunks.size() - 1)
	t.check("last chunk of long paragraph maps", off != -1 and long_text.substr(off) == long_chunks[long_chunks.size() - 1], true)
	# Scroll decisions: a 20px line in a 200..600 band with a 16px lead.
	t.check("line inside needs no scroll", ReaderTts.follow_scroll_y(300, 320, 200, 600, 16, 2000) == -1.0, true)
	t.check("line at the top edge needs no scroll", ReaderTts.follow_scroll_y(200, 220, 200, 600, 16, 2000) == -1.0, true)
	t.check("line near the bottom scrolls to top area", ReaderTts.follow_scroll_y(580, 600, 200, 600, 16, 2000) == 564.0, true)
	t.check("line two lines from the bottom already scrolls", ReaderTts.follow_scroll_y(550, 570, 200, 600, 16, 2000) == 534.0, true)
	t.check("line past the bottom scrolls to top area", ReaderTts.follow_scroll_y(700, 720, 200, 600, 16, 2000) == 684.0, true)
	t.check("line above the top scrolls back down", ReaderTts.follow_scroll_y(100, 120, 200, 600, 16, 2000) == 84.0, true)
	t.check("scroll target clamps at zero", ReaderTts.follow_scroll_y(5, 25, 200, 600, 16, 2000) == 0.0, true)
	t.check("scroll target clamps at max", ReaderTts.follow_scroll_y(1990, 2010, 200, 600, 16, 1000) == 1000.0, true)
	# Spoken-to-shown mapping on a rendered page with one tall paragraph.
	var page2 := ReaderPage.new()
	t.add_child(page2)
	var words := PackedStringArray()
	for k in 60:
		words.append(WORDS[k % WORDS.size()])
	var sent := words[0].capitalize() + " " + " ".join(words.slice(1)) + "."
	page2._items = [{"kind": "title", "bb": "Follow", "tts": "Follow"},
		{"kind": "p", "bb": (sent + " ").repeat(30).strip_edges(), "tts": (sent + " ").repeat(30).strip_edges()}]
	page2._render()
	page2.tts.highlight = 1
	page2.tts._anchor(1, 0)
	var n: int = page2.tts._chunks.size()
	t.check("tall paragraph splits in sentences", n > 5, true)
	t.check("chunk starts mapped", page2.tts._starts.size() == n and page2.tts._starts[0] == 0, true)
	t.check("display starts mapped", page2.tts._disp.size() == n and page2.tts._disp[0] == 0, true)
	var first_char := page2.tts._spoken_label_char()
	page2.tts._spoken_chunk = 5
	page2.tts._spoken_off = 0
	var later_char := page2.tts._spoken_label_char()
	t.check("later chunk maps later in the label", later_char > first_char, true)
	await t.get_tree().process_frame
	t.check("spoken label char has a line", page2._text.get_character_line(later_char) >= 0, true)
	var mode2: String = Settings.get_value("tts_mode")
	Settings.set_value("tts_mode", "sentence")
	page2.tts.highlight_sentence = 5
	page2.tts._spoken_chunk = 5
	page2.tts._spoken_off = 3
	var span := page2._sentence_span(page2._items[1], 5)
	var want := page2.tts._label_char_of(1, span.x + mini(page2.tts._spoken_progress(), span.y - span.x))
	t.check("sentence mode maps into the sentence mark", page2.tts._spoken_label_char() == want, true)
	Settings.set_value("tts_mode", mode2)
	page2.queue_free()
