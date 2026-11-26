class_name ReaderTts
extends RefCounted
## Reading-aloud controller for the reader's Read tab: starting and stopping,
## highlight state, follow-scrolling, queue-ahead for background playback,
## end-of-chapter advance, and the speech service signal handlers. The ReaderPage
## keeps the view (chapter loading, BBCode, tabs, bookmarks, details) and this
## helper calls back into it for those.

## Chapters handed to the speech service ahead of time on Android, so reading carries on
## while the app is in the background (where the reader can't load the next chapter).
## A few downloaded, for listening where there's no signal; more would download chapters
## nobody hears. Chapters already saved in full cost no download, so those reach further.
const CHAPTERS_AHEAD := 3
const SAVED_AHEAD := 30

## After a manual scroll or drag, leave the view alone this long, so looking
## around isn't yanked back on the next word; the next chunk start resumes anyway.
const FOLLOW_HOLD_MS := 2000
## Starting guess of characters spoken per second at 1x, for the estimate used where
## the platform sends no word positions. Measured chunk timings replace it quickly.
const EST_CPS := 14.0

var page: ReaderPage
var highlight := -1          # paragraph being read, or -1
var highlight_sentence := -1  # sentence of highlight being read in sentence mode, or -1
var _spoken_para := -1       # paragraph the spoken position below was measured in
var _spoken_chunk := 0       # chunk (sentence) of it being spoken
var _spoken_off := 0         # chars past the chunk start already spoken
var _spoken_msec := 0        # when _spoken_off was measured (Time.get_ticks_msec)
var _starts := PackedInt32Array()  # chunk starts in the paragraph's spoken text
var _chunks := PackedStringArray()  # chunks of _spoken_para as the voice hears them
var _disp := PackedInt32Array()  # chunk starts in visible chars; empty when unmappable
var _last_touch_msec := 0    # last manual scroll/drag on the text
var _cps := EST_CPS          # measured characters per second at 1x
var _had_words := false      # word positions arrived for the current chunk
var _tick: Timer             # estimate ticks where no word positions arrive
var _follow_token := 0       # bumps so only the latest _follow_start() scrolls
var _advance_token := 0      # bumps when navigation invalidates a waiting end-of-chapter advance
var _upcoming_token := 0     # bumps to cancel a running queue_upcoming()


func _init(p: ReaderPage) -> void:
	page = p


## Wires the speech service to the handlers below. Called once the page is ready.
func connect_signals() -> void:
	Speech.paragraph_started.connect(on_paragraph)
	Speech.sentence_started.connect(on_sentence)
	Speech.word_boundary.connect(on_word)
	Speech.state_changed.connect(on_state)
	Speech.reached_end.connect(on_end)
	Speech.chapter_changed.connect(on_chapter)
	Speech.sleep_triggered.connect(on_sleep)
	_tick = Timer.new()
	_tick.wait_time = 0.3
	_tick.timeout.connect(_follow_tick)
	page.add_child(_tick)
	_tick.start()
	page._text.gui_input.connect(_on_text_input)


## Reads the current chapter aloud from `from`, or from the first visible paragraph.
## Waits while the chapter is still loading; when loading fails the reader
## already shows why, so there is nothing more to say.
func start(from := -1) -> void:
	if not Speech.is_supported():
		page.main.toast("Text-to-speech isn't available on this device.", "warn")
		return
	if page._items.is_empty() and page._loading:
		var id: String = page.book.get("id", "")
		var ch := page.chapter
		while page._loading and page.book.get("id", "") == id and page.chapter == ch:
			await page.get_tree().process_frame
		if page.book.get("id", "") != id or page.chapter != ch:
			return  # the user opened something else while this chapter loaded
	if page._items.is_empty():
		return
	var at := from if from >= 0 else page._first_visible()
	Speech.play(ReaderPage._speech_items(page._items), at, "reader", page.book.title, page.book.chapters[page.chapter].title)
	page.header_changed.emit()
	queue_upcoming()


func toggle() -> void:
	if Speech.playing:
		Speech.stop()
		set_highlight(-1)
	else:
		start()


## Forgets the highlight without touching the chapter text (it is being rebuilt anyway).
func clear_silent() -> void:
	highlight = -1
	highlight_sentence = -1


## Drops the highlight and refreshes the view.
func clear_highlight() -> void:
	set_highlight(-1)


## A navigation happened; a waiting end-of-chapter advance must not fire for it.
func bump_advance() -> void:
	_advance_token += 1


## Marks paragraph `i` (and sentence `sent`) as being read. Only the old and new
## highlighted paragraphs are rebuilt; the rest of the chapter text is reused as-is.
func set_highlight(i: int, sent := -1) -> void:
	if Settings.get_value("tts_mode") != "sentence":
		sent = -1
	if highlight == i and highlight_sentence == sent:
		return
	var old := highlight
	highlight = i
	highlight_sentence = sent
	page.refresh_highlight(old, i)


## Scrolls to the paragraph being read aloud (used when jumping back from the sidebar).
func reveal() -> void:
	if Speech.playing and Speech.source_owner == "reader" and Speech.items.size() == page._items.size():
		set_highlight(Speech.current, Speech.current_sentence())
		page._scroll_to(Speech.current, false)


## Hands the next chapters to the speech service (Android), loading them first if needed.
func queue_upcoming() -> void:
	if not Speech.reads_ahead() or not Settings.get_value("tts_auto_advance"):
		return
	_upcoming_token += 1
	var token := _upcoming_token
	var id: String = page.book.id
	while Speech.playing and Speech.source_owner == "reader":
		var ahead := Speech.chapters_ahead()
		var index := page.chapter + ahead + 1
		if index >= page.book.chapters.size():
			return
		if ahead >= SAVED_AHEAD:
			return
		var saved := Library.has_full_chapter(id, index)
		if ahead >= CHAPTERS_AHEAD and not saved:
			return
		var data: Dictionary = Library.load_chapter(id, index)
		if data.is_empty() or data.get("excerpt", false):
			data = await Sources.load_chapter(page.book, index, true)
			if token != _upcoming_token or page.book.get("id", "") != id:
				return
		if data.has("error") and not data.has("paragraphs"):
			return  # the reader will try again when it gets there
		Speech.append_chapter(ReaderPage._speech_items(page._make_items(data, index)), page.book.chapters[index].title)
		if saved:
			await page.get_tree().process_frame
			if token != _upcoming_token or page.book.get("id", "") != id:
				return


## The speech service moved on to a chapter that queue_upcoming() handed over.
func on_chapter(delta: int) -> void:
	if page.book.is_empty() or Speech.source_owner != "reader":
		return
	page.chapter = clampi(page.chapter + delta, 0, page.book.chapters.size() - 1)
	await page._load_chapter(maxi(Speech.current, 0))
	reveal()
	queue_upcoming()


func on_paragraph(index: int) -> void:
	if not page.is_inside_tree() or Speech.source_owner != "reader" or Speech.items.size() != page._items.size():
		return
	set_highlight(index, Speech.current_sentence())
	if Settings.get_value("tts_follow"):
		_follow_start(index, Speech.current_sentence(), Settings.get_value("tts_mode") != "sentence")
	page._update_player()


func on_end() -> void:
	if page.book.is_empty() or Speech.source_owner != "reader" or Speech.items.size() != page._items.size():
		return  # speech that the reader didn't start
	set_highlight(-1)
	if Speech.stops_at_chapter_end():
		Speech.set_sleep(0)
		page.main.toast("Sleep timer: stopped at the end of the chapter.")
		page.header_changed.emit()
		return
	if Settings.get_value("tts_auto_advance") and page.chapter < page.book.chapters.size() - 1:
		_advance_token += 1
		var token := _advance_token
		var id: String = page.book.get("id", "")
		var ch := page.chapter
		await page.get_tree().create_timer(int(Settings.get_value("tts_pause_chapter")) / 1000.0).timeout
		if token != _advance_token or page.book.get("id", "") != id or page.chapter != ch:
			return  # the user moved on while the pause ran
		if page.visible:
			page.go_to_chapter(ch + 1, true)
	else:
		page.header_changed.emit()


func on_sentence(index: int, sent: int) -> void:
	if not page.is_inside_tree() or Speech.source_owner != "reader" or Speech.items.size() != page._items.size():
		return
	if index == highlight:
		set_highlight(index, sent)
		if Settings.get_value("tts_follow"):
			_follow_start(index, sent, false)


## Keeps the header's Listen / Stop button in step with playback, however it started or stopped.
func on_state(_playing: bool) -> void:
	page._update_player()
	if Speech.playing != page._listen_shown and page.main.current == page:
		page.header_changed.emit()


func on_sleep() -> void:
	set_highlight(-1)
	page.main.toast("Sleep timer: stopped reading.", "info")


## A word position arrived: record it and keep its line on screen. Layout is
## settled (no re-render happens on words), so no frame wait is needed.
func on_word(paragraph: int, char_pos: int) -> void:
	if paragraph != _spoken_para or _starts.is_empty():
		return  # a new chunk start anchors it; never scroll on a stale position
	var chunk := 0
	for k in _starts.size():
		if _starts[k] <= char_pos:
			chunk = k
	_spoken_chunk = mini(chunk, maxi(_chunks.size() - 1, 0))
	_spoken_off = char_pos - _starts[_spoken_chunk]
	_spoken_msec = Time.get_ticks_msec()
	_had_words = true
	_follow_line()


## A manual scroll or drag: hold follow scrolls briefly, and stop the one in
## flight so it doesn't fight the finger. The next chunk start resumes following.
func _on_text_input(event: InputEvent) -> void:
	var touched := event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventPanGesture
	if event is InputEventMouseButton and event.pressed:
		touched = true
	if event is InputEventMouseMotion and event.button_mask != 0:
		touched = true
	if touched:
		_last_touch_msec = Time.get_ticks_msec()
		page.stop_smooth_scroll()


## The estimate tick: where no word positions arrive, advance the spoken position
## by elapsed time and keep its line on screen.
func _follow_tick() -> void:
	if highlight < 0:
		return
	_follow_line()


## A new chunk started: anchor the spoken position, then (in paragraph mode)
## place the paragraph and make sure the spoken line is visible once layout
## has settled for the re-rendered highlight.
func _follow_start(para: int, chunk: int, place: bool) -> void:
	_anchor(para, chunk)
	_follow_token += 1
	var token := _follow_token
	await page.get_tree().process_frame
	if token != _follow_token or not _follow_ready(para):
		return
	if place:
		_place_paragraph(para)
	_follow_line()


## Remembers where the voice is: the start of chunk `chunk` of paragraph `para`,
## with the chunk starts in spoken and in visible characters for mapping later.
func _anchor(para: int, chunk: int) -> void:
	_measure_speed(para, chunk)
	_spoken_para = para
	_spoken_chunk = maxi(chunk, 0)
	_spoken_off = 0
	_spoken_msec = Time.get_ticks_msec()
	_had_words = false
	_chunks = PackedStringArray()
	_starts = PackedInt32Array()
	_disp = PackedInt32Array()
	if para < 0 or para >= page._items.size():
		return
	var it: Dictionary = page._items[para]
	_chunks = Speech.split({"text": it.tts, "kind": it.kind})
	if _spoken_chunk >= _chunks.size():
		_spoken_chunk = maxi(_chunks.size() - 1, 0)
	var text := str(it.get("tts", ""))
	for k in _chunks.size():
		var off := Speech.chunk_offset(text, _chunks, k)
		if off == -1:
			_starts = PackedInt32Array()
			break
		_starts.append(off)
	if _starts.is_empty():
		return
	var shown := ReaderMarkup.visible_text(it.bb)
	var from := 0
	for k in _chunks.size():
		var at := shown.find(_chunks[k], from)
		if at == -1:
			_disp = PackedInt32Array()
			return
		_disp.append(at)
		from = at + _chunks[k].length()


## Whether a follow scroll for `para` is wanted right now at all. Never while
## paused: the view stays wherever the reader scrolled it until playback resumes.
func _follow_ready(para: int) -> bool:
	return (Settings.get_value("tts_follow") and Speech.is_active()
		and Speech.source_owner == "reader" and Speech.items.size() == page._items.size()
		and para == highlight and para == _spoken_para
		and page.is_inside_tree() and page._read_view.visible)


## Start of a paragraph in paragraph mode: keep the 28% placement when the whole
## paragraph fits on screen, else put its first line near the top so the most
## lines are visible and the word-by-word follow takes it from there.
func _place_paragraph(para: int) -> void:
	var top := page._text.get_paragraph_offset(para)
	var bottom := page._text.get_paragraph_offset(para + 1) if para + 1 < page._items.size() else float(page._text.get_content_height())
	if bottom - top > page._text.get_v_scroll_bar().page * 0.72:
		page.smooth_scroll_to(maxf(0.0, top - _lead()))
	else:
		page._scroll_to(para, true)


## Keeps the line being spoken inside the actually visible text: the viewport
## minus the top margin and the player bar's bottom margin, with a line's margin.
## Scrolls rarely, page-turn-like: only when the line is above the top or gets
## near the bottom, and never while the user just scrolled by hand.
func _follow_line() -> void:
	if not _follow_ready(highlight):
		return
	if Time.get_ticks_msec() - _last_touch_msec < FOLLOW_HOLD_MS:
		return
	var label_char := _spoken_label_char()
	if label_char < 0:
		return
	var line := page._text.get_character_line(label_char)
	if line < 0:
		return
	var top := page._text.get_line_offset(line)
	var bottom := top + page._text.get_line_height(line)
	var bar := page._text.get_v_scroll_bar()
	var vtop := page.scroll_target()
	var y := follow_scroll_y(top, bottom, vtop, vtop + bar.page, _lead(), bar.max_value - bar.page)
	if y >= 0.0:
		page.smooth_scroll_to(y)


## Content offset that puts the spoken line (top..bottom) `lead` below the top of
## the visible band (vtop..vbottom), or -1 when it is comfortably inside. Scrolls
## once the line is within two lines of the bottom, so an estimated position that
## runs a little behind the voice still scrolls before the voice leaves the screen,
## and the lead keeps one that runs a little ahead on screen too. Line offsets and
## the band are in content coordinates, which leave out the stylebox margins. Pure.
static func follow_scroll_y(top: float, bottom: float, vtop: float, vbottom: float, lead: float, max_y: float) -> float:
	if top < vtop or bottom > vbottom - 2.0 * (bottom - top):
		return clampf(top - lead, 0.0, maxf(max_y, 0.0))
	return -1.0


## Label character of the spoken position, or -1 when it can't be located. In
## sentence mode the sentence mark gives it exactly; otherwise chunk starts are
## mapped into the shown text when the speech rules left it alone, else the
## paragraph start counts (conservative: never past words actually spoken).
func _spoken_label_char() -> int:
	if highlight < 0 or highlight >= page._items.size():
		return -1
	var it: Dictionary = page._items[highlight]
	var prog := _spoken_progress()
	if Settings.get_value("tts_mode") == "sentence":
		var span := page._sentence_span(it, highlight_sentence)
		if span.x >= 0:
			var shown := span.x
			if _spoken_chunk == highlight_sentence:
				shown += mini(prog, span.y - span.x)
			return _label_char_of(highlight, shown)
	if not _disp.is_empty() and _spoken_chunk < _disp.size():
		return _label_char_of(highlight, _disp[_spoken_chunk] + prog)
	return _label_char_of(highlight, 0)


## Chars past the current chunk start already spoken: the last measured position
## plus elapsed time at the reading rate (frozen while paused), capped at the
## chunk length so the estimate can't run into the next chunk.
func _spoken_progress() -> int:
	if Speech.paused:
		return _spoken_off
	var el := float(Time.get_ticks_msec() - _spoken_msec) / 1000.0
	var prog := float(_spoken_off) + maxf(el, 0.0) * float(Settings.get_value("tts_rate")) * _cps
	var cap := _chunks[_spoken_chunk].length() if _spoken_chunk < _chunks.size() else -1
	return mini(int(prog), cap) if cap >= 0 else int(prog)


## Label character of visible offset `shown` of paragraph `para`.
func _label_char_of(para: int, shown: int) -> int:
	var start := _paragraph_char(para)
	if start < 0:
		return -1
	var it: Dictionary = page._items[para]
	if Library.bookmarks(page.book).any(func(m): return m.chapter == page.chapter and m.paragraph == para):
		start += 2  # the bookmark icon and the space after it
	if Settings.get_value("first_line_indent") and page._indented(it):
		start += 1  # the indent image
	return start + maxi(shown, 0)


## Room kept above the spoken line after a follow scroll: enough that an estimate
## running ahead of the voice still leaves the voice on screen.
func _lead() -> float:
	var page_h := page._text.get_v_scroll_bar().page
	return maxf(float(Settings.get_value("font_size")), page_h * 0.15)


## When chunk `chunk` of `para` starts right after the chunk being tracked, learns
## the voice's speed from how long that one took (less the pause after it), so the
## estimate follows the actual voice, engine and rate.
func _measure_speed(para: int, chunk: int) -> void:
	if _had_words or _spoken_para < 0 or _spoken_chunk >= _chunks.size() or Speech.paused:
		return
	var next := (para == _spoken_para and chunk == _spoken_chunk + 1) or (para == _spoken_para + 1 and chunk == 0 and _spoken_chunk == _chunks.size() - 1)
	if not next:
		return
	var rate := float(Settings.get_value("tts_rate"))
	var gap := Speech._gap_ms(Speech.items, _spoken_para, _spoken_chunk, _chunks) if _spoken_para < Speech.items.size() else 0
	var secs := float(Time.get_ticks_msec() - _spoken_msec - gap) / 1000.0
	var chars := _chunks[_spoken_chunk].length()
	if secs <= 0.5 or chars < 40 or rate <= 0.0:
		return  # too short to time reliably
	var cps := chars / secs / rate
	if cps > 5.0 and cps < 40.0:
		_cps = lerpf(_cps, cps, 0.5)


## Index in the label's characters of the first one of paragraph `paragraph`, or -1.
func _paragraph_char(paragraph: int) -> int:
	var lo := 0
	var hi := page._text.get_total_character_count()
	while lo < hi:
		var mid := (lo + hi) / 2
		if page._text.get_character_paragraph(mid) < paragraph:
			lo = mid + 1
		else:
			hi = mid
	return lo if page._text.get_character_paragraph(lo) == paragraph else -1
