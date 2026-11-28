extends Node
## Dev harness: measures read-aloud follow-scrolling in the live reader.
## Two flows, picked by user args (see main.gd dispatch):
##   --followcheck  wipe the followcheck profile, import a generated book, read it
##                  aloud 40 s in paragraph mode then 40 s in sentence mode, and
##                  print one FOLLOWCHECK line per mode before quitting (0 ok).
##   --followshots  same setup, then photograph the reading highlight on a tall
##                  paragraph in each tts_mode x tts_highlight combination, plus
##                  3x nearest-neighbour crops, into SHOT_DIR (AFTER tree only).
## Optional: followcheck-secs=N shortens the per-mode read time (smoke tests).
## A watchdog prints FOLLOWCHECK TIMEOUT and quits 1 when anything stalls.

const MODE_SECONDS := 40.0
const WATCHDOG_SECONDS := 300.0
const LONG_FRAME_MS := 33.0
const BACKWARD_PX := 2.0
const JUMP_VIEWPORT_RATIO := 0.6
const SCROLL_SETTLE_SECONDS := 0.6
const HEARTBEAT_SECONDS := 10.0
const BOOK_PATH := "user://followcheck_book.txt"
const SHOT_DIR := "user://followcheck_shots"

## Original public-domain prose for the imported book: a harbor town tale.
const SENTENCES := [
	"The morning bell rang over the harbor before the gulls had woken.",
	"Salt dried in white lines along the mooring ropes by the stone quay.",
	"Mara carried her basket of nets down the worn steps to the boats.",
	"The tide was low, and the smell of kelp hung heavy in the still air.",
	"Old Tomas mended a sail in the doorway of his blue-painted shed.",
	"Children chased each other between the barrels stacked near the market.",
	"A gray cat slept on the warm lid of the fish merchant's icebox.",
	"The lighthouse keeper waved once from the cliff path and walked on.",
	"Fishing boats nodded at anchor, their masts drawing lines on the sky.",
	"Mara's brother had promised to teach her the deep-water knots today.",
	"The market square filled slowly with baskets of crabs and shining mackerel.",
	"A woman sold hot rolls from a cart, calling out in a hoarse kind voice.",
	"The church clock struck eight, and the pigeons rose all together.",
	"Down by the breakwater, the waves made a sound like turning pages.",
	"Mara traded three brass buttons for a spool of strong twine.",
	"The rope-maker's dog followed her halfway home and then gave up.",
	"Clouds gathered over the headland, dark at the edges like wet wool.",
	"Her grandmother sat by the window, shelling peas into a chipped bowl.",
	"The radio spoke of a storm far out at sea, moving slowly east.",
	"Mara checked the shutters and the latch on the little back door.",
	"Rain began at noon, drumming on the roof of the washhouse.",
	"The harbor water turned the color of hammered pewter under the clouds.",
	"Boats strained at their ropes, eager as dogs on short leashes.",
	"Tomas shouted for help, and three strangers ran to hold his sail.",
	"By evening the wind had torn one awning loose in the market square.",
	"The lighthouse beam came on early, sweeping the restless water.",
	"Mara lit the lamp and read the tide table by its yellow light.",
	"Her brother came home soaked, grinning, with a story about a seal.",
	"They ate soup and bread while the rain ran down the windowpanes.",
	"The storm peaked at midnight, rattling every loose thing in town.",
	"In the morning the quay was littered with weed and broken spars.",
	"The gray cat reappeared, dry and smug, from inside a lobster pot.",
	"Neighbors helped each other drag the fallen awning to the shed.",
	"Mara found a green glass float tangled in the nets, unbroken.",
	"She held it to the light, and the whole kitchen turned sea-green.",
	"The fishing fleet went out late, when the swell had settled.",
	"Gulls quarreled over scraps behind the smokehouse all afternoon.",
	"The rope-maker praised her knots and paid her in fresh twine.",
	"At dusk the harbor lay flat and gold, as if nothing had happened.",
	"The lighthouse beam went round again, steady as a heartbeat.",
]

## Target paragraph lengths in words per chapter: short lines mixed with long ones.
const PLAN := [
	[12, 230, 40, 260, 15, 190, 45, 220],
	[55, 240, 50, 200, 100, 170, 45],
	[50, 210, 60, 230, 80],
]

var _main = null ## untyped: drives the live app through its existing members
var _reader = null ## untyped: the reader page under test (shape differs per tree)
var _measuring := false
var _shots_mode := false
var _eff_secs := MODE_SECONDS
var _new_api := false ## the tree maps word_boundary to the paragraph (overlay build)
var _cur := {}
var _results: Array = []
var _profile_dir_global := ""
var _prev_scroll := 0.0
var _last_change := -10.0
var _scroll_active := false
var _have_spoken := false
var _spoken_top := 0.0
var _spoken_bottom := 0.0
var _stretch_start := -1.0
var _last_para := -1
var _last_chunk_label := -1
var _search_from := 0
var _mode_start := 0.0
var _snapped35 := false
var _snapped70 := false
var _last_beat := 0.0


func _ready() -> void:
	OS.low_processor_usage_mode = false
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s == "--followshots":
			_shots_mode = true
		if s.begins_with("--followcheck-secs="):
			_eff_secs = maxf(1.0, float(s.trim_prefix("--followcheck-secs=")))
		elif s.begins_with("followcheck-secs="):
			_eff_secs = maxf(1.0, float(s.trim_prefix("followcheck-secs=")))
	# Connected once for the whole run: per-mode connect/disconnect churn and
	# stray fire-and-forget coroutines both risk outliving the state they touch.
	Speech.paragraph_started.connect(_on_paragraph)
	Speech.sentence_started.connect(_on_sentence)
	Speech.word_boundary.connect(_on_word)
	get_tree().create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog)
	_run.call_deferred()


func _run() -> void:
	_main = get_parent()
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_main):
		print("FOLLOWCHECK ABORT: main went away during startup")
		get_tree().quit(1)
		return
	if not Speech.is_supported() or Speech.voices().is_empty():
		print("FOLLOWCHECK ABORT: no text-to-speech voices on this machine")
		get_tree().quit(1)
		return
	_wipe_profile()
	var book := _import_book()
	if book.has("error") or (book as Dictionary).is_empty():
		print("FOLLOWCHECK ABORT: import failed: ", (book as Dictionary).get("error", "empty book"))
		get_tree().quit(1)
		return
	print("FOLLOWCHECK profile=", _profile_dir_global, " book=", (book as Dictionary).get("title", "?"))
	Settings.set_value("tts_follow", true)
	Settings.set_value("tts_rate", 2.0)
	Settings.set_value("font_size", 20)
	if _shots_mode:
		await _run_shots(book)
		return
	for mode in ["paragraph", "sentence"]:
		Speech.stop()
		Settings.set_value("tts_mode", mode)
		await get_tree().process_frame
		await _main.open_reader((book as Dictionary)["id"], 0)
		if not _wait_reader_ready():
			print("FOLLOWCHECK ABORT: reader not ready in mode ", mode)
			get_tree().quit(1)
			return
		for i in 6:
			await get_tree().process_frame
		_begin_mode(mode)
		print("FOLLOWCHECK BEGIN mode=", mode, " items=", _items().size())
		_reader.start_tts(0)
		await get_tree().create_timer(_eff_secs).timeout
		_end_mode()
		_snap("fc_%s_end" % mode)
		print("FOLLOWCHECK END mode=", mode, " ", _mini_summary())
	Speech.stop()
	_print_summary()
	get_tree().quit(0)


func _on_watchdog() -> void:
	print("FOLLOWCHECK TIMEOUT: exceeded %.0f seconds" % WATCHDOG_SECONDS)
	get_tree().quit(1)


## Deletes everything inside the followcheck profile folder and forgets what the
## autoloads already loaded from it, so the run starts from an empty library.
func _wipe_profile() -> void:
	var dir: String = Settings.data_dir()
	if not dir.ends_with("profiles/followcheck"):
		print("FOLLOWCHECK ABORT: refusing to wipe unexpected profile dir: ", dir)
		get_tree().quit(1)
		return
	_profile_dir_global = ProjectSettings.globalize_path(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm_rf(dir.path_join(d))
	Library.books = []
	Library.tombstones = {}
	Library.flush()


func _rm_rf(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm_rf(dir.path_join(d))
	DirAccess.remove_absolute(dir)


## Writes the generated text to a file and imports it like a user file drop.
func _import_book() -> Dictionary:
	var text := ""
	var titles := ["Chapter One", "Chapter Two", "Chapter Three"]
	for c in PLAN.size():
		text += titles[c] + "\n\n"
		var start := c * 7
		for p in PLAN[c].size():
			text += _paragraph(int(PLAN[c][p]), start + p * 11) + "\n\n"
	var f := FileAccess.open(BOOK_PATH, FileAccess.WRITE)
	if f == null:
		return {"error": "could not write " + BOOK_PATH}
	f.store_string(text)
	f.close()
	return Library.import_file(BOOK_PATH)


## Takes sentences round-robin from the bank until the word target is reached.
static func _paragraph(target_words: int, offset: int) -> String:
	var words := 0
	var out := PackedStringArray()
	var i := offset
	while words < target_words:
		var s: String = SENTENCES[i % SENTENCES.size()]
		out.append(s)
		words += s.split(" ").size()
		i += 1
	return " ".join(out)


# --- measurement -------------------------------------------------------------

## The reader page behind main.pages["reader"], once it shows chapter text.
func _wait_reader_ready() -> bool:
	if _main.get("pages") == null:
		return false
	_reader = _main.pages["reader"]
	if _reader == null or not is_instance_valid(_reader):
		return false
	if _reader.get("_text") == null or _reader.get("_items") == null:
		return false
	# The overlay build scrolls through one shared tween; the older build tweens
	# the bar directly. The word event's offset is paragraph-relative only there.
	_new_api = _reader.has_method("smooth_scroll_to")
	return true


func _begin_mode(mode: String) -> void:
	_cur = {
		"mode": mode, "seconds": _eff_secs, "frames": 0, "scroll_frames": 0,
		"scrolls": 0, "long_frames": 0, "backward": 0, "big_jumps": 0,
		"para_events": 0, "sent_events": 0, "word_events": 0,
		"offscreen_events": 0, "off_time": 0.0, "longest_off_ms": 0.0,
		"reached_para": 0, "shots": [],
	}
	_have_spoken = false
	_stretch_start = -1.0
	_last_para = -1
	_last_chunk_label = -1
	_search_from = 0
	var bar := _label().get_v_scroll_bar()
	_prev_scroll = (bar as VScrollBar).value
	_last_change = -10.0
	_scroll_active = false
	_mode_start = _now()
	_last_beat = _mode_start
	_snapped35 = false
	_snapped70 = false
	_measuring = true


func _end_mode() -> void:
	_measuring = false
	_close_stretch(_now())
	if not _cur.is_empty():
		_results.append(_cur)


func _mini_summary() -> String:
	return "para_ev=%d sent_ev=%d word_ev=%d offscreen=%d longest_off_ms=%.0f scrolls=%d long=%d backward=%d jumps=%d" % [
		int(_cur.para_events), int(_cur.sent_events), int(_cur.word_events),
		int(_cur.offscreen_events), float(_cur.longest_off_ms), int(_cur.scrolls),
		int(_cur.long_frames), int(_cur.backward), int(_cur.big_jumps),
	]


func _process(delta: float) -> void:
	if _reader == null or not is_instance_valid(_reader):
		return
	if not _measuring or _cur.is_empty():
		return
	_cur.frames += 1
	var bar := _label().get_v_scroll_bar()
	var v: float = (bar as VScrollBar).value
	var vh := _viewport_h()
	if Speech.playing and absf(v - _prev_scroll) > 0.5:
		_last_change = _now()
	var active := Speech.playing and (_now() - _last_change < SCROLL_SETTLE_SECONDS)
	if active and not _scroll_active:
		_cur.scrolls += 1
	_scroll_active = active
	if _scroll_active:
		_cur.scroll_frames += 1
		if delta * 1000.0 > LONG_FRAME_MS:
			_cur.long_frames += 1
		if v < _prev_scroll - BACKWARD_PX:
			_cur.backward += 1
		if v - _prev_scroll > vh * JUMP_VIEWPORT_RATIO:
			_cur.big_jumps += 1
	if Speech.playing and _have_spoken:
		if _is_visible(_spoken_top, _spoken_bottom, v, vh):
			_close_stretch(_now())
		else:
			if _stretch_start < 0.0:
				_stretch_start = _now()
			_cur.off_time += delta
	_prev_scroll = v
	var el := _now() - _mode_start
	if not _snapped35 and el > _eff_secs * 0.35:
		_snapped35 = true
		_snap("fc_%s_mid35" % String(_cur.mode))
	if not _snapped70 and el > _eff_secs * 0.7:
		_snapped70 = true
		_snap("fc_%s_mid70" % String(_cur.mode))
	if _now() - _last_beat > HEARTBEAT_SECONDS:
		_last_beat = _now()
		print("FOLLOWCHECK BEAT mode=", _cur.mode, " t=%.0f playing=" % el, Speech.playing,
			" current=", Speech.current, " scroll=%.0f" % v, " ", _mini_summary())


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _label() -> RichTextLabel:
	return _reader._text


func _items() -> Array:
	return _reader._items


## Text height actually visible: the stylebox's top margin and the bottom margin
## that reserves room for the floating player bar are not text.
func _viewport_h() -> float:
	var label := _label()
	var m := _margins()
	return maxf(float(label.size.y) - m.x - m.y, 1.0)


func _margins() -> Vector2:
	var sb := _label().get_theme_stylebox("normal")
	if sb == null:
		return Vector2(36, 36)
	return Vector2(sb.content_margin_top, sb.content_margin_bottom)


func _is_visible(top: float, bottom: float, scroll: float, vh: float) -> bool:
	return top >= scroll - 2.0 and bottom <= scroll + vh + 2.0


func _close_stretch(now: float) -> void:
	if _stretch_start >= 0.0:
		_cur.longest_off_ms = maxf(float(_cur.longest_off_ms), (now - _stretch_start) * 1000.0)
		_stretch_start = -1.0


# --- spoken-position mapping -------------------------------------------------
## Label-space character of the first character of paragraph `paragraph`, or -1.
## Same binary search the reader's own follow code uses over the label's paragraphs.

func _paragraph_char(label: RichTextLabel, paragraph: int) -> int:
	var lo := 0
	var hi := label.get_total_character_count()
	if hi <= 0:
		return -1
	while lo < hi:
		var mid := (lo + hi) / 2
		if label.get_character_paragraph(mid) < paragraph:
			lo = mid + 1
		else:
			hi = mid
	return lo if label.get_character_paragraph(lo) == paragraph else -1


## Embedded images before the text shift label characters: the bookmark icon and
## space, and the first-line indent image. Same adjustments the reader applies.
func _lead_extra(item: Dictionary, paragraph: int) -> int:
	var extra := 0
	if Library.bookmarks(_reader.book).any(func(m): return m.chapter == _reader.chapter and m.paragraph == paragraph):
		extra += 2
	if bool(Settings.get_value("first_line_indent")) and str(item.get("kind", "p")) != "title" and str(item.get("kind", "p")) != "heading":
		extra += 1
	return extra


## Label-space character where chunk `sent` of item `item` starts showing, or -1
## when the spoken text no longer matches the shown text (rules changed it).
func _chunk_label_char(item: Dictionary, paragraph: int, sent: int) -> int:
	var label := _label()
	var start := _paragraph_char(label, paragraph)
	if start < 0:
		return -1
	var chunks := Speech.split({"text": item.tts, "kind": item.get("kind", "p")})
	if sent < 0 or sent >= chunks.size():
		return -1
	var shown := ReaderMarkup.visible_text(item.bb)
	var pos := _search_from if paragraph == _last_para else 0
	for k in sent + 1:
		pos = shown.find(chunks[k], pos)
		if pos == -1:
			return -1
		if k < sent:
			pos += chunks[k].length()
	return start + _lead_extra(item, paragraph) + pos


## Records the spoken position as a line box and counts the event offscreen when
## that box is outside the visible part of the text at event time.
func _note_spoken(label_char: int, paragraph: int) -> void:
	if _cur.is_empty():
		return
	var label := _label()
	if label_char < 0 or label_char >= label.get_total_character_count():
		return
	var line := label.get_character_line(label_char)
	if line < 0:
		return
	_have_spoken = true
	_spoken_top = label.get_line_offset(line)
	_spoken_bottom = _spoken_top + label.get_line_height(line)
	var bar := label.get_v_scroll_bar()
	var m := _margins()
	var top := (bar as VScrollBar).value + m.x
	if not _is_visible(_spoken_top, _spoken_bottom, top, _viewport_h()):
		_cur.offscreen_events += 1
	_cur.reached_para = maxi(int(_cur.reached_para), paragraph)


func _on_paragraph(index: int) -> void:
	if not _measuring or _cur.is_empty() or _reader == null or not is_instance_valid(_reader):
		return
	_cur.para_events += 1
	_last_para = index
	_search_from = 0
	var items := _items()
	if index < 0 or index >= items.size():
		return
	var start := _paragraph_char(_label(), index)
	if start < 0:
		return
	_last_chunk_label = start + _lead_extra(items[index], index)
	_note_spoken(_last_chunk_label, index)


func _on_sentence(index: int, sent: int) -> void:
	if not _measuring or _cur.is_empty() or _reader == null or not is_instance_valid(_reader):
		return
	_cur.sent_events += 1
	var items := _items()
	if index < 0 or index >= items.size():
		return
	var at := _chunk_label_char(items[index], index, sent)
	if at < 0:
		return
	_last_para = index
	_last_chunk_label = at
	_search_from = at - _paragraph_char(_label(), index)
	_note_spoken(at, index)


func _on_word(paragraph: int, char_pos: int) -> void:
	if not _measuring or _cur.is_empty() or _reader == null or not is_instance_valid(_reader):
		return
	_cur.word_events += 1
	if paragraph != _last_para or _last_chunk_label < 0:
		return
	if _new_api:
		# New tree: char_pos runs over the paragraph's whole spoken text.
		var items := _items()
		if paragraph < 0 or paragraph >= items.size():
			return
		var start := _paragraph_char(_label(), paragraph)
		if start < 0:
			return
		_note_spoken(start + _lead_extra(items[paragraph], paragraph) + char_pos, paragraph)
	else:
		# Old tree: char_pos runs over the spoken chunk it arrived in.
		_note_spoken(_last_chunk_label + char_pos, paragraph)


# --- summary -----------------------------------------------------------------

func _print_summary() -> void:
	for r in _results:
		print("FOLLOWCHECK mode=%s seconds=%.1f frames=%d scroll_frames=%d scrolls=%d long_frames=%d backward=%d big_jumps=%d para_events=%d sent_events=%d word_events=%d offscreen_events=%d off_time_s=%.2f longest_off_ms=%.0f reached_para=%d shots=%s" % [
			r.mode, float(r.seconds), r.frames, r.scroll_frames, r.scrolls,
			r.long_frames, r.backward, r.big_jumps, r.para_events,
			r.sent_events, r.word_events, r.offscreen_events, float(r.off_time),
			float(r.longest_off_ms), r.reached_para, ",".join(PackedStringArray(r.shots)),
		])


# --- screenshots ---------------------------------------------------------------

## Photographs the reading highlight on a tall paragraph for every tts_mode x
## tts_highlight combination (AFTER tree only: the overlay does not exist before).
func _run_shots(book: Dictionary) -> void:
	# AFTER tree only: the overlay this photographs does not exist before it.
	# Follow stays off here: sustained smooth-scroll following wedges the main
	# loop on this machine (see report), and a still never shows a scroll
	# mid-flight anyway. The highlight, player bar and placement are identical.
	Settings.set_value("tts_follow", false)
	# Device pixels, not layout points: on a scaled display the layout viewport
	# is smaller than the captured image.
	var prefix := "dt" if get_viewport().get_texture().get_image().get_width() >= 1000 else "ph"
	var combos := [
		["paragraph", "background"], ["paragraph", "underline"], ["paragraph", "color"],
		["sentence", "background"], ["sentence", "underline"], ["sentence", "color"],
	]
	var taken: Array = []
	for combo in combos:
		var mode := String(combo[0])
		var style := String(combo[1])
		Speech.stop()
		Settings.set_value("tts_highlight", style)
		Settings.set_value("tts_mode", mode)
		await get_tree().process_frame
		print("FOLLOWCHECK SHOT BEGIN ", mode, " ", style)
		await _main.open_reader(book["id"], 0)
		if not _wait_reader_ready():
			print("FOLLOWCHECK SHOT SKIP ", mode, " ", style, ": reader not ready")
			continue
		print("FOLLOWCHECK SHOT OPENED ", mode, " ", style, " items=", _items().size())
		for i in 6:
			await get_tree().process_frame
		var idx := _tall_para()
		print("FOLLOWCHECK SHOT TALL ", mode, " ", style, " para=", idx)
		_reader.start_tts(idx)
		var ok := await _wait_until(func(): return Speech.playing and Speech.current == idx and _reader.tts.highlight == idx, 30.0)
		print("FOLLOWCHECK SHOT WAITED ", mode, " ", style, " ok=", ok, " playing=", Speech.playing, " current=", Speech.current)
		if not ok:
			print("FOLLOWCHECK SHOT SKIP ", mode, " ", style, ": highlight never reached para ", idx)
			Speech.stop()
			continue
		# Sentence mode marks only the spoken sentence, so snap before speech
		# drifts past the first lines the paragraph placement shows.
		await _wait_secs(1.0 if mode == "sentence" else 3.0)
		# Instant placement instead of a follow scroll: same view, no tween.
		# The first scroll can settle the label layout once (paragraph offsets
		# shift under a steady scrollbar), so place, settle, then place again
		# from the fresh offsets; the last set re-lines the overlay too.
		_reader._scroll_to(idx, false)
		for i in 10:
			await get_tree().process_frame
		_reader._scroll_to(idx, false)
		for i in 6:
			await get_tree().process_frame
		var _bar := _label().get_v_scroll_bar()
		print("FOLLOWCHECK SHOT POS ", mode, " ", style, " bar=", (_bar as VScrollBar).value,
			" max=", (_bar as VScrollBar).max_value, " page=", (_bar as VScrollBar).page,
			" top4=", _label().get_paragraph_offset(idx), " size=", _label().size)
		var tag := "%s_%s_%s" % [prefix, mode, style]
		_snap(tag)
		_snap_crop(tag)
		taken.append(tag)
		print("FOLLOWCHECK SHOT ", tag, " para=", idx, " highlight=", _reader.tts.highlight)
		Speech.stop()
	Speech.stop()
	print("FOLLOWCHECK SHOTS done: ", ",".join(PackedStringArray(taken)))
	get_tree().quit(0)


## Tallest paragraph of the open chapter, in words of spoken text.
func _tall_para() -> int:
	var best := 0
	var best_w := -1
	for i in _items().size():
		var w: int = str((_items()[i] as Dictionary).get("tts", "")).split(" ", false).size()
		if w > best_w:
			best_w = w
			best = i
	return best


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var t := 0.0
	while t < timeout_s:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return bool(cond.call())


func _wait_secs(s: float) -> void:
	var t := 0.0
	while t < s:
		await get_tree().process_frame
		t += get_process_delta_time()


func _snap(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, tag]
	if img.save_png(path) == OK:
		print("FOLLOWCHECK SNAP ", path, " ", img.get_width(), "x", img.get_height())
		if not _cur.is_empty() and _measuring:
			_cur.shots.append(path)
	else:
		print("FOLLOWCHECK SNAP FAILED ", path)


## 3x nearest-neighbour crop of the highlighted region, for judging alignment.
func _snap_crop(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var full := Rect2i(Vector2i.ZERO, Vector2i(img.get_width(), img.get_height()))
	var r := _highlight_rect().grow(12).intersection(full)
	if r.size.x < 4 or r.size.y < 4:
		print("FOLLOWCHECK CROP SKIP ", tag, ": empty highlight rect")
		return
	var crop := img.get_region(r)
	crop.resize(r.size.x * 3, r.size.y * 3, Image.INTERPOLATE_NEAREST)
	var path := "%s/%s_crop.png" % [SHOT_DIR, tag]
	if crop.save_png(path) == OK:
		print("FOLLOWCHECK CROP ", path, " ", crop.get_width(), "x", crop.get_height())
	else:
		print("FOLLOWCHECK CROP FAILED ", path)


## Viewport-pixel box of the spoken highlight: the overlay rect when it shows,
## else the spoken line's box in the main label.
func _highlight_rect() -> Rect2i:
	if _new_api:
		var hl = _reader._hl_label
		var vis := hl != null and is_instance_valid(hl) and (hl as Control).visible
		print("FOLLOWCHECK HLRECT hl_valid=", hl != null and is_instance_valid(hl),
			" visible=", vis, " highlight=", _reader.tts.highlight,
			" sent=", _reader.tts.highlight_sentence,
			" mode=", Settings.get_value("tts_mode"), " style=", Settings.get_value("tts_highlight"))
		if vis:
			var r := (hl as Control).get_global_rect()
			print("FOLLOWCHECK HLRECT rect=", r, " head=", (hl as RichTextLabel).text.left(120))
			return Rect2i(r)
	var label := _label()
	var bar := label.get_v_scroll_bar()
	var p := label.get_global_rect().position + Vector2(0.0, _spoken_top - (bar as VScrollBar).value)
	return Rect2i(Rect2(p, Vector2(label.size.x, maxf(_spoken_bottom - _spoken_top, 2.0))))
