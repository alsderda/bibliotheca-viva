class_name ReaderPage
extends Page
## Reader with Read / Contents / Details / Bookmarks tabs, display settings and a TTS player.

const RATES := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

var book := {}
var chapter := 0
var _items: Array = []           # [{kind, bb, tts}] one per RichTextLabel paragraph
var _data := {}                  # raw chapter data, kept so rules can be re-applied
var _load_token := 0
var _highlight := -1
var _highlight_sentence := -1    # sentence of _highlight being read in sentence mode, or -1
var _follow_token := 0           # bumps so only the latest _follow_sentence() scrolls
var _listen_shown := false       # whether the header's Listen button currently shows "Stop"
var _excerpt := false
var _restoring := false
var _save_timer: Timer

var _bg: ColorRect
var _read_view: Control
var _text: RichTextLabel
var _status: VBoxContainer
var _banner: Control
var _footer: PanelContainer
var _footer_label: Label
var _footer_bar: ProgressBar
var _player: PanelContainer
var _play_btn: Button
var _player_label: Label
var _player_info: Control
var _rate_btn: Button
var _contents_view: Control
var _contents_list: VBoxContainer
var _details_view: Control
var _bookmarks_view: Control
var _bookmarks_list: VBoxContainer
var _menu_paragraph := -1        # paragraph the context menu was opened on
var _press_timer: Timer          # long-press on a paragraph (touch screens)
var _press_at := Vector2.ZERO
var _sleep_btn: Button
var _epub_dialog: FileDialog
var _cover_dialog: FileDialog
var _advance_token := 0
var _upcoming_token := 0
var _search_view: SearchView
var _find := {}                  # search match marked on the Read tab: {paragraph, from, to}

## Chapters handed to the speech service ahead of time on Android, so reading carries on
## while the app is in the background (where the reader can't load the next chapter).
## A few, for listening where there's no signal; more would download chapters nobody hears.
const CHAPTERS_AHEAD := 3

const SEARCH_TAB := 2
const DETAILS_TAB := 3

const MENU_FIX_SPEECH := 100
const MENU_SKIP_SPEECH := 101
const MENU_REPLACE_TEXT := 102
const MENU_BOOKMARK := 103

const BOOKMARKS_TAB := 4


func _ready() -> void:
	_bg = ColorRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_build_read_view()
	_build_contents_view()
	_search_view = SearchView.new(self)
	_search_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_search_view.set_compact(compact)
	_search_view.hide()
	add_child(_search_view)
	_details_view = Control.new()
	_details_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_details_view)
	_build_bookmarks_view()
	_build_aa_popup()

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.8
	_save_timer.timeout.connect(_save_progress)
	add_child(_save_timer)

	Settings.changed.connect(_on_setting)
	Speech.paragraph_started.connect(_on_tts_paragraph)
	Speech.sentence_started.connect(_on_tts_sentence)
	Speech.state_changed.connect(_on_tts_state)
	Speech.reached_end.connect(_on_tts_end)
	Speech.chapter_changed.connect(_on_tts_chapter)
	Speech.sleep_changed.connect(_update_player)
	Speech.sleep_triggered.connect(func(): _set_highlight(-1); main.toast("Sleep timer: stopped reading.", "info"))
	TextRules.changed.connect(_on_rules_changed)
	Library.chapter_saved.connect(func(id, index):
		if not book.is_empty() and id == book.id and index == chapter and _excerpt and not Speech.playing:
			book = Library.get_book(id)
			_load_chapter(0))
	_setup_context_menu()
	_build_tts_popup()
	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.timeout.connect(func(): if Speech.playing and Speech.sleep_minutes > 0: _update_player())
	add_child(tick)
	tick.start()
	_text.resized.connect(_apply_layout)
	_apply_style()


func page_title() -> String:
	return book.get("title", "Reader")


func tabs() -> PackedStringArray:
	return ["Read", "Contents", "Search", "Details", "Bookmarks"]


func nav_key() -> String:
	return "library"


func has_back() -> bool:
	return true


func go_back() -> void:
	_save_progress()
	main.navigate("library")


func build_actions(bar: HBoxContainer) -> void:
	if not compact:
		var prev := UI.icon_button("chev_left", "Previous chapter (←)", func(): go_to_chapter(chapter - 1))
		prev.disabled = chapter <= 0
		bar.add_child(prev)
		var nxt := UI.icon_button("chev_right", "Next chapter (→)", func(): go_to_chapter(chapter + 1))
		nxt.disabled = chapter >= book.get("chapters", []).size() - 1
		bar.add_child(nxt)
	var aa := UI.icon_button("type", "Display settings", _show_aa)
	aa.name = "AaButton"
	bar.add_child(aa)
	_listen_shown = Speech.playing
	var listen := UI.button("" if compact else ("Stop" if Speech.playing else "Listen"), "stop" if Speech.playing else "headphones",
		"" if Speech.playing else "PrimaryButton", toggle_tts)
	listen.tooltip_text = "Read aloud (Space)"
	bar.add_child(listen)


func _on_tab(i: int) -> void:
	_read_view.visible = i == 0
	_bg.visible = i == 0
	_contents_view.visible = i == 1
	_search_view.visible = i == SEARCH_TAB
	_details_view.visible = i == DETAILS_TAB
	_bookmarks_view.visible = i == BOOKMARKS_TAB
	if i == 1:
		_build_contents()
	elif i == SEARCH_TAB:
		_search_view.refresh()
	elif i == DETAILS_TAB:
		_build_details()
	elif i == BOOKMARKS_TAB:
		_build_bookmarks()


func on_hidden() -> void:
	_save_progress()


## Scroll to the paragraph being read aloud (used when jumping back from the sidebar).
func reveal_speech() -> void:
	if Speech.playing and Speech.source_owner == "reader" and Speech.items.size() == _items.size():
		_set_highlight(Speech.current, Speech.current_sentence())
		_scroll_to(Speech.current, false)


# --- loading -----------------------------------------------------------------

func open_book(id: String, ch := -1) -> void:
	if Speech.playing and (book.get("id", "") != id or Speech.source_owner != "reader"):
		Speech.stop()
	book = Library.get_book(id)
	if book.is_empty():
		return
	chapter = clampi(ch if ch >= 0 else book.progress.chapter, 0, max(0, book.chapters.size() - 1))
	var para: int = book.progress.paragraph if ch < 0 else 0
	select_tab(0)
	await _load_chapter(para)


func go_to_chapter(index: int, start_tts := false) -> void:
	if index < 0 or index >= book.chapters.size():
		return
	var was_playing := Speech.playing
	Speech.stop()
	chapter = index
	header_changed.emit()
	await _load_chapter(0)
	Library.set_progress(book.id, chapter, 0)
	if start_tts or was_playing:
		start_tts(0)


func _load_chapter(paragraph: int) -> void:
	_load_token += 1
	var token := _load_token
	_highlight = -1
	_highlight_sentence = -1
	_find = {}
	_items.clear()  # so nothing re-renders the previous chapter while this one loads or fails
	_data = {}
	_text.text = ""
	_banner.hide()
	_set_status("Loading chapter…")
	header_changed.emit()
	_update_footer()
	var data: Dictionary = Library.load_chapter(book.id, chapter)
	if data.is_empty() or data.get("excerpt", false):
		data = await Sources.load_chapter(book, chapter)
	if token != _load_token:
		return
	if data.has("error") and not data.has("paragraphs"):
		_set_status(data.error, true)
		return
	_set_status("")
	_excerpt = data.get("excerpt", false)
	_banner.visible = _excerpt
	_data = data
	_items = _make_items(data, chapter)
	_render()
	await get_tree().process_frame
	_restoring = true
	_scroll_to(paragraph, false)
	_restoring = false
	Library.set_progress(book.id, chapter, paragraph)
	_update_footer()
	_prefetch(chapter + 1)


func _prefetch(index: int) -> void:
	if book.kind == "web" and index < book.chapters.size() and not Library.has_chapter(book.id, index):
		Sources.load_chapter(book, index, true)


## The paragraphs of chapter `index` as the Read tab shows them (used by the Search tab).
func chapter_items(data: Dictionary, index: int) -> Array:
	return _make_items(data, index)


func _make_items(data: Dictionary, index: int) -> Array:
	var items := []
	var paras: Array = Array(data.get("paragraphs", []))
	var title: String = book.chapters[index].title
	var starts_with_title := paras.size() > 0 and HtmlText.is_heading(paras[0])
	if paras.size() > 0 and not starts_with_title and HtmlText.plain(paras[0]).strip_edges().to_lower() == title.strip_edges().to_lower():
		paras.remove_at(0)
	if not starts_with_title:
		_add_item(items, "title", _esc(title))
	for p in paras:
		_add_item(items, "heading" if HtmlText.is_heading(p) else "p", p.replace(HtmlText.HEADING, ""))
	return items


## Runs the user's text rules: display rules change `bb`, speech rules change `tts`.
func _add_item(items: Array, kind: String, bb: String) -> void:
	var shown := TextRules.apply_display(bb, book.id)
	var spoken := TextRules.apply_tts(HtmlText.plain(bb), book.id).strip_edges()
	if HtmlText.plain(shown).strip_edges() == "" and spoken == "":
		return  # rules removed this paragraph entirely
	items.append({"kind": kind, "bb": shown, "tts": spoken})


static func _speech_items(items: Array) -> Array:
	return items.map(func(it): return {"text": it.tts, "kind": it.kind})


func _on_rules_changed() -> void:
	if _data.is_empty() or book.is_empty():
		return
	var resume := Speech.current if Speech.playing else -1
	_items = _make_items(_data, chapter)
	_render()
	if resume >= 0:
		start_tts(mini(resume, _items.size() - 1))


func _render() -> void:
	var colors := Settings.reader_colors()
	var size := int(Settings.get_value("font_size"))
	var hl: String = colors.highlight.to_html()
	var parts := PackedStringArray()
	var first_heading := true
	var marked := {}
	for m in Library.bookmarks(book):
		if m.chapter == chapter:
			marked[m.paragraph] = true
	var marker := _marker_bbcode(size) if not marked.is_empty() else ""
	var indent := indent_bbcode(size) if Settings.get_value("first_line_indent") else ""
	for i in _items.size():
		var it: Dictionary = _items[i]
		var bb: String = it.bb
		if i == _highlight:
			bb = _highlighted(it, hl, colors)
		elif i == _find.get("paragraph", -1):
			bb = _mark_span(bb, _find.from, _find.to, "[bgcolor=%s]" % Color(UiTheme.WARN, 0.4).to_html(), "[/bgcolor]")
		if indent != "" and _indented(it):
			bb = indent + bb
		if marked.has(i):
			bb = marker + bb
		if it.kind == "title" or (it.kind == "heading" and first_heading):
			bb = "[center][font_size=%d][b]%s[/b][/font_size][/center]" % [int(size * 1.45), bb]
			first_heading = false
		elif it.kind == "heading":
			bb = "[font_size=%d][b]%s[/b][/font_size]" % [int(size * 1.15), bb]
		parts.append(bb)
	var v := _text.get_v_scroll_bar().value
	_text.text = "\n".join(parts)
	_text.get_v_scroll_bar().value = v


## An inline bookmark icon for the start of bookmarked paragraphs. [img] only takes
## a resource path, so the icon (made at runtime) is registered under one.
func _marker_bbcode(font_size: int) -> String:
	var s := int(font_size * 0.85)
	var tex := Icons.get_icon("bookmark_fill", UiTheme.ACCENT, s)
	var path := "res://__bookmark_marker_%d.tres" % s
	if tex.resource_path != path:
		tex.take_over_path(path)
	return "[img width=%d height=%d]%s[/img] " % [s, s, path]


## An invisible inline gap that indents a paragraph's first line. An image rather than
## spaces, so justified text doesn't stretch it.
static func indent_bbcode(font_size: int) -> String:
	const PATH := "res://__first_line_indent.tres"
	if _indent_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_indent_tex = ImageTexture.create_from_image(img)
		_indent_tex.take_over_path(PATH)
	return "[img width=%d height=1]%s[/img]" % [int(font_size * 1.5), PATH]


static var _indent_tex: ImageTexture


## Whether the first-line indent applies to this item: body paragraphs only.
func _indented(it: Dictionary) -> bool:
	return it.kind != "title" and it.kind != "heading"


## The item's bbcode with the part being read aloud marked: the sentence in sentence
## mode, or the whole paragraph.
func _highlighted(it: Dictionary, hl: String, colors: Dictionary) -> String:
	var tags: Array
	match str(Settings.get_value("tts_highlight")):
		"background": tags = ["[bgcolor=%s]" % hl, "[/bgcolor]"]
		"underline": tags = ["[u]", "[/u]"]
		"color": tags = ["[color=%s]" % UiTheme.ACCENT.darkened(0.15 if colors.bg.get_luminance() > 0.5 else 0.0).to_html(), "[/color]"]
		_: return it.bb
	var span := _sentence_span(it, _highlight_sentence)
	if span.x < 0:
		return tags[0] + it.bb + tags[1]
	return _mark_span(it.bb, span.x, span.y, tags[0], tags[1])


## Start and end (in visible characters) of sentence `sentence` of the item's text, or
## (-1, -1) when only the whole paragraph can be marked: outside sentence mode, or when
## speech rules changed the text so its sentences don't line up with the shown ones.
func _sentence_span(it: Dictionary, sentence: int) -> Vector2i:
	if sentence < 0 or Settings.get_value("tts_mode") != "sentence":
		return Vector2i(-1, -1)
	var spoken := Speech.split({"text": it.tts, "kind": it.kind})
	var shown_text := _visible_text(it.bb)
	var shown := Speech.split_sentences(shown_text)
	if spoken.size() != shown.size() or sentence >= shown.size():
		return Vector2i(-1, -1)
	var from := 0
	for k in sentence + 1:
		from = shown_text.find(shown[k], from)
		if from == -1:
			return Vector2i(-1, -1)
		if k < sentence:
			from += shown[k].length()
	return Vector2i(from, from + shown[sentence].length())


## The text a bbcode paragraph shows: tags dropped, [lb]/[rb] as brackets.
static func _visible_text(bb: String) -> String:
	return _mark_span(bb, 0, 0, "", "", true)


## Wraps visible characters `from`..`to` of `bb` in `open`/`close`, closing and reopening
## around any tag inside so the result stays properly nested. With `text_only`, returns
## just the visible text instead.
static func _mark_span(bb: String, from: int, to: int, open: String, close: String, text_only := false) -> String:
	var out := ""
	var pos := 0          # visible characters so far
	var marking := false
	var i := 0
	while i < bb.length():
		var token := bb[i]
		var visible := true
		if token == "[":
			var j := bb.find("]", i)
			if j != -1:
				token = bb.substr(i, j - i + 1)
				visible = token == "[lb]" or token == "[rb]"
		i += token.length()
		if text_only:
			if visible:
				out += "[" if token == "[lb]" else ("]" if token == "[rb]" else token)
			continue
		var inside := visible and pos >= from and pos < to
		if marking and not inside:
			out += close
			marking = false
		if inside and not marking:
			out += open
			marking = true
		out += token
		if visible:
			pos += 1
	if marking:
		out += close
	return out


## Opens chapter `index` at a search match and marks it. If the chapter changed since
## the search (new text rules, a full download), marks the first place `matched` is found.
func show_match(index: int, paragraph: int, from: int, matched: String) -> void:
	select_tab(0)
	header_changed.emit()
	if index != chapter or _items.is_empty():
		Speech.stop()
		chapter = index
		await _load_chapter(paragraph)
	if chapter != index or _items.is_empty():
		return  # the chapter didn't load; its status message says why
	var p := paragraph
	if p >= _items.size() or _visible_text(_items[p].bb).substr(from, matched.length()) != matched:
		p = -1
		for k in _items.size():
			from = _visible_text(_items[k].bb).find(matched)
			if from != -1:
				p = k
				break
		if p == -1:
			return
	_find = {"paragraph": p, "from": from, "to": from + matched.length()}
	_render()
	await get_tree().process_frame
	_scroll_to(p, false)
	Library.set_progress(book.id, chapter, p)


func _set_status(message: String, is_error := false) -> void:
	UI.clear(_status)
	_status.visible = message != ""
	if message == "":
		return
	var colors := Settings.reader_colors()
	var l := UI.label(message, "", true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size.x = 320
	l.add_theme_color_override("font_color", colors.muted)
	_status.add_child(l)
	if is_error:
		var row := UI.hbox(10)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var url: String = book.chapters[chapter].get("url", "")
		row.add_child(UI.button("Retry", "refresh", "", func():
			Net.end_break(url if url != "" else str(book.get("url", "")))
			_load_chapter(0)))
		if url != "":
			if main.web_available():
				row.add_child(UI.button("Open in Web tab", "globe", "PrimaryButton", func(): main.open_web(url)))
			row.add_child(UI.button("Open in browser", "external", "", func(): OS.shell_open(url)))
		_status.add_child(row)


# --- TTS ---------------------------------------------------------------------

func toggle_tts() -> void:
	if Speech.playing:
		Speech.stop()
		_set_highlight(-1)
	else:
		start_tts()


func start_tts(from := -1) -> void:
	if not Speech.is_supported():
		main.toast("Text-to-speech isn't available on this device.", "warn")
		return
	if _items.is_empty():
		await get_tree().create_timer(0.3).timeout
		if _items.is_empty():
			return
	var start := from if from >= 0 else _first_visible()
	Speech.play(_speech_items(_items), start, "reader", book.title, book.chapters[chapter].title)
	header_changed.emit()
	_queue_upcoming()


## Hands the next chapters to the speech service (Android), loading them first if needed.
func _queue_upcoming() -> void:
	if not Speech.reads_ahead() or not Settings.get_value("tts_auto_advance"):
		return
	_upcoming_token += 1
	var token := _upcoming_token
	var id: String = book.id
	while Speech.playing and Speech.source_owner == "reader" and Speech.chapters_ahead() < CHAPTERS_AHEAD:
		var index := chapter + Speech.chapters_ahead() + 1
		if index >= book.chapters.size():
			return
		var data: Dictionary = Library.load_chapter(id, index)
		if data.is_empty() or data.get("excerpt", false):
			data = await Sources.load_chapter(book, index, true)
			if token != _upcoming_token or book.get("id", "") != id:
				return
		if data.has("error") and not data.has("paragraphs"):
			return  # the reader will try again when it gets there
		Speech.append_chapter(_speech_items(_make_items(data, index)), book.chapters[index].title)


## The speech service moved on to a chapter that _queue_upcoming() handed over.
func _on_tts_chapter(delta: int) -> void:
	if book.is_empty() or Speech.source_owner != "reader":
		return
	chapter = clampi(chapter + delta, 0, book.chapters.size() - 1)
	await _load_chapter(maxi(Speech.current, 0))
	reveal_speech()
	_queue_upcoming()


func _on_tts_paragraph(index: int) -> void:
	if not is_inside_tree() or Speech.source_owner != "reader" or Speech.items.size() != _items.size():
		return
	_set_highlight(index, Speech.current_sentence())
	if Settings.get_value("tts_follow"):
		if Settings.get_value("tts_mode") == "sentence":
			_follow_sentence()
		else:
			_scroll_to(index, true)
	_update_player()


func _on_tts_end() -> void:
	if book.is_empty() or Speech.source_owner != "reader" or Speech.items.size() != _items.size():
		return  # speech that the reader didn't start
	_set_highlight(-1)
	if Speech.stops_at_chapter_end():
		Speech.set_sleep(0)
		main.toast("Sleep timer: stopped at the end of the chapter.")
		header_changed.emit()
		return
	if Settings.get_value("tts_auto_advance") and chapter < book.chapters.size() - 1:
		_advance_token += 1
		var token := _advance_token
		await get_tree().create_timer(int(Settings.get_value("tts_pause_chapter")) / 1000.0).timeout
		if token == _advance_token and visible:
			go_to_chapter(chapter + 1, true)
	else:
		header_changed.emit()


func _on_tts_sentence(index: int, sentence: int) -> void:
	if not is_inside_tree() or Speech.source_owner != "reader" or Speech.items.size() != _items.size():
		return
	if index == _highlight:
		_set_highlight(index, sentence)
		if Settings.get_value("tts_follow"):
			_follow_sentence()


## Keeps the header's Listen / Stop button in step with playback, however it started or stopped.
func _on_tts_state(_playing: bool) -> void:
	_update_player()
	if Speech.playing != _listen_shown and main.current == self:
		header_changed.emit()


func _set_highlight(i: int, sentence := -1) -> void:
	if Settings.get_value("tts_mode") != "sentence":
		sentence = -1
	if _highlight == i and _highlight_sentence == sentence:
		return
	_highlight = i
	_highlight_sentence = sentence
	_render()


# --- scrolling / progress ----------------------------------------------------

func _scroll_to(paragraph: int, smooth: bool) -> void:
	if paragraph <= 0 or paragraph >= _items.size():
		if not smooth:
			_text.get_v_scroll_bar().value = 0
		return
	# The paragraph starts 28% down the screen, or near the top when it wouldn't fit below that.
	var top := _text.get_paragraph_offset(paragraph)
	var bottom := _text.get_paragraph_offset(paragraph + 1) if paragraph + 1 < _items.size() else float(_text.get_content_height())
	var lead := _text.size.y * 0.28
	if bottom - top > _text.size.y - lead:
		lead = minf(lead, int(Settings.get_value("font_size")))
	var y := top - lead
	var bar := _text.get_v_scroll_bar()
	y = clampf(y, 0, bar.max_value)
	if smooth:
		create_tween().tween_property(bar, "value", y, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		bar.value = y


## Sentence mode: scroll only once part of the sentence being read is off screen, and
## then put it near the top, so scrolls are as rare as possible. When the sentence
## can't be located, the whole paragraph counts. Waits a frame, for the label to lay
## out the re-rendered text.
func _follow_sentence() -> void:
	_follow_token += 1
	var token := _follow_token
	await get_tree().process_frame
	if token != _follow_token or _highlight < 0 or _highlight >= _items.size():
		return
	var it: Dictionary = _items[_highlight]
	var span := _sentence_span(it, _highlight_sentence)
	if span.x < 0:
		span = Vector2i(0, _visible_text(it.bb).length())
	var start := _paragraph_char(_highlight)
	if start < 0:
		return
	if Library.bookmarks(book).any(func(m): return m.chapter == chapter and m.paragraph == _highlight):
		start += 2  # the bookmark icon and the space after it
	if Settings.get_value("first_line_indent") and _indented(it):
		start += 1  # the indent image
	var first := _text.get_character_line(start + span.x)
	var last := _text.get_character_line(start + maxi(span.x, span.y - 1))
	if first < 0 or last < 0:
		return
	var top := _text.get_line_offset(first)
	var bottom := _text.get_line_offset(last) + _text.get_line_height(last)
	var bar := _text.get_v_scroll_bar()
	if top >= bar.value and bottom <= bar.value + _text.size.y:
		return
	var y := clampf(top - int(Settings.get_value("font_size")), 0, bar.max_value)
	create_tween().tween_property(bar, "value", y, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Index in the label's characters of the first one of paragraph `paragraph`, or -1.
func _paragraph_char(paragraph: int) -> int:
	var lo := 0
	var hi := _text.get_total_character_count()
	while lo < hi:
		var mid := (lo + hi) / 2
		if _text.get_character_paragraph(mid) < paragraph:
			lo = mid + 1
		else:
			hi = mid
	return lo if _text.get_character_paragraph(lo) == paragraph else -1


func _first_visible() -> int:
	var y := _text.get_v_scroll_bar().value
	for i in _items.size():
		if _text.get_paragraph_offset(i) >= y - 4:
			return i
	return 0


func _on_scrolled(_v: float) -> void:
	_update_footer()
	if not _restoring:
		_save_timer.start()


func _save_progress() -> void:
	if not book.is_empty() and not _items.is_empty():
		Library.set_progress(book.id, chapter, _first_visible())


func _update_footer() -> void:
	if book.is_empty():
		return
	var n: int = book.chapters.size()
	var bar := _text.get_v_scroll_bar()
	var page_ratio := 0.0
	if bar.max_value - bar.page > 1:
		page_ratio = clampf(bar.value / (bar.max_value - bar.page), 0, 1)
	_footer_label.text = "%d / %d  ·  %d%% of chapter" % [chapter + 1, n, int(page_ratio * 100)]
	_footer_bar.value = (chapter + page_ratio) / max(1, n)


func _update_player() -> void:
	_player.visible = Speech.playing and Speech.source_owner == "reader"
	_play_btn.icon = Icons.get_icon("play" if Speech.paused else "pause", Color("#06121f"), 22)
	_player_label.text = "%s  ·  paragraph %d of %d" % [Speech.voice_name(), Speech.current + 1, max(1, _items.size())]
	var sleeping := Speech.sleep_minutes != 0
	_sleep_btn.text = "" if not sleeping else ("Chapter" if Speech.sleep_minutes == -1 else Speech.sleep_label())
	_sleep_btn.icon = Icons.get_icon("moon", UiTheme.ACCENT if sleeping else UiTheme.MUTED, 18)
	_sleep_btn.tooltip_text = "Sleep timer: " + Speech.sleep_label()
	_rate_btn.text = "%sx" % str(float(Settings.get_value("tts_rate"))).trim_suffix(".0")


# --- view construction -------------------------------------------------------

func _build_read_view() -> void:
	_read_view = UI.vbox(0)
	_read_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_read_view)

	_banner = UI.panel("Banner")
	var brow := UI.hbox(10, [UI.icon("rss", UiTheme.WARN, 18)])
	var bl := UI.label("Preview from the RSS feed. Open the chapter in the Web tab to read or listen to the full text — it's saved to your library as you go.", "Small", true)
	bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bl.add_theme_color_override("font_color", UiTheme.WARN)
	brow.add_child(bl)
	brow.add_child(UI.button("Open in Web tab", "globe", "", func(): main.open_web(book.chapters[chapter].url)))
	_banner.add_child(brow)
	_banner.hide()
	_read_view.add_child(UI.margin(_banner, 24, 14, 24, 0))

	var stack := Control.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_read_view.add_child(stack)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.selection_enabled = true
	_text.context_menu_enabled = true
	_text.scroll_active = true
	_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_text.get_v_scroll_bar().value_changed.connect(_on_scrolled)
	_text.focus_mode = Control.FOCUS_CLICK
	stack.add_child(_text)

	_status = UI.vbox(14)
	_status.alignment = BoxContainer.ALIGNMENT_CENTER
	_status.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_status)

	# Floating TTS player
	_player = UI.panel("PlayerBar")
	_player.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var prow := UI.hbox(8)
	prow.add_child(UI.icon_button("skip_back", "Back a sentence / paragraph", func(): Speech.skip_sentence(-1)))
	_play_btn = Button.new()
	_play_btn.theme_type_variation = "PrimaryButton"
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.custom_minimum_size = Vector2(44, 44)
	_play_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_play_btn.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.ACCENT, 22))
	_play_btn.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.ACCENT.lightened(0.1), 22))
	_play_btn.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.ACCENT.darkened(0.1), 22))
	_play_btn.pressed.connect(Speech.toggle)
	prow.add_child(_play_btn)
	prow.add_child(UI.icon_button("skip_fwd", "Forward a sentence / paragraph", func(): Speech.skip_sentence(1)))
	var info := UI.vbox(0)
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var now := UI.label("Reading aloud", "H3")
	now.add_theme_font_size_override("font_size", 13)
	info.add_child(now)
	_player_label = UI.label("", "Small")
	info.add_child(_player_label)
	_player_info = UI.margin(info, 8, 0, 8, 0)
	prow.add_child(_player_info)
	_rate_btn = UI.button("1x", "", "ChipButton", _cycle_rate)
	_rate_btn.tooltip_text = "Speed"
	_rate_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prow.add_child(_rate_btn)
	_sleep_btn = UI.button("", "moon", "GhostButton", Speech.cycle_sleep, UiTheme.MUTED)
	_sleep_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prow.add_child(_sleep_btn)
	var tts_settings := UI.icon_button("settings", "Voice settings", _show_tts_popup)
	tts_settings.name = "TtsSettingsButton"
	prow.add_child(tts_settings)
	prow.add_child(UI.icon_button("x", "Stop", func(): Speech.stop(); _set_highlight(-1)))
	_player.add_child(prow)
	_player.hide()
	var dock := UI.vbox(0, [UI.spacer(false), _player])
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dock_m := UI.margin(dock, 12, 0, 12, 18)
	dock_m.set_anchors_preset(Control.PRESET_FULL_RECT)
	dock_m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(dock_m)

	# Footer: chapter navigation and progress
	_footer = PanelContainer.new()
	var fs := UiTheme.box(Color.TRANSPARENT, 0, Color.TRANSPARENT, 0, Vector4(16, 6, 16, 8))
	_footer.add_theme_stylebox_override("panel", fs)
	var frow := UI.hbox(12)
	frow.add_child(UI.icon_button("chev_left", "Previous chapter", func(): go_to_chapter(chapter - 1)))
	var mid := UI.vbox(4)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_footer_label = UI.label("", "Small")
	_footer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mid.add_child(_footer_label)
	_footer_bar = UI.progress(0, 3)
	mid.add_child(_footer_bar)
	frow.add_child(mid)
	frow.add_child(UI.icon_button("chev_right", "Next chapter", func(): go_to_chapter(chapter + 1)))
	_footer.add_child(frow)
	_read_view.add_child(_footer)


func _build_contents_view() -> void:
	_contents_list = UI.vbox(2)
	var scroll := UI.scroll(UI.margin(_contents_list, 0, 20, 0, 40))
	_contents_view = UI.margin(scroll, 8 if compact else 24, 0, 8 if compact else 24, 0)
	_contents_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_contents_view.hide()
	add_child(_contents_view)


func set_compact(value: bool) -> void:
	super(value)
	if _contents_view == null:
		return
	# The list scrolls vertically only, so anything wider than the screen
	# pushes the chapter rows (and their download icons) off the right edge.
	var side := 8 if compact else 24
	for v in [_contents_view, _bookmarks_view]:
		v.add_theme_constant_override("margin_left", side)
		v.add_theme_constant_override("margin_right", side)
	_search_view.set_compact(value)
	if _contents_view.visible:
		_build_contents()
	if _bookmarks_view.visible:
		_build_bookmarks()


func _build_contents() -> void:
	UI.clear(_contents_list)
	var head := UI.hbox(10)
	head.add_child(UI.label("%d chapters" % book.chapters.size(), "H2"))
	if book.kind == "web":
		var cached := Library.cached_count(book.id)
		head.add_child(UI.chip("%d downloaded" % cached))
		head.add_child(UI.spacer())
		var check := UI.button("" if compact else "Check for new", "refresh", "", _refresh_book)
		check.tooltip_text = "Check for new chapters"
		head.add_child(check)
	_contents_list.add_child(UI.margin(head, 6 if compact else 12, 0, 6 if compact else 12, 12))
	for i in book.chapters.size():
		var ch: Dictionary = book.chapters[i]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.custom_minimum_size.y = 44
		var current_ch: bool = i == chapter
		var pad := Vector4(14, 10, 14, 10)
		b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.ACCENT_DIM if current_ch else Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, pad))
		b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, pad))
		b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_3, 8, Color.TRANSPARENT, 0, pad))
		b.add_theme_color_override("font_color", UiTheme.TEXT if (current_ch or i > book.progress.chapter or book.last_read == 0) else UiTheme.MUTED)
		b.text = "%d.   %s" % [i + 1, ch.title]
		if book.kind == "web":
			var have := Library.has_chapter(book.id, i)
			b.icon = Icons.get_icon("check" if have else "download", UiTheme.GOOD if have else UiTheme.FAINT, 16)
			b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			b.tooltip_text = "Downloaded" if have else "Not downloaded yet"
		b.pressed.connect(func(): go_to_chapter(i); main.pages.reader.select_tab(0); header_changed.emit())
		_contents_list.add_child(b)


# --- bookmarks ---------------------------------------------------------------

func _build_bookmarks_view() -> void:
	_bookmarks_list = UI.vbox(8)
	var scroll := UI.scroll(UI.margin(_bookmarks_list, 0, 20, 0, 40))
	_bookmarks_view = UI.margin(scroll, 8 if compact else 24, 0, 8 if compact else 24, 0)
	_bookmarks_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bookmarks_view.hide()
	add_child(_bookmarks_view)


func _build_bookmarks() -> void:
	UI.clear(_bookmarks_list)
	var marks := Library.bookmarks(book)
	var how := "Long-press" if OS.has_feature("mobile") else "Right-click"
	var side := 6 if compact else 12
	_bookmarks_list.add_child(UI.margin(UI.label("%d bookmark%s" % [marks.size(), "" if marks.size() == 1 else "s"], "H2"), side, 0, side, 4))
	if marks.is_empty():
		var hint := UI.label("%s a paragraph while reading and choose “Bookmark this paragraph” to add one. You can give each bookmark a name." % how, "Muted", true)
		_bookmarks_list.add_child(UI.margin(hint, side, 0, side, 0))
		return
	_bookmarks_list.add_child(UI.margin(UI.label("%s a paragraph while reading to add more." % how, "Small", true), side, 0, side, 8))
	for m in marks:
		_bookmarks_list.add_child(_bookmark_row(m))


func _bookmark_row(m: Dictionary) -> Control:
	var pad := Vector4(14, 10, 14, 10)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = "Go to this bookmark"
	b.add_theme_stylebox_override("normal", UiTheme.box(Color.TRANSPARENT, 8))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 8))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_3, 8))
	var col := UI.vbox(2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var heading := UI.label(m.name if m.name != "" else "Untitled bookmark", "H3")
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(heading)
	var ch_title: String = book.chapters[m.chapter].title if m.chapter < book.chapters.size() else ""
	var where := UI.label("Chapter %d%s" % [m.chapter + 1, (" · " + ch_title) if ch_title != "" else ""], "Small")
	where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	where.add_theme_color_override("font_color", UiTheme.ACCENT)
	col.add_child(where)
	if m.text != "":
		var ex := UI.label("“%s”" % m.text, "Small")
		ex.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(ex)
	for l in col.get_children():
		l.clip_text = true  # long names and quotes mustn't widen the list
		l.custom_minimum_size.x = 1
	var inner := UI.margin(col, int(pad.x), int(pad.y), int(pad.z), int(pad.w))
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.add_child(inner)
	var fit := func(): b.custom_minimum_size.y = inner.get_combined_minimum_size().y
	inner.minimum_size_changed.connect(fit)
	fit.call_deferred()
	b.pressed.connect(func(): go_to_bookmark(m))
	var row := UI.hbox(4, [b])
	var edit := UI.icon_button("pencil", "Rename", func(): _rename_bookmark(m))
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(edit)
	var del := UI.icon_button("trash", "Remove bookmark", func():
		Library.remove_bookmark(book.id, m.id)
		_after_bookmarks_changed()
		main.toast("Bookmark removed.", "info"))
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(del)
	return row


func go_to_bookmark(m: Dictionary) -> void:
	if m.chapter >= book.chapters.size():
		return
	select_tab(0)
	header_changed.emit()
	if m.chapter == chapter and not _items.is_empty():
		await get_tree().process_frame
		_scroll_to(m.paragraph, false)
		Library.set_progress(book.id, chapter, m.paragraph)
		return
	Speech.stop()
	chapter = m.chapter
	header_changed.emit()
	await _load_chapter(m.paragraph)


## Opens the dialog to add a bookmark at paragraph i of this chapter, or to rename
## or remove the one that's there.
func _edit_bookmark(i: int) -> void:
	if i < 0 or i >= _items.size():
		return
	var existing := Library.bookmark_at(book, chapter, i)
	var excerpt := _paragraph_excerpt(i)
	var opts := {
		"title": "Edit bookmark" if not existing.is_empty() else "Add bookmark", "icon": "bookmark",
		"text": "Chapter %d · “%s”" % [chapter + 1, excerpt.left(140) + ("…" if excerpt.length() > 140 else "")],
		"input": existing.get("name", ""), "input_hint": "Name (optional)",
		"confirm": "Save", "confirm_icon": "check",
	}
	var id: String = book.id
	var at := chapter
	if not existing.is_empty():
		var remove := func():
			Library.remove_bookmark(id, existing.id)
			_after_bookmarks_changed()
			main.toast("Bookmark removed.", "info")
		opts.merge({"alt": "Remove", "alt_icon": "trash", "alt_then": remove})
	var save := func(typed: String):
		if book.get("id", "") != id:
			return
		if existing.is_empty():
			Library.add_bookmark(id, at, i, typed, excerpt.left(200))
			main.toast("Bookmark added.", "ok")
		else:
			Library.rename_bookmark(id, existing.id, typed)
		_after_bookmarks_changed()
	ConfirmDialog.open(main, opts, save)


func _rename_bookmark(m: Dictionary) -> void:
	ConfirmDialog.open(main, {
		"title": "Rename bookmark", "icon": "pencil", "text": "“%s”" % m.text.left(140) if m.text != "" else "",
		"input": m.name, "input_hint": "Name (optional)", "confirm": "Save", "confirm_icon": "check",
	}, func(typed: String):
		Library.rename_bookmark(book.id, m.id, typed)
		_after_bookmarks_changed())


func _after_bookmarks_changed() -> void:
	book = Library.get_book(book.id)
	_render()
	if _bookmarks_view.visible:
		_build_bookmarks()


## The shown text of paragraph i, on one line.
func _paragraph_excerpt(i: int) -> String:
	var t := _visible_text(_items[i].bb).replace("\n", " ").strip_edges()
	return RegEx.create_from_string("\\s+").sub(t, " ", true)


func _build_details() -> void:
	UI.clear(_details_view)
	var row := UI.hbox(32) if not compact else UI.vbox(20)
	var cover := CoverView.new()
	cover.radius = 12
	cover.custom_minimum_size = Vector2(200, 300) if not compact else Vector2(140, 210)
	cover.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cover.set_book(book)
	row.add_child(cover)
	var col := UI.vbox(10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t := UI.label(book.title, "H1", true)
	t.add_theme_font_override("font", UiTheme.serif_bold)
	t.add_theme_font_size_override("font_size", 30)
	col.add_child(t)
	if book.author != "":
		col.add_child(UI.label("by " + book.author, "Muted"))
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	chips.add_child(UI.chip(BookCard._badge_text(book), UiTheme.ACCENT))
	chips.add_child(UI.chip(BookCard._source_name(book)))
	for tag in book.get("tags", []):
		var tb := UI.button(tag, "", "ChipButton", func(): main.pages.library.show_tag(tag), UiTheme.MUTED)
		tb.tooltip_text = "Show the books tagged “%s”" % tag
		chips.add_child(tb)
	col.add_child(UI.margin(chips, 0, 4, 0, 8))
	var stats := HFlowContainer.new()  # wraps on narrow (phone) screens
	stats.add_theme_constant_override("h_separation", 28)
	stats.add_theme_constant_override("v_separation", 14)
	stats.add_child(_stat("Chapters", str(book.chapters.size())))
	stats.add_child(_stat("Progress", "%d%%" % int(Library.progress_ratio(book) * 100)))
	stats.add_child(_stat("Last read", UI.relative_time(book.last_read)))
	if book.kind == "web":
		stats.add_child(_stat("Downloaded", str(Library.cached_count(book.id))))
	var words := Library.saved_words(book)
	var total := int(book.get("total_words", 0))
	if words.chapters > 0 or total > 0:
		var w := _stat("Words", _short_count(words.words) + (" / " + _short_count(total) if total > 0 else ""))
		w.tooltip_text = "%s words in %d saved chapter(s)%s" % [_grouped(words.words), words.chapters,
			", %s in the whole book (from the site)" % _grouped(total) if total > 0 else ""]
		stats.add_child(w)
	col.add_child(stats)
	if book.synopsis != "":
		col.add_child(UI.margin(UI.label("About", "H3"), 0, 14, 0, 0))
		var syn := UI.label(book.synopsis, "", true)
		syn.add_theme_color_override("font_color", UiTheme.MUTED)
		syn.add_theme_constant_override("line_spacing", 4)
		col.add_child(syn)
	var buttons := HFlowContainer.new()  # wraps on narrow (phone) screens
	buttons.add_theme_constant_override("h_separation", 10)
	buttons.add_theme_constant_override("v_separation", 10)
	buttons.add_child(UI.button("Read", "book", "PrimaryButton", func(): main.pages.reader.select_tab(0); header_changed.emit()))
	if Library.is_file_book(book):
		var edit := UI.button("Edit details", "pencil", "", _edit_details)
		edit.tooltip_text = "Change the title, author, tags and description"
		buttons.add_child(edit)
	var change := UI.button("Change cover", "image", "", _pick_cover)
	change.tooltip_text = "Use an image file (PNG, JPEG or WebP) as this book's cover"
	buttons.add_child(change)
	if book.url != "":
		buttons.add_child(UI.button("Open website", "external", "", func(): OS.shell_open(book.url)))
	if book.kind == "web":
		var fill := UI.button("Add chapters from EPUB", "import", "", _pick_epub)
		fill.tooltip_text = "Fill in chapters that aren't downloaded from an EPUB of this book, e.g. one saved with WebToEpub"
		buttons.add_child(fill)
	elif Library.is_file_book(book):
		var more := UI.button("Add chapters from EPUB", "import", "", _pick_epub)
		more.tooltip_text = "Add the new chapters of a later EPUB of this book to its end, e.g. the latest chapters of a serial. Chapters it already has are skipped."
		buttons.add_child(more)
	var del := UI.button("Delete book", "trash", "GhostButton", _confirm_delete, UiTheme.BAD)
	del.add_theme_color_override("font_color", UiTheme.BAD)
	del.tooltip_text = "Remove this book and its downloaded chapters from the library"
	buttons.add_child(del)
	col.add_child(UI.margin(buttons, 0, 16, 0, 0))
	row.add_child(col)
	var m := UI.margin(row, 40 if not compact else 20, 32, 40 if not compact else 20, 40)
	var s := UI.scroll(m)
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	_details_view.add_child(s)


func _pick_epub() -> void:
	if _epub_dialog == null:
		_epub_dialog = FileDialog.new()
		_epub_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_epub_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_epub_dialog.use_native_dialog = true
		_epub_dialog.filters = PackedStringArray(["*.epub ; EPUB ebooks"])
		_epub_dialog.file_selected.connect(func(path):
			if book.get("kind", "") == "web":
				_fill_from_epub(path)
			else:
				_append_from_file(path))
		add_child(_epub_dialog)
	_epub_dialog.popup_centered_ratio(0.6)


func _pick_cover() -> void:
	if _cover_dialog == null:
		_cover_dialog = FileDialog.new()
		_cover_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_cover_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_cover_dialog.use_native_dialog = true
		_cover_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
		_cover_dialog.file_selected.connect(_set_cover)
		add_child(_cover_dialog)
	_cover_dialog.popup_centered_ratio(0.6)


func _edit_details() -> void:
	var id: String = book.id
	BookEditor.open(main, id, func():
		main.toast("Details saved", "ok")
		if book.get("id", "") == id:
			book = Library.get_book(id)
			_build_details()
			header_changed.emit())


func _confirm_delete() -> void:
	var id: String = book.id
	ConfirmDialog.open(main, {
		"title": "Delete “%s”?" % book.title,
		"text": "This removes the book, its downloaded chapters, reading progress and bookmarks from the library, here and on your synced devices.",
		"icon": "trash", "confirm": "Delete", "confirm_icon": "trash", "danger": true,
	}, func():
		var b := Library.get_book(id)
		if b.is_empty():
			return
		if book.get("id", "") == id:
			if Speech.source_owner == "reader":
				Speech.stop()
			book = {}
			_items = []
			main.navigate("library")
		Library.remove_book(id)
		main.toast("Deleted “%s”" % b.title))


func _set_cover(path: String) -> void:
	var id: String = book.id
	# read the bytes: works for Android's content:// URIs too
	var err := Library.set_cover_from_bytes(id, FileAccess.get_file_as_bytes(path))
	if err != "":
		main.toast(err, "error")
		return
	main.toast("Cover changed", "ok")
	if book.get("id", "") == id:
		book = Library.get_book(id)
		_build_details()


## Adds the chapters of a later EPUB of an imported book (the next chapters of a
## serial) to its end. Asks first when the EPUB's title doesn't look like this book's.
func _append_from_file(path: String) -> void:
	var id: String = book.id
	var parsed := Library.read_file(path)
	if parsed.has("error"):
		main.toast(parsed.error, "error")
		return
	var fresh := Library.new_chapters_for(id, parsed)
	if fresh.is_empty():
		main.toast("This book already has all of the EPUB's chapters", "warn")
		return
	if not Library.same_series(book, parsed):
		ConfirmDialog.open(main, {
			"title": "Add chapters from a different book?",
			"text": "The EPUB is “%s”%s, not “%s”. Add its %d chapter(s) to the end of this book anyway?" % [
				parsed.title, " by " + parsed.author if parsed.get("author", "") != "" else "", book.title, fresh.size()],
			"icon": "import", "confirm": "Add chapters", "confirm_icon": "import",
		}, func(): _append_chapters(id, parsed, fresh))
		return
	_append_chapters(id, parsed, fresh)


func _append_chapters(id: String, parsed: Dictionary, fresh: Array) -> void:
	if Library.get_book(id).is_empty():
		return
	var skipped: int = parsed.chapters.size() - fresh.size()
	Library.append_chapters(id, parsed, fresh)
	main.toast("Added %d chapter(s)%s" % [fresh.size(), " (%d were already in it)" % skipped if skipped > 0 else ""], "ok")
	if book.get("id", "") == id:
		book = Library.get_book(id)
		_build_details()


## Checks the site for new chapters first, so chapters the EPUB has that the
## chapter list doesn't yet can be filled too (if the site can't be reached, the
## chapters already listed are still filled).
func _fill_from_epub(path: String) -> void:
	var id: String = book.id
	var epub := Library.read_epub_for(id, path)
	if epub.has("error"):
		main.toast(epub.error, "error")
		return
	main.toast("Adding chapters from the EPUB…")
	await Sources.refresh(Library.get_book(id))
	if Library.get_book(id).is_empty():
		return
	var r := Library.fill_from_epub(id, epub)
	if book.get("id", "") == id:
		book = Library.get_book(id)
		_build_details()
	if r.matched == 0:
		main.toast("None of the EPUB's chapters are in this book", "warn")
	elif r.filled == 0:
		main.toast("All %d chapter(s) the EPUB has are already downloaded" % r.matched, "ok")
	else:
		main.toast("Added %d chapter(s) from the EPUB" % r.filled, "ok")


## 950, 8.4k, 84k, 1.2M
static func _short_count(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 10000:
		return ("%.1fk" % (n / 1000.0)).replace(".0k", "k")
	if n < 1000000:
		return "%dk" % roundi(n / 1000.0)
	return ("%.1fM" % (n / 1000000.0)).replace(".0M", "M")


## 1234567 -> "1,234,567"
static func _grouped(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


func _stat(label: String, value: String) -> Control:
	var v := UI.vbox(2)
	v.add_child(UI.label(label.to_upper(), "Overline"))
	var l := UI.label(value, "H2")
	v.add_child(l)
	return v


func _build_aa_popup() -> void:
	pass


func _aa_content() -> Control:
	var col := UI.vbox(14)
	col.custom_minimum_size.x = 300
	col.add_child(UI.label("Theme", "Overline"))
	var themes := UI.hbox(8)
	for key in ["dark", "sepia", "light"]:
		var c: Dictionary = Settings.READER_THEMES[key]
		var b := Button.new()
		b.text = key.capitalize()
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 40
		b.add_theme_stylebox_override("normal", UiTheme.box(c.bg, 8, UiTheme.BORDER, 1))
		b.add_theme_stylebox_override("hover", UiTheme.box(c.bg, 8, UiTheme.MUTED, 1))
		b.add_theme_stylebox_override("pressed", UiTheme.box(c.bg, 8, UiTheme.ACCENT, 2))
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, c.text)
		b.pressed.connect(func(): Settings.set_value("reader_theme", key))
		b.set_meta("theme_key", key)
		themes.add_child(b)
	col.add_child(themes)
	col.add_child(UI.label("Font", "Overline"))
	var fonts := UI.hbox(8)
	for f in [["serif", "Literata"], ["sans", "Inter"]]:
		var b := UI.button(f[1], "", "ChipButton", func(): Settings.set_value("reader_font", f[0]))
		b.add_theme_font_override("font", UiTheme.serif if f[0] == "serif" else UiTheme.sans)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fonts.add_child(b)
	col.add_child(fonts)
	col.add_child(_stepper("Text size", "font_size", 14, 34, 1))
	col.add_child(UI.label("Alignment", "Overline"))
	col.add_child(SettingsPage.segmented_row("text_align", ALIGN_OPTIONS))
	col.add_child(_stepper("Line spacing", "line_spacing", 0, 20, 2))
	col.add_child(_stepper("Paragraph spacing", "paragraph_gap", 0, 60, 2))
	col.add_child(_stepper("Text width", "column_width", 360, 1600, 40))
	col.add_child(_stepper("Side margins", "side_margin", 0, 160, 4))
	var indent := CheckButton.new()
	indent.text = "Indent first line"
	indent.focus_mode = Control.FOCUS_NONE
	indent.button_pressed = bool(Settings.get_value("first_line_indent"))
	indent.toggled.connect(func(v): Settings.set_value("first_line_indent", v))
	col.add_child(indent)
	var rules_btn := UI.button("Text & speech rules", "replace", "", func():
		close_aa()
		main.pages.settings.tab = 2
		main.navigate("settings"))
	rules_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(rules_btn)
	return col


const ALIGN_OPTIONS := [["left", "Left"], ["justify", "Justified"], ["center", "Centred"]]


func _stepper(label: String, key: String, lo: int, hi: int, step: int) -> Control:
	var row := UI.hbox(8)
	var l := UI.label(label, "Muted")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var value := UI.label(str(int(Settings.get_value(key))), "H3")
	value.custom_minimum_size.x = 44
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var minus := UI.icon_button("chev_left", "Less", func():
		Settings.set_value(key, clampi(int(Settings.get_value(key)) - step, lo, hi)); value.text = str(int(Settings.get_value(key))))
	var plus := UI.icon_button("chev_right", "More", func():
		Settings.set_value(key, clampi(int(Settings.get_value(key)) + step, lo, hi)); value.text = str(int(Settings.get_value(key))))
	row.add_child(minus)
	row.add_child(value)
	row.add_child(plus)
	return row


var _aa_node: Popover


func _show_aa() -> void:
	var btn: Control = main.find_child("AaButton", true, false)
	_aa_node = Popover.show_for(btn, _aa_content())


func close_aa() -> void:
	if is_instance_valid(_aa_node):
		_aa_node.close()


# --- style -------------------------------------------------------------------

func _on_setting(key: String) -> void:
	if key in ["reader_theme", "reader_font", "font_size", "line_spacing", "paragraph_gap", "column_width", "side_margin", "text_align", "first_line_indent"]:
		_apply_style()
		if not _items.is_empty():
			_render()
	elif key in ["tts_highlight", "tts_mode"]:
		if not _items.is_empty():
			_render()
	elif key == "tts_rate":
		_update_player()


func _apply_style() -> void:
	var c := Settings.reader_colors()
	_bg.color = c.bg
	var serif: bool = Settings.get_value("reader_font") == "serif"
	var size := int(Settings.get_value("font_size"))
	_text.add_theme_font_override("normal_font", UiTheme.serif if serif else UiTheme.sans)
	_text.add_theme_font_override("bold_font", UiTheme.serif_bold if serif else UiTheme.sans_bold)
	_text.add_theme_font_override("italics_font", UiTheme.serif_italic if serif else UiTheme.sans)
	_text.add_theme_font_override("bold_italics_font", UiTheme.serif_bold if serif else UiTheme.sans_bold)
	for k in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		_text.add_theme_font_size_override(k, size)
	_text.add_theme_color_override("default_color", c.text)
	_text.add_theme_color_override("selection_color", Color(UiTheme.ACCENT, 0.3))
	_text.add_theme_constant_override("line_separation", int(Settings.get_value("line_spacing")) + int(size * 0.2))
	_text.add_theme_constant_override("paragraph_separation", int(Settings.get_value("paragraph_gap")))
	_text.horizontal_alignment = text_alignment()
	_text.add_theme_constant_override("text_highlight_h_padding", 6)
	_text.add_theme_constant_override("text_highlight_v_padding", 3)
	var dark: bool = c.bg.get_luminance() < 0.5
	var sb := _text.get_v_scroll_bar()
	sb.add_theme_stylebox_override("grabber", UiTheme.box(Color(1, 1, 1, 0.10) if dark else Color(0, 0, 0, 0.14), 4))
	_footer_label.add_theme_color_override("font_color", c.muted)
	_set_status_colors(c)
	_apply_layout()


## The reader's text alignment setting as a HorizontalAlignment.
static func text_alignment() -> HorizontalAlignment:
	match str(Settings.get_value("text_align")):
		"justify": return HORIZONTAL_ALIGNMENT_FILL
		"center": return HORIZONTAL_ALIGNMENT_CENTER
	return HORIZONTAL_ALIGNMENT_LEFT


func _set_status_colors(c: Dictionary) -> void:
	for l in _status.get_children():
		if l is Label:
			l.add_theme_color_override("font_color", c.muted)


func _apply_layout() -> void:
	if _text == null:
		return
	var col := float(Settings.get_value("column_width"))
	var w := _text.size.x
	var side := maxf(float(Settings.get_value("side_margin")), (w - col) / 2.0)
	var style := StyleBoxEmpty.new()
	style.content_margin_left = side
	style.content_margin_right = side
	style.content_margin_top = 36 if not compact else 20
	style.content_margin_bottom = 120
	_text.add_theme_stylebox_override("normal", style)
	_text.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_player.custom_minimum_size.x = 0 if compact else 520
	_player_info.visible = not compact


# --- quick voice settings (player bar) ---------------------------------------

func _build_tts_popup() -> void:
	pass


func _tts_content() -> Control:
	var col := UI.vbox(12)
	col.custom_minimum_size.x = 340
	col.add_child(UI.label("Reading aloud", "H3"))
	col.add_child(SettingsPage.slider_row("Speed", "tts_rate", 0.5, 3.0, 0.05, "%.2fx", 140))
	col.add_child(SettingsPage.slider_row("Pitch", "tts_pitch", 0.5, 1.5, 0.05, "%.2f", 140))
	col.add_child(SettingsPage.slider_row("Paragraph pause", "tts_pause_paragraph", 0, 3000, 50, "%d ms", 140))
	col.add_child(SettingsPage.slider_row("Heading pause", "tts_pause_heading", 0, 4000, 50, "%d ms", 140))
	col.add_child(SettingsPage.slider_row("Sentence pause", "tts_pause_sentence", 0, 2000, 25, "%d ms", 140))
	col.add_child(SettingsPage.segmented_row("tts_mode", [["paragraph", "Paragraphs"], ["sentence", "Sentences"]]))
	col.add_child(UI.label("Sentence pauses apply in Sentences mode. Changes apply from the next sentence.", "Small", true))
	col.add_child(UI.button("All voice settings", "settings", "", func():
		if _tts_popup_node: _tts_popup_node.close()
		main.pages.settings.tab = 1
		main.navigate("settings")))
	return col


var _tts_popup_node: Popover


func _show_tts_popup() -> void:
	var btn: Control = find_child("TtsSettingsButton", true, false)
	_tts_popup_node = Popover.show_for(btn if btn else _player, _tts_content(), true)


func close_tts_popup() -> void:
	if is_instance_valid(_tts_popup_node):
		_tts_popup_node.close()


# --- create rules from selected text -----------------------------------------

func _setup_context_menu() -> void:
	var menu := _text.get_menu()
	menu.add_separator()
	menu.add_item("Fix pronunciation of selection…", MENU_FIX_SPEECH)
	menu.add_item("Don't read selection aloud…", MENU_SKIP_SPEECH)
	menu.add_item("Replace selection in text…", MENU_REPLACE_TEXT)
	menu.add_separator()
	menu.add_item("Bookmark this paragraph…", MENU_BOOKMARK)
	menu.id_pressed.connect(_on_menu_item)
	menu.about_to_popup.connect(func():
		var has := _text.get_selected_text().strip_edges() != ""
		for id in [MENU_FIX_SPEECH, MENU_SKIP_SPEECH, MENU_REPLACE_TEXT]:
			menu.set_item_disabled(menu.get_item_index(id), not has)
		var bi := menu.get_item_index(MENU_BOOKMARK)
		menu.set_item_disabled(bi, _menu_paragraph < 0)
		var marked := _menu_paragraph >= 0 and not Library.bookmark_at(book, chapter, _menu_paragraph).is_empty()
		menu.set_item_text(bi, "Edit bookmark…" if marked else "Bookmark this paragraph…"))
	_text.gui_input.connect(_on_text_input)
	_press_timer = Timer.new()
	_press_timer.one_shot = true
	_press_timer.wait_time = 0.6
	_press_timer.timeout.connect(func():
		var i := _paragraph_at(_press_at)
		if i >= 0 and _text.get_selected_text() == "":
			_edit_bookmark(i))
	add_child(_press_timer)


## Notes the paragraph under a right-click (for the menu) and opens the bookmark
## dialog on a long press on touch screens, where there is no right-click.
func _on_text_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		_menu_paragraph = _paragraph_at(e.position)
	elif e is InputEventScreenTouch:
		_press_at = e.position
		if e.pressed and not e.double_tap:
			_press_timer.start()
		else:
			_press_timer.stop()
	elif e is InputEventScreenDrag and e.position.distance_to(_press_at) > 12:
		_press_timer.stop()


## The paragraph at a point in the text view, or -1.
func _paragraph_at(pos: Vector2) -> int:
	if _items.is_empty():
		return -1
	var y := pos.y - _text.get_theme_stylebox("normal").content_margin_top + _text.get_v_scroll_bar().value
	var found := 0
	for i in _items.size():
		if _text.get_paragraph_offset(i) > y:
			break
		found = i
	return found


func _on_menu_item(id: int) -> void:
	if id == MENU_BOOKMARK:
		if _menu_paragraph >= 0:
			_edit_bookmark(_menu_paragraph)
		return
	var sel := _text.get_selected_text().strip_edges()
	if sel == "" or id < MENU_FIX_SPEECH:
		return
	var context := _paragraph_containing(sel)
	match id:
		MENU_FIX_SPEECH:
			open_rule_editor({"pattern": sel, "replace": sel, "scope": "tts", "whole_word": true, "book": book.id}, context)
		MENU_SKIP_SPEECH:
			open_rule_editor({"pattern": sel, "replace": " ", "scope": "tts", "book": book.id}, context)
		MENU_REPLACE_TEXT:
			open_rule_editor({"pattern": sel, "replace": "", "scope": "display", "book": book.id}, context)


func open_rule_editor(rule: Dictionary, sample := "") -> RuleEditor:
	return RuleEditor.open(main, rule, book.get("id", ""), sample)


func _paragraph_containing(text: String) -> String:
	for p in _data.get("paragraphs", []):
		var plain := HtmlText.plain(p)
		if plain.find(text) != -1:
			return plain
	return text


func _cycle_rate() -> void:
	var r := float(Settings.get_value("tts_rate"))
	var i := RATES.find(r)
	Settings.set_value("tts_rate", RATES[(i + 1) % RATES.size()])
	if Speech.playing:
		Speech.skip(0)  # restart the current paragraph at the new speed


func _refresh_book() -> void:
	main.toast("Checking for new chapters…")
	var r := await Sources.refresh(book)
	book = Library.get_book(book.id)
	main.toast(r.error if r.error != "" else "%d new chapter(s)" % r.new, "error" if r.error != "" else "ok")
	_build_contents()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F and event.is_command_or_control_pressed():
		select_tab(SEARCH_TAB)
		header_changed.emit()
		get_viewport().set_input_as_handled()
		return
	if not visible or tab != 0 or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			if Speech.playing: Speech.toggle()
			else: start_tts()
		KEY_RIGHT: go_to_chapter(chapter + 1)
		KEY_LEFT: go_to_chapter(chapter - 1)
		_: return
	get_viewport().set_input_as_handled()


static func _esc(s: String) -> String:
	return s.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")
