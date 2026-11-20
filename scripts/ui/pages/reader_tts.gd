class_name ReaderTts
extends RefCounted
## Reading-aloud controller for the reader's Read tab: starting and stopping,
## highlight state, follow-scrolling, queue-ahead for background playback,
## end-of-chapter advance, and the speech service signal handlers. The ReaderPage
## keeps the view (chapter loading, BBCode, tabs, bookmarks, details) and this
## helper calls back into it for those.

## Chapters handed to the speech service ahead of time on Android, so reading carries on
## while the app is in the background (where the reader can't load the next chapter).
## A few, for listening where there's no signal; more would download chapters nobody hears.
const CHAPTERS_AHEAD := 3

var page: ReaderPage
var highlight := -1          # paragraph being read, or -1
var highlight_sentence := -1  # sentence of highlight being read in sentence mode, or -1
var _follow_token := 0       # bumps so only the latest follow_sentence() scrolls
var _advance_token := 0      # bumps when navigation invalidates a waiting end-of-chapter advance
var _upcoming_token := 0     # bumps to cancel a running queue_upcoming()


func _init(p: ReaderPage) -> void:
	page = p


## Wires the speech service to the handlers below. Called once the page is ready.
func connect_signals() -> void:
	Speech.paragraph_started.connect(on_paragraph)
	Speech.sentence_started.connect(on_sentence)
	Speech.state_changed.connect(on_state)
	Speech.reached_end.connect(on_end)
	Speech.chapter_changed.connect(on_chapter)
	Speech.sleep_triggered.connect(on_sleep)


## Reads the current chapter aloud from `from`, or from the first visible paragraph.
## Waits while the chapter is still loading instead of giving up after a fixed delay;
## when loading fails the reader already shows why, so there is nothing more to say.
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
	while Speech.playing and Speech.source_owner == "reader" and Speech.chapters_ahead() < CHAPTERS_AHEAD:
		var index := page.chapter + Speech.chapters_ahead() + 1
		if index >= page.book.chapters.size():
			return
		var data: Dictionary = Library.load_chapter(id, index)
		if data.is_empty() or data.get("excerpt", false):
			data = await Sources.load_chapter(page.book, index, true)
			if token != _upcoming_token or page.book.get("id", "") != id:
				return
		if data.has("error") and not data.has("paragraphs"):
			return  # the reader will try again when it gets there
		Speech.append_chapter(ReaderPage._speech_items(page._make_items(data, index)), page.book.chapters[index].title)


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
		if Settings.get_value("tts_mode") == "sentence":
			follow_sentence()
		else:
			page._scroll_to(index, true)
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
			follow_sentence()


## Keeps the header's Listen / Stop button in step with playback, however it started or stopped.
func on_state(_playing: bool) -> void:
	page._update_player()
	if Speech.playing != page._listen_shown and page.main.current == page:
		page.header_changed.emit()


func on_sleep() -> void:
	set_highlight(-1)
	page.main.toast("Sleep timer: stopped reading.", "info")


## Sentence mode: scroll only once part of the sentence being read is off screen, and
## then put it near the top, so scrolls are as rare as possible. When the sentence
## can't be located, the whole paragraph counts. Waits a frame, for the label to lay
## out the re-rendered text.
func follow_sentence() -> void:
	_follow_token += 1
	var token := _follow_token
	await page.get_tree().process_frame
	if token != _follow_token or highlight < 0 or highlight >= page._items.size():
		return
	var it: Dictionary = page._items[highlight]
	var span := page._sentence_span(it, highlight_sentence)
	if span.x < 0:
		span = Vector2i(0, ReaderPage._visible_text(it.bb).length())
	var start := _paragraph_char(highlight)
	if start < 0:
		return
	if Library.bookmarks(page.book).any(func(m): return m.chapter == page.chapter and m.paragraph == highlight):
		start += 2  # the bookmark icon and the space after it
	if Settings.get_value("first_line_indent") and page._indented(it):
		start += 1  # the indent image
	var first := page._text.get_character_line(start + span.x)
	var last := page._text.get_character_line(start + maxi(span.x, span.y - 1))
	if first < 0 or last < 0:
		return
	var top := page._text.get_line_offset(first)
	var bottom := page._text.get_line_offset(last) + page._text.get_line_height(last)
	var bar := page._text.get_v_scroll_bar()
	if top >= bar.value and bottom <= bar.value + page._text.size.y:
		return
	var y := clampf(top - int(Settings.get_value("font_size")), 0, bar.max_value)
	page.create_tween().tween_property(bar, "value", y, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


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
