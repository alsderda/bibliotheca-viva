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

	# Follow scrolling is off while reading aloud is paused, on again once it resumes.
	var saved_speech := [Speech.playing, Speech.paused, Speech.source_owner, Speech.items]
	Speech.items = ReaderPage._speech_items(page._items)
	Speech.source_owner = "reader"
	Speech.playing = true
	page.tts.highlight = 10
	page.tts._spoken_para = 10
	t.check("follow scrolls while reading", page.tts._follow_ready(10), true)
	Speech.paused = true
	t.check("no follow scroll while paused", page.tts._follow_ready(10), false)
	Speech.paused = false
	t.check("follow scrolls again after resume", page.tts._follow_ready(10), true)
	page.tts.highlight = -1
	page.tts._spoken_para = -1
	Speech.playing = saved_speech[0]
	Speech.paused = saved_speech[1]
	Speech.source_owner = saved_speech[2]
	Speech.items = saved_speech[3]

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
	var contents_page := ReaderPage.new()
	t.add_child(contents_page)
	var chapters := []
	for i in 230:
		chapters.append({"title": "Chapter %d" % (i + 1)})
	contents_page.book = {"id": "contents-check", "title": "Made-Up Serial", "author": "", "kind": "epub",
		"chapters": chapters, "progress": {"chapter": 120, "paragraph": 0}, "last_read": 1}
	contents_page.chapter = 120
	contents_page.contents.build()
	var titles := PackedStringArray()
	for c in chapters:
		titles.append(c.title)
	var groups := BookGroups.split(titles, int(Settings.get_value("contents_group_size")))
	var headers: Array = []
	var boxes: Array = []
	var rows := contents_page.contents.list.get_children()
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
				and contents_page.contents.list.get_children().size() == rows.size()
				and (boxes[cur] as Control).visible, true)
			(headers[other] as Button).pressed.emit()
			t.check("toggling again collapses the group", not box.visible, true)

	# Touch selection bar: placement, actions and hiding.
	var bar := SelectionBar.new()
	t.add_child(bar)
	var bounds := Rect2(0, 0, 400, 800)
	bar.show_at(Vector2(200, 400), bounds, ReaderSelection.actions(true, false))
	t.check("selection bar opens above the anchor when there is room",
		bar.visible and bar.position.y + bar.size.y <= 400, true)
	t.check("selection bar stays inside bounds",
		bounds.encloses(Rect2(bar.position, bar.size)), true)
	bar.show_at(Vector2(200, 10), bounds, ReaderSelection.actions(true, false))
	t.check("selection bar opens below the anchor at the top edge", bar.position.y > 10, true)
	t.check("selection bar stays inside bounds at the top edge",
		bounds.encloses(Rect2(bar.position, bar.size)), true)
	var ids := ReaderSelection.actions(true, false).map(func(a): return a.id)
	t.check("selection actions are copy, bookmark and more",
		ids == [ReaderSelection.SEL_COPY, ReaderSelection.SEL_BOOKMARK, ReaderSelection.SEL_MORE], true)
	var plain_ids := ReaderSelection.actions(false, false).map(func(a): return a.id)
	t.check("no-selection actions are bookmark and copy paragraph",
		plain_ids == [ReaderSelection.SEL_BOOKMARK, ReaderSelection.SEL_COPY_PARA], true)
	var marked: Dictionary = ReaderSelection.actions(true, true)[1]
	t.check("bookmarked paragraph offers editing",
		marked.text == "Edit bookmark" and marked.icon == "bookmark_fill", true)
	var fresh: Dictionary = ReaderSelection.actions(true, false)[1]
	t.check("plain paragraph offers bookmarking",
		fresh.text == "Bookmark" and fresh.icon == "bookmark", true)
	# A long press with no selection still pops the bar up (bookmark path).
	page.selection.show_bar(Vector2(20, 100))
	t.check("long press shows the bar without a selection", page.selection.bar.visible, true)
	t.check("long press without a selection offers bookmarking",
		page.selection.bar._row.get_child_count() == 2, true)
	page._on_scrolled(0.0)
	t.check("scrolling hides the selection bar", page.selection.bar.visible, false)
	bar.queue_free()
	contents_page.queue_free()
	page.queue_free()
	await t.get_tree().process_frame
	await run_follow_checks(t)
	await run_resilience_checks(t)


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


## One failed clip ends that request instead of killing the helper, play() with nothing readable stops a running UI, the touch menu
## opens at the touch point, and oversized EPUB entries fail with an error.
func run_resilience_checks(t: Node) -> void:
	# play() with nothing readable after playing stops the UI's Stop state.
	var states: Array = []
	var on_state := func(p): states.append(p)
	Speech.state_changed.connect(on_state)
	Speech.playing = true
	Speech.play([], 0, "reader")
	t.check("play() with nothing readable stops a running UI", states, [false])
	t.check("play() with nothing readable clears playing", Speech.playing, false)
	Speech.play([], 0, "reader")
	t.check("play() with nothing readable stays quiet when idle", states, [false])
	Speech.state_changed.disconnect(on_state)

	# One failed Windows render ends that request; repeated ones give up.
	var wv := WinVoice.new()  # never added, so the helper never starts
	var ended: Array = []
	var failed: Array = []
	wv.ended.connect(func(id): ended.append(id))
	wv.failed.connect(func(): failed.append(true))
	_fail_clip(wv, 1, "k1", 7, "1\tERR\tboom")
	t.check("one failed clip ends that request", ended, [7])
	t.check("one failed clip clears the want", [wv._want_key, wv._want_id], ["", -1])
	t.check("one failed clip keeps the helper", [wv.is_broken(), failed], [false, []])
	_fail_clip(wv, 2, "k2", 8, "2\tERR\tboom")
	t.check("two failed clips keep the helper", [wv.is_broken(), failed], [false, []])
	_fail_clip(wv, 3, "k3", 9, "3\tERR\tboom")
	t.check("repeated failures disable the helper", [wv.is_broken(), failed], [true, [true]])

	# A good clip between failures resets the count.
	var wv2 := WinVoice.new()
	var ended2: Array = []
	var failed2: Array = []
	wv2.ended.connect(func(id): ended2.append(id))
	wv2.failed.connect(func(): failed2.append(true))
	wv2._dir = "user://"
	_fail_clip(wv2, 1, "a", 11, "1\tERR\tx")
	var wav := FileAccess.open("user://2.wav", FileAccess.WRITE)
	wav.store_buffer(_tiny_wav_bytes())
	wav.close()
	wv2._req_key[2] = "b"
	wv2._clips["b"] = null
	wv2._on_line("2\tOK")
	t.check("a good clip renders and resets the count", wv2._clips.get("b") != null, true)
	_fail_clip(wv2, 3, "c", 12, "3\tERR\tx")
	_fail_clip(wv2, 4, "d", 13, "4\tERR\tx")
	t.check("failures after a good clip keep the helper", [wv2.is_broken(), failed2], [false, []])
	t.check("skipped clips end their requests", ended2, [11, 12, 13])

	# A double-tap opens the menu at the touch point, not card-local.
	var card := BookCard.new()
	t.add_child(card)
	card.setup({"id": "check-card", "title": "Check", "author": "Anon", "kind": "epub",
		"chapters": [{"title": "A"}], "progress": {"chapter": 0, "paragraph": 0}, "last_read": 0}, 168.0)
	card.position = Vector2(100, 200)
	await t.get_tree().process_frame
	var at: Array = []
	card.menu_requested.connect(func(id, pos): at.append(pos))
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	touch.double_tap = true
	touch.position = Vector2(10, 10)
	card._on_input(touch)
	var want: Vector2 = card.get_global_transform_with_canvas() * Vector2(10, 10)
	t.check("double-tap menu opens at the touch point", at, [want])
	t.check("double-tap menu position is not card-local", at[0] != Vector2(10, 10), true)
	card.queue_free()

	# A tiny EPUB imports; an entry over the cap fails with an error.
	t.check("epub entry cap is 32 MiB", EpubLoader.MAX_ENTRY_BYTES, 32 * 1024 * 1024)
	t.check("epub total cap is 512 MiB", EpubLoader.MAX_TOTAL_BYTES, 512 * 1024 * 1024)
	var tiny := Settings.data_dir() + "/selftest-tiny.epub"
	_write_epub(tiny, false)
	var parsed := EpubLoader.load_epub(tiny)
	t.check("tiny epub loads", [parsed.get("error", "unset"), parsed.get("title", ""), parsed.get("chapters", []).size()], ["unset", "Tiny", 1])
	var big := Settings.data_dir() + "/selftest-big.epub"
	_write_epub(big, true)
	var refused := EpubLoader.load_epub(big)
	t.check("oversized epub entry fails", refused.has("error"), true)
	t.check("oversized epub error names the cap", str(refused.get("error", "")).contains("bigger than"), true)
	DirAccess.remove_absolute(tiny)
	DirAccess.remove_absolute(big)


## A failed render for one request: the clip stays missing and the wanted
## request waits no longer, as if the helper had answered for that request.
static func _fail_clip(wv: WinVoice, req: int, key: String, id: int, line: String) -> void:
	wv._req_key[req] = key
	wv._clips[key] = null
	wv._want_key = key
	wv._want_id = id
	wv._on_line(line)


## 200 alternating samples of 16-bit mono PCM in a WAV header, for the WinVoice check.
static func _tiny_wav_bytes() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(400)
	for i in 200:
		data.encode_s16(i * 2, 1200 if i % 2 == 0 else -1200)
	var b := PackedByteArray()
	b.resize(44)
	b.encode_u32(0, 0x46464952)  # RIFF
	b.encode_u32(4, 36 + data.size())
	b.encode_u32(8, 0x45564157)  # WAVE
	b.encode_u32(12, 0x20746D66)  # fmt + space
	b.encode_u32(16, 16)
	b.encode_u16(20, 1)
	b.encode_u16(22, 1)
	b.encode_u32(24, 22050)
	b.encode_u32(28, 22050 * 2)
	b.encode_u16(32, 2)
	b.encode_u16(34, 16)
	b.encode_u32(36, 0x61746164)  # data
	b.encode_u32(40, data.size())
	return b + data


## A minimal two-file EPUB, with an extra oversized entry when `big` is set.
static func _write_epub(path: String, big: bool) -> void:
	var chapter := "OEBPS/ch1.xhtml"
	var manifest := '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
	var spine := '<itemref idref="c1"/>'
	if big:
		manifest += '<item id="big" href="big.xhtml" media-type="application/xhtml+xml"/>'
		spine += '<itemref idref="big"/>'
	var opf := '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
	opf += '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Tiny</dc:title>'
	opf += '<dc:creator>Anon</dc:creator></metadata><manifest>' + manifest + '</manifest>'
	opf += '<spine>' + spine + '</spine></package>'
	var zip := ZIPPacker.new()
	zip.open(path)
	zip.start_file("META-INF/container.xml")
	zip.write_file('<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'.to_utf8_buffer())
	zip.close_file()
	zip.start_file("OEBPS/content.opf")
	zip.write_file(opf.to_utf8_buffer())
	zip.close_file()
	zip.start_file(chapter)
	zip.write_file('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><p>Hello alder grove meadow.</p></body></html>'.to_utf8_buffer())
	zip.close_file()
	if big:
		var huge := PackedByteArray()
		huge.resize(EpubLoader.MAX_ENTRY_BYTES + 1)
		huge.fill(97)
		zip.start_file("OEBPS/big.xhtml")
		zip.write_file(huge)
		zip.close_file()
	zip.close()
