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
	page.queue_free()
	await t.get_tree().process_frame
