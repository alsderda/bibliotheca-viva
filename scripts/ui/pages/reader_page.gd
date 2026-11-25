class_name ReaderPage
extends Page
## Reader with Read / Contents / Details / Bookmarks tabs, display settings and a TTS player.

const RATES := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

var book := {}
var chapter := 0
var tts: ReaderTts               # reading-aloud control; the page keeps the view
var _items: Array = []           # [{kind, bb, tts}] one per RichTextLabel paragraph
var _data := {}                  # raw chapter data, kept so rules can be re-applied
var _load_token := 0
var _loading := false            # a chapter load is in flight
var _bb_cache := PackedStringArray()  # finished plain BBCode per item, exactly what the main label shows
var _hl_queued := false         # an overlay re-line-up is waiting for the end of the frame
var _hl_clip: Control           # clips the overlay to the lines the text itself draws
var _hl_label: RichTextLabel  # draws the highlighted paragraph over the main label, so the chapter text is never re-parsed for a highlight
var _big := {}                   # item indexes rendered title-size (first title/heading)
var _listen_shown := false       # whether the header's Listen button currently shows "Stop"
var _excerpt := false
var _restoring := false
var _save_timer: Timer
var _scroll_tween: Tween        # the follow scroll in flight, so a new one can replace it
var _scroll_target := 0.0       # where that scroll ends

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
var _player_row: HBoxContainer
var _player_dock: MarginContainer
var _player_edge := false  # true while the player is a full-width strip (screen too thin to float it)
var _rate_btn: Button
var _contents_view: Control
var _contents_list: VBoxContainer
var _open_groups := {}  # start index -> true for each expanded Contents group
var _contents_book := "" # book id `_open_groups` belongs to
var _details_view: Control
var bookmarks: ReaderBookmarks
var _menu_paragraph := -1        # paragraph the context menu was opened on
var _press_timer: Timer          # long-press on a paragraph (touch screens)
var _press_at := Vector2.ZERO
var _tap := false                # the current touch is still a plain tap
var _press_scroll := 0.0         # scroll position when the current touch began
var _read_stack: Control         # the text and the floating bars live here
var _sel_bar: SelectionBar       # touch selection pop-up over the text
var _sel_paragraph := -1         # paragraph the selection bar was opened on
var _sel_popup: PopupMenu        # the bar's "More" menu, if open
var _sleep_btn: Button
var _rail_play_btn: Button
var _rail_more_btn: Button
var _rail_info_label: Label
var _rail_rate_btn: Button
var _rail_sleep_btn: Button
var _rail_more_popover: Popover
var _epub_dialog: FileDialog
var _cover_dialog: FileDialog
var _search_view: SearchView
var _find := {}                  # search match marked on the Read tab: {paragraph, from, to}

const SEARCH_TAB := 2
const DETAILS_TAB := 3

const MENU_FIX_SPEECH := 100
const MENU_SKIP_SPEECH := 101
const MENU_REPLACE_TEXT := 102
const MENU_BOOKMARK := 103

const SEL_COPY := 200
const SEL_BOOKMARK := 201
const SEL_MORE := 202
const SEL_COPY_PARA := 203

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
	bookmarks = ReaderBookmarks.new(self)
	bookmarks.build_view()
	_build_aa_popup()

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.8
	_save_timer.timeout.connect(_save_progress)
	add_child(_save_timer)

	Settings.changed.connect(_on_setting)
	tts = ReaderTts.new(self)
	tts.connect_signals()
	Speech.sleep_changed.connect(_update_player)
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


func tab_icons() -> PackedStringArray:
	return ["book", "list", "search", "info", "bookmark"]


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
	if not _rail_tts_active():
		var listen := UI.button("" if compact else ("Stop" if Speech.playing else "Listen"), "stop" if Speech.playing else "headphones",
			"" if Speech.playing else "PrimaryButton", toggle_tts)
		listen.tooltip_text = "Read aloud (Space)"
		bar.add_child(listen)


func _on_tab(i: int) -> void:
	_hide_selection_bar()
	_read_view.visible = i == 0
	_bg.visible = i == 0
	_contents_view.visible = i == 1
	_search_view.visible = i == SEARCH_TAB
	_details_view.visible = i == DETAILS_TAB
	bookmarks.view.visible = i == BOOKMARKS_TAB
	if i == 1:
		_build_contents()
	elif i == SEARCH_TAB:
		_search_view.refresh()
	elif i == DETAILS_TAB:
		_build_details()
	elif i == BOOKMARKS_TAB:
		bookmarks.build()


func on_hidden() -> void:
	_save_progress()
	if is_instance_valid(_rail_more_popover):
		_rail_more_popover.close()


func on_shown() -> void:
	_update_player()


func build_rail_extras(box: VBoxContainer) -> void:
	_rail_play_btn = null
	_rail_more_btn = null
	_rail_info_label = null
	_rail_rate_btn = null
	_rail_sleep_btn = null
	if not _rail_tts_active():
		if is_instance_valid(_rail_more_popover):
			_rail_more_popover.close()
		return
	box.add_child(main.rail_button("skip_back", "Back a sentence / paragraph", func(): Speech.skip_sentence(-1)))
	_rail_play_btn = _make_rail_play_button()
	box.add_child(_rail_play_btn)
	box.add_child(main.rail_button("skip_fwd", "Forward a sentence / paragraph", func(): Speech.skip_sentence(1)))
	_rail_more_btn = main.rail_button("more", "More reading controls", _show_rail_more)
	box.add_child(_rail_more_btn)


func _make_rail_play_button() -> Button:
	var b := Button.new()
	b.theme_type_variation = "PrimaryButton"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(44, 44)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.icon = Icons.get_icon("play" if Speech.paused else "pause", Color("#06121f"), 22)
	b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.ACCENT, 22))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.ACCENT.lightened(0.1), 22))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.ACCENT.darkened(0.1), 22))
	b.pressed.connect(Speech.toggle)
	return b


func _rail_tts_active() -> bool:
	return Speech.playing and Speech.source_owner == "reader" and tab == 0 \
		and main != null and main.current == self and main.rail_active()


func _show_rail_more() -> void:
	if is_instance_valid(_rail_more_popover):
		_rail_more_popover.close()
	var content := UI.vbox(10)
	content.custom_minimum_size.x = 260
	_rail_info_label = UI.label("", "Small")
	_rail_info_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	content.add_child(_rail_info_label)
	_rail_rate_btn = UI.button("", "", "ChipButton", _cycle_rate)
	_rail_rate_btn.tooltip_text = "Speed"
	_rail_rate_btn.custom_minimum_size.y = 40
	_rail_sleep_btn = UI.button("", "moon", "GhostButton", func(): Speech.cycle_sleep(); _update_player(), UiTheme.MUTED)
	_rail_sleep_btn.custom_minimum_size.y = 40
	content.add_child(UI.hbox(8, [_rail_rate_btn, _rail_sleep_btn]))
	var voice: Button
	voice = UI.button("Voice settings", "settings", "", func(): _show_tts_popup(voice))
	voice.custom_minimum_size.y = 40
	var stop := UI.button("Stop", "x", "", func(): Speech.stop(); tts.clear_highlight())
	stop.custom_minimum_size.y = 40
	content.add_child(UI.hbox(8, [voice, stop]))
	_rail_more_popover = Popover.show_for(_rail_more_btn, content)
	_update_player()


## Scroll to the paragraph being read aloud (used when jumping back from the sidebar).
func reveal_speech() -> void:
	tts.reveal()


# --- loading -----------------------------------------------------------------

func open_book(id: String, ch := -1) -> void:
	if Speech.playing and (book.get("id", "") != id or Speech.source_owner != "reader"):
		Speech.stop()
	book = Library.get_book(id)
	if book.is_empty():
		return
	tts.bump_advance()
	Library.set_dropped(id, false)  # opening a dropped book picks it up again
	chapter = clampi(ch if ch >= 0 else book.progress.chapter, 0, max(0, book.chapters.size() - 1))
	var para: int = book.progress.paragraph if ch < 0 else 0
	select_tab(0)
	await _load_chapter(para)


func go_to_chapter(index: int, start_tts := false) -> void:
	if index < 0 or index >= book.chapters.size():
		return
	tts.bump_advance()
	var was_playing := Speech.playing
	Speech.stop()
	chapter = index
	header_changed.emit()
	var id: String = book.get("id", "")
	await _load_chapter(0)
	if book.get("id", "") != id or chapter != index:
		return
	Library.set_progress(book.id, chapter, 0)
	if start_tts or was_playing:
		start_tts(0)


func _load_chapter(paragraph: int) -> void:
	_hide_selection_bar()
	_load_token += 1
	var token := _load_token
	_loading = true
	tts.clear_silent()
	_find = {}
	_items.clear()  # so nothing re-renders the previous chapter while this one loads or fails
	_data = {}
	_text.text = ""
	_show_highlight()  # the old highlight must not linger over the loading text
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
		_loading = false
		return
	_set_status("")
	_excerpt = data.get("excerpt", false)
	_banner.visible = _excerpt
	_data = data
	_items = _make_items(data, chapter)
	_render()
	await get_tree().process_frame
	if token != _load_token:
		return
	_restoring = true
	_scroll_to(paragraph, false)
	_restoring = false
	Library.set_progress(book.id, chapter, paragraph)
	_loading = false
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


## Everything a finished paragraph depends on besides the items and the highlight.
func _render_ctx() -> Dictionary:
	var size := int(Settings.get_value("font_size"))
	var colors := Settings.reader_colors()
	var marked := {}
	for m in Library.bookmarks(book):
		if m.chapter == chapter:
			marked[m.paragraph] = true
	return {
		"colors": colors, "size": size, "hl": colors.highlight.to_html(),
		"marked": marked, "marker": _marker_bbcode(size) if not marked.is_empty() else "",
		"indent": indent_bbcode(size) if Settings.get_value("first_line_indent") else "",
	}


## The finished BBCode of item `i`: search mark, indent, bookmark icon, title
## sizing, and the highlight when `with_hl`. Pure in the items, the context and
## the highlight state. The main label always uses the plain form; only the
## highlight overlay uses the highlighted form.
func _item_bbcode(i: int, ctx: Dictionary, with_hl: bool) -> String:
	var it: Dictionary = _items[i]
	var bb: String = it.bb
	if with_hl and i == tts.highlight:
		bb = _highlighted(it, String(ctx.hl), ctx.colors)
	elif i == _find.get("paragraph", -1):
		bb = _mark_span(bb, _find.from, _find.to, "[bgcolor=%s]" % Color(UiTheme.WARN, 0.4).to_html(), "[/bgcolor]")
	var indent: String = ctx.indent
	if indent != "" and _indented(it):
		bb = indent + bb
	if (ctx.marked as Dictionary).has(i):
		bb = String(ctx.marker) + bb
	if _big.has(i):
		bb = "[center][font_size=%d][b]%s[/b][/font_size][/center]" % [int(int(ctx.size) * 1.45), bb]
	elif it.kind == "heading":
		bb = "[font_size=%d][b]%s[/b][/font_size]" % [int(int(ctx.size) * 1.15), bb]
	return bb


func _render() -> void:
	var ctx := _render_ctx()
	_bb_cache = PackedStringArray()
	_big = {}
	var first_heading := true
	for i in _items.size():
		var it: Dictionary = _items[i]
		if it.kind == "title" or (it.kind == "heading" and first_heading):
			_big[i] = true
			first_heading = false
		_bb_cache.append(_item_bbcode(i, ctx, false))
	_assign_text()
	_show_highlight()


func _assign_text() -> void:
	var v := _text.get_v_scroll_bar().value
	_text.text = "\n".join(_bb_cache)
	_text.get_v_scroll_bar().value = v


## Moves the highlight without touching the chapter text: the main label keeps
## showing the plain paragraphs, so its layout and scroll position stay exactly
## where they are (a running smooth scroll is never disturbed). Only the small
## overlay re-parses, for one paragraph.
func refresh_highlight(old: int, new: int) -> void:
	if _bb_cache.size() != _items.size():
		_render()
		return
	_show_highlight()


## Shows the spoken paragraph in the highlight overlay, lined up over that same
## paragraph in the main label. Hides the overlay when nothing is spoken or the
## highlight style adds no tags, so identical text is never drawn twice.
func _show_highlight() -> void:
	if _hl_label == null or tts == null:
		return
	var i := tts.highlight
	if i < 0 or i >= _items.size() or _bb_cache.size() != _items.size():
		_hl_label.hide()
		return
	var bb := _item_bbcode(i, _render_ctx(), true)
	if bb == _bb_cache[i]:
		_hl_label.hide()
		return
	_hl_label.text = bb
	_hl_label.show()
	_position_highlight()


## Re-lines the overlay up once, at the end of this frame. Never straight from a
## scroll signal: the layout getters it uses can make the label re-lay itself out and
## toggle its scrollbar, which changes the scroll value again and so re-enters the
## signal without end.
func _queue_position_highlight() -> void:
	if not _hl_queued:
		_hl_queued = true
		_position_highlight.call_deferred()


## Lines the overlay up with its paragraph: the same wrap width the main label
## lays out at (the one-paragraph overlay never needs a scrollbar, so the main
## bar's share comes off the width), shifted past the top margin and the scroll.
func _position_highlight() -> void:
	_hl_queued = true  # scroll signals the getters below set off must not queue another
	_line_up_highlight()
	_hl_queued = false


func _line_up_highlight() -> void:
	if _hl_label == null or not _hl_label.visible or tts == null:
		return
	if _text.size.x <= 0.0:
		return
	var i := tts.highlight
	if i < 0 or i >= _items.size():
		return
	var bar := _text.get_v_scroll_bar()
	var reserves := bar.size.x if bar.visible else 0.0
	var top := _text.get_paragraph_offset(i)
	var bottom := bar.max_value if i + 1 >= _items.size() else _text.get_paragraph_offset(i + 1)
	var margin_top := _text.get_theme_stylebox("normal").content_margin_top
	_hl_label.size = Vector2(maxf(_text.size.x - reserves, 1.0), maxf(bottom - top + 8.0, 8.0))
	_hl_label.position = Vector2(0.0, margin_top + top - bar.value)
	# The text draws no line that starts below its visible page (the rest of the
	# bottom margin is left clear for the player), so the overlay stops there too.
	var clip_bottom := _text.size.y
	for k in _hl_label.get_line_count():
		var line_top := top + _hl_label.get_line_offset(k)
		if line_top >= bar.value + bar.page:
			var pad := _hl_label.get_theme_constant("text_highlight_v_padding")  # a background mark reaches above its line
			clip_bottom = minf(clip_bottom, margin_top + line_top - bar.value - pad)
			break
	_hl_clip.offset_bottom = clip_bottom - _hl_clip.get_parent_control().size.y


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
	var span := _sentence_span(it, tts.highlight_sentence)
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
	var id: String = book.get("id", "")
	if index != chapter or _items.is_empty():
		Speech.stop()
		chapter = index
		await _load_chapter(paragraph)
	if book.get("id", "") != id or chapter != index or _items.is_empty():
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
	var token := _load_token
	await get_tree().process_frame
	if token != _load_token or book.get("id", "") != id:
		return
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


# --- TTS (control lives in ReaderTts; the page keeps the view) --------------------

func toggle_tts() -> void:
	tts.toggle()


## Reads the current chapter aloud, waiting first while it is still loading.
func start_tts(from := -1) -> void:
	tts.start(from)


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
		smooth_scroll_to(y)
	else:
		stop_smooth_scroll()
		bar.value = y


## Eases the text so content offset `y` (clamped) is at the top. A new call replaces
## the one in flight and starts from wherever that got to, so follow scrolls never
## fight each other.
func smooth_scroll_to(y: float, duration := 0.35) -> void:
	var bar := _text.get_v_scroll_bar()
	y = clampf(y, 0, maxf(0, bar.max_value - bar.page))
	stop_smooth_scroll()
	if absf(bar.value - y) < 1:
		return
	_scroll_target = y
	_scroll_tween = create_tween()
	_scroll_tween.tween_property(bar, "value", y, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Where the text is scrolled to, or is easing towards while a follow scroll runs.
func scroll_target() -> float:
	return _scroll_target if is_smooth_scrolling() else _text.get_v_scroll_bar().value


func stop_smooth_scroll() -> void:
	if _scroll_tween and _scroll_tween.is_valid():
		_scroll_tween.kill()
	_scroll_tween = null


## Whether a follow scroll is still easing.
func is_smooth_scrolling() -> bool:
	return _scroll_tween != null and _scroll_tween.is_running()


func _first_visible() -> int:
	var y := _text.get_v_scroll_bar().value
	for i in _items.size():
		if _text.get_paragraph_offset(i) >= y - 4:
			return i
	return 0


func _on_scrolled(_v: float) -> void:
	_hide_selection_bar()
	_update_footer()
	_queue_position_highlight()
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
	var shown := Speech.playing and Speech.source_owner == "reader"
	var rail_controls := _rail_tts_active()
	var floating := shown and not rail_controls
	if not rail_controls and is_instance_valid(_rail_more_popover):
		_rail_more_popover.close()
	if _player.visible != floating:
		_player.visible = floating
		_apply_layout()  # the text only leaves room at the bottom while the player shows
	_play_btn.icon = Icons.get_icon("play" if Speech.paused else "pause", Color("#06121f"), 22)
	_player_label.text = "%s  ·  paragraph %d of %d" % [Speech.voice_name(), Speech.current + 1, max(1, _items.size())]
	var sleeping := Speech.sleep_minutes != 0
	_sleep_btn.text = "" if not sleeping else ("Chapter" if Speech.sleep_minutes == -1 else Speech.sleep_label())
	_sleep_btn.icon = Icons.get_icon("moon", UiTheme.ACCENT if sleeping else UiTheme.MUTED, 18)
	_sleep_btn.tooltip_text = "Sleep timer: " + Speech.sleep_label()
	_rate_btn.text = "%sx" % str(float(Settings.get_value("tts_rate"))).trim_suffix(".0")
	if is_instance_valid(_rail_play_btn):
		_rail_play_btn.icon = Icons.get_icon("play" if Speech.paused else "pause", Color("#06121f"), 22)
	if is_instance_valid(_rail_info_label):
		_rail_info_label.text = "%s  ·  paragraph %d of %d" % [Speech.voice_name(), Speech.current + 1, max(1, _items.size())]
	if is_instance_valid(_rail_rate_btn):
		_rail_rate_btn.text = _rate_btn.text
	if is_instance_valid(_rail_sleep_btn):
		var rail_sleeping := Speech.sleep_minutes != 0
		_rail_sleep_btn.text = "Sleep" if not rail_sleeping else ("Chapter" if Speech.sleep_minutes == -1 else Speech.sleep_label())
		_rail_sleep_btn.icon = Icons.get_icon("moon", UiTheme.ACCENT if rail_sleeping else UiTheme.MUTED, 18)
		_rail_sleep_btn.tooltip_text = "Sleep timer: " + Speech.sleep_label()
	_fit_player()  # the sleep and speed labels change the bar's width


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
	# The TTS highlight, drawn above the text and clipped to the same bounds. Not a
	# child of the text: resizing a child makes a RichTextLabel lay out all of its
	# text again, which fires its scroll signal, which moves the overlay again.
	# It never takes input or shows its own bar.
	_hl_clip = Control.new()
	var hl_clip := _hl_clip
	hl_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	hl_clip.clip_contents = true
	hl_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hl_label = RichTextLabel.new()
	_hl_label.bbcode_enabled = true
	_hl_label.scroll_active = false
	_hl_label.selection_enabled = false
	_hl_label.context_menu_enabled = false
	_hl_label.focus_mode = Control.FOCUS_NONE
	_hl_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hl_label.hide()
	hl_clip.add_child(_hl_label)
	stack.add_child(_text)
	stack.add_child(hl_clip)
	_read_stack = stack
	_sel_bar = SelectionBar.new()
	_sel_bar.hide()
	stack.add_child(_sel_bar)
	_sel_bar.action.connect(_on_selection_action)

	_status = UI.vbox(14)
	_status.alignment = BoxContainer.ALIGNMENT_CENTER
	_status.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_status)

	# Floating TTS player
	_player = UI.panel("PlayerBar")
	_player.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var prow := UI.hbox(8)
	_player_row = prow
	prow.add_child(UI.icon_button("skip_back", "Back a sentence / paragraph", func(): Speech.skip_sentence(-1)))
	_play_btn = Button.new()
	_play_btn.theme_type_variation = "PrimaryButton"
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.custom_minimum_size = Vector2(44, 44)
	_play_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # stay round if the row gets taller
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
	prow.add_child(UI.icon_button("x", "Stop", func(): Speech.stop(); tts.clear_highlight()))
	_player.add_child(prow)
	_player.hide()
	var dock := UI.vbox(0, [UI.spacer(false), _player])
	dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dock_m := UI.margin(dock, 12, 0, 12, 18)
	dock_m.set_anchors_preset(Control.PRESET_FULL_RECT)
	dock_m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(dock_m)
	_player_dock = dock_m

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
	# Its text changes while scrolling; on a narrow screen a width that followed it
	# would resize the chapter text, whose re-layout moves the scroll, and so on.
	_footer_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	_hide_selection_bar()
	# The list scrolls vertically only, so anything wider than the screen
	# pushes the chapter rows (and their download icons) off the right edge.
	var side := 8 if compact else 24
	for v in [_contents_view, bookmarks.view]:
		v.add_theme_constant_override("margin_left", side)
		v.add_theme_constant_override("margin_right", side)
	_search_view.set_compact(value)
	if _contents_view.visible:
		_build_contents()
	if bookmarks.view.visible:
		bookmarks.build()
	_update_player()


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
	if book.get("id", "") != _contents_book:
		_contents_book = book.get("id", "")
		_open_groups.clear()
	var titles := PackedStringArray()
	for ch in book.chapters:
		titles.append(ch.title)
	var groups := BookGroups.split(titles, int(Settings.get_value("contents_group_size")))
	if groups.is_empty():
		for i in book.chapters.size():
			_contents_list.add_child(_chapter_button(i))
		return
	for g in groups:
		if int(g.start) <= chapter and chapter < int(g.end):
			_open_groups[int(g.start)] = true
	for g in groups:
		var box := UI.vbox(2)
		if _open_groups.has(int(g.start)):
			_fill_group(box, int(g.start), int(g.end))
		else:
			box.hide()
		_contents_list.add_child(_group_header(g, box))
		_contents_list.add_child(box)


## One Contents chapter row: the title, muted once read, with a download badge for web books.
func _chapter_button(i: int) -> Button:
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
	return b


## A Contents group header: the group's label and chapter count, with a chevron
## showing whether its chapter list (built lazily) is expanded.
func _group_header(g: Dictionary, box: VBoxContainer) -> Button:
	var start := int(g.start)
	var end := int(g.end)
	var n := end - start
	var b := Button.new()
	b.set_meta("group_start", start)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size.y = 44
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Vector4(14, 10, 14, 10)
	b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_3, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_font_override("font", UiTheme.sans_semibold)
	b.add_theme_color_override("font_color", UiTheme.TEXT)
	b.text = "%s  ·  %d %s" % [g.label, n, "chapter" if n == 1 else "chapters"]
	b.icon = Icons.get_icon("chev_down" if _open_groups.has(start) else "chev_right", UiTheme.MUTED, 18)
	b.pressed.connect(func(): _toggle_group(b, box, start, end))
	return b


## Opens or closes a Contents group in place, so the list keeps its scroll position.
func _toggle_group(header: Button, box: VBoxContainer, start: int, end: int) -> void:
	if _open_groups.has(start):
		_open_groups.erase(start)
		box.hide()
		header.icon = Icons.get_icon("chev_right", UiTheme.MUTED, 18)
	else:
		_open_groups[start] = true
		_fill_group(box, start, end)
		box.show()
		header.icon = Icons.get_icon("chev_down", UiTheme.MUTED, 18)


## Builds a group's chapter rows the first time it is shown, so opening
## Contents stays fast even with thousands of chapters.
func _fill_group(box: VBoxContainer, start: int, end: int) -> void:
	if box.get_child_count() > 0:
		return
	for i in range(start, end):
		box.add_child(_chapter_button(i))


# --- bookmarks ---------------------------------------------------------------


func go_to_bookmark(m: Dictionary) -> void:
	if m.chapter >= book.chapters.size():
		return
	select_tab(0)
	header_changed.emit()
	if m.chapter == chapter and not _items.is_empty():
		var id: String = book.get("id", "")
		var at := chapter
		var token := _load_token
		await get_tree().process_frame
		if token != _load_token or book.get("id", "") != id or chapter != at:
			return
		_scroll_to(m.paragraph, false)
		Library.set_progress(book.id, chapter, m.paragraph)
		return
	Speech.stop()
	chapter = m.chapter
	header_changed.emit()
	await _load_chapter(m.paragraph)


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
	chips.add_child(UI.chip(BookStatus.kind_label(book), UiTheme.ACCENT))
	chips.add_child(UI.chip(BookStatus.source_name(book)))
	if book.get("dropped", false):
		chips.add_child(UI.chip("Dropped", UiTheme.BAD))
	elif BookStatus.is_finished(book):
		chips.add_child(UI.chip("Finished", UiTheme.GOOD))
	if BookStatus.is_favorite(book):
		chips.add_child(UI.chip("Favorite", UiTheme.ACCENT))
	if BookStatus.is_archived(book):
		chips.add_child(UI.chip("Archived", UiTheme.MUTED))
	for tag in book.get("tags", []):
		var tb := UI.button(tag, "", "ChipButton", func(): main.pages.library.show_tag(tag), UiTheme.MUTED)
		tb.tooltip_text = "Show the books tagged “%s”" % tag
		chips.add_child(tb)
	col.add_child(UI.margin(chips, 0, 4, 0, 8))
	if book.get("possible_gap", false):
		var gap := UI.label("Some new chapters may be missing. Open the book in the Web tab to fill them in.", "Small", true)
		gap.add_theme_color_override("font_color", UiTheme.WARN)
		col.add_child(gap)
	var stats := HFlowContainer.new()  # wraps on narrow (phone) screens
	stats.add_theme_constant_override("h_separation", 28)
	stats.add_theme_constant_override("v_separation", 14)
	stats.add_child(_stat("Chapters", str(book.chapters.size())))
	stats.add_child(_stat("Progress", "%d%%" % int(BookStatus.progress_ratio(book) * 100)))
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
	if not Library.editable_fields(book).is_empty():
		var edit := UI.button("Edit details", "pencil", "", _edit_details)
		if Library.is_file_book(book):
			edit.tooltip_text = "Change the title, author, tags and description"
		else:
			edit.tooltip_text = "Change the title and tags shown for this book"
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
	var favorite: bool = BookStatus.is_favorite(book)
	var fav := UI.button("Unfavorite" if favorite else "Favorite", "star_fill" if favorite else "star", "", _toggle_favorite)
	fav.tooltip_text = "Remove this book from the Favorites tab" if favorite \
		else "Also show this book in the library's Favorites tab"
	buttons.add_child(fav)
	var archived: bool = BookStatus.is_archived(book)
	var arch := UI.button("Unarchive" if archived else "Archive", "archive", "", _toggle_archived)
	arch.tooltip_text = "Put this book back in the library's other tabs" if archived \
		else "Move this book to the library's Archive tab, out of Reading, the other tabs and Updates (a favorite stays in Favorites). It's only checked for new chapters from its chapter list."
	buttons.add_child(arch)
	var dropped: bool = book.get("dropped", false)
	var drop := UI.button("Undo drop" if dropped else "Mark as dropped", "refresh" if dropped else "x", "", _toggle_dropped)
	drop.tooltip_text = "Show this book in the Reading tab again" if dropped \
		else "Hide this book from the Reading tab until you open it again"
	buttons.add_child(drop)
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


func _toggle_dropped() -> void:
	var dropped: bool = not book.get("dropped", false)
	Library.set_dropped(book.id, dropped)
	book = Library.get_book(book.id)
	_build_details()
	main.toast("Marked as dropped" if dropped else "Back in your Reading list", "ok")


func _toggle_favorite() -> void:
	var favorite: bool = not BookStatus.is_favorite(book)
	Library.set_favorite(book.id, favorite)
	book = Library.get_book(book.id)
	_build_details()
	main.toast("Added to favorites" if favorite else "Removed from favorites", "ok")


func _toggle_archived() -> void:
	var archived: bool = not BookStatus.is_archived(book)
	Library.set_archived(book.id, archived)
	book = Library.get_book(book.id)
	_build_details()
	main.toast("Archived. Find it in the library's Archive tab" if archived else "Back in your library", "ok")


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
	if not EpubMatch.same_series(book, parsed):
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
	elif r.filled == 0 and r.added == 0:
		main.toast("All %d chapter(s) the EPUB has are already downloaded" % r.matched, "ok")
	elif r.added == 0:
		main.toast("Added %d chapter(s) from the EPUB" % r.filled, "ok")
	else:
		main.toast("Added %d chapter(s) from the EPUB, %d of them no longer on the site" % [r.filled + r.added, r.added], "ok")


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
	elif key == "contents_group_size":
		# Open groups are keyed by their first chapter, which no longer lines up.
		_open_groups.clear()
		if not book.is_empty() and _contents_view.visible:
			_build_contents()


func _apply_style() -> void:
	var c := Settings.reader_colors()
	_bg.color = c.bg
	var serif: bool = Settings.get_value("reader_font") == "serif"
	var size := int(Settings.get_value("font_size"))
	# The highlight overlay renders one paragraph of the same text, so it gets
	# every layout-affecting override the main label gets.
	for rt: RichTextLabel in [_text, _hl_label]:
		rt.add_theme_font_override("normal_font", UiTheme.serif if serif else UiTheme.sans)
		rt.add_theme_font_override("bold_font", UiTheme.serif_bold if serif else UiTheme.sans_bold)
		rt.add_theme_font_override("italics_font", UiTheme.serif_italic if serif else UiTheme.sans)
		rt.add_theme_font_override("bold_italics_font", UiTheme.serif_bold if serif else UiTheme.sans_bold)
		for k in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
			rt.add_theme_font_size_override(k, size)
		rt.add_theme_color_override("default_color", c.text)
		rt.add_theme_color_override("selection_color", Color(UiTheme.ACCENT, 0.3))
		rt.add_theme_constant_override("line_separation", int(Settings.get_value("line_spacing")) + int(size * 0.2))
		rt.add_theme_constant_override("paragraph_separation", int(Settings.get_value("paragraph_gap")))
		apply_alignment(rt)
		rt.add_theme_constant_override("text_highlight_h_padding", 6)
		rt.add_theme_constant_override("text_highlight_v_padding", 3)
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


## Sets the reader's alignment on a label. When justified, a paragraph's only line is left
## alone like the last line of a longer one, instead of being stretched across the column.
static func apply_alignment(rt: RichTextLabel) -> void:
	rt.horizontal_alignment = text_alignment()
	rt.justification_flags &= ~TextServer.JUSTIFICATION_DO_NOT_SKIP_SINGLE_LINE


func _set_status_colors(c: Dictionary) -> void:
	for l in _status.get_children():
		if l is Label:
			l.add_theme_color_override("font_color", c.muted)


func _apply_layout() -> void:
	if _text == null:
		return
	_hide_selection_bar()
	var col := float(Settings.get_value("column_width"))
	var w := _text.size.x
	var side := maxf(float(Settings.get_value("side_margin")), (w - col) / 2.0)
	var style := StyleBoxEmpty.new()
	style.content_margin_left = side
	style.content_margin_right = side
	style.content_margin_top = 36 if not compact else 20
	# Keep the last lines clear of the floating TTS player; without it, use the space for text.
	style.content_margin_bottom = 120 if _player.visible else style.content_margin_top
	_text.add_theme_stylebox_override("normal", style)
	_text.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Same side margins, so the text starts at the same x; no top or bottom margin, as
	# _position_highlight() places the overlay's top on the paragraph's first line.
	var hl_style: StyleBoxEmpty = style.duplicate()
	hl_style.content_margin_top = 0
	hl_style.content_margin_bottom = 0
	_hl_label.add_theme_stylebox_override("normal", hl_style)
	_hl_label.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_queue_position_highlight()  # margins or width changed
	_player.custom_minimum_size.x = 0 if compact else 520
	_player_info.visible = not compact
	# On a phone the bar has no room to spare: a countdown beside the moon pushes the
	# stop button off screen, so put it under the moon in small type instead.
	_sleep_btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP if compact else VERTICAL_ALIGNMENT_CENTER
	_sleep_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if compact else HORIZONTAL_ALIGNMENT_LEFT
	_sleep_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	if compact:
		_sleep_btn.add_theme_font_size_override("font_size", 11)
		_sleep_btn.add_theme_constant_override("h_separation", 0)
	else:
		_sleep_btn.remove_theme_font_size_override("font_size")
		_sleep_btn.remove_theme_constant_override("h_separation")
	_fit_player()


## Very thin screens can't fit the floating bar with its side gaps and padding,
## so it turns into a plain strip across the full width at the bottom.
func _fit_player() -> void:
	var gap := 4 if compact else 8
	var cur := _player_row.get_theme_constant("separation")
	var bare := 0.0  # the buttons alone, no gaps
	var shown := 0
	for c: Control in _player_row.get_children():
		if c.visible:
			bare += c.get_combined_minimum_size().x
			shown += 1
	var gaps := maxi(1, shown - 1)
	var fb: StyleBox = _player.get_theme_stylebox("panel", "PlayerBar")
	var need := bare + gap * gaps + fb.get_margin(SIDE_LEFT) + fb.get_margin(SIDE_RIGHT)
	var edge := compact and need > _text.size.x - 24  # 12px gap on each side when floating
	if edge:  # as much gap as fits, down to none
		gap = clampi(int((_text.size.x - 8 - bare) / gaps), 0, gap)
	if cur != gap:
		_player_row.add_theme_constant_override("separation", gap)
	if edge == _player_edge:
		return
	_player_edge = edge
	for side in ["margin_left", "margin_right"]:
		_player_dock.add_theme_constant_override(side, 0 if edge else 12)
	_player_dock.add_theme_constant_override("margin_bottom", 0 if edge else 18)
	_player.size_flags_horizontal = Control.SIZE_FILL if edge else Control.SIZE_SHRINK_CENTER
	_player_row.alignment = BoxContainer.ALIGNMENT_CENTER
	if edge:
		var strip := UiTheme.box(UiTheme.SURFACE, 0, Color.TRANSPARENT, 0, Vector4(4, 8, 4, 8))
		strip.border_color = UiTheme.BORDER
		strip.border_width_top = 1
		_player.add_theme_stylebox_override("panel", strip)
	else:
		_player.remove_theme_stylebox_override("panel")


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


func _show_tts_popup(anchor: Control = null) -> void:
	var btn: Control = anchor if is_instance_valid(anchor) else find_child("TtsSettingsButton", true, false)
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
		_tap = false
		# Off until the finger lifts: jitter of a held finger across a line edge
		# would otherwise select a line's worth of text under the bar.
		_text.selection_enabled = false
		_text.focus_mode = Control.FOCUS_CLICK
		_show_selection_bar(_press_at))
	add_child(_press_timer)


## Notes the paragraph under a right-click (for the menu). On touch screens a
## long press or a touch release after selecting pops up the selection bar,
## since there is no right-click.
func _on_text_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		_menu_paragraph = _paragraph_at(e.position)
	elif e is InputEventScreenTouch:
		if e.pressed:
			_press_at = e.position
			_press_scroll = _text.get_v_scroll_bar().value
			_tap = not e.double_tap
			_hide_selection_bar()
			if _tap:
				_press_timer.start()
		else:
			_press_timer.stop()
			var long_press := not _text.selection_enabled
			if long_press:
				_text.selection_enabled = true
				_text.focus_mode = Control.FOCUS_CLICK
			# A press only moves the nearest end of an existing selection (the label
			# gets the emulated mouse press before this touch event), so without
			# this a touch screen could never dismiss a selection. After a long
			# press the label still holds what the jitter selected and brings it back.
			# A slow swipe both scrolls and selects; the selection is a side effect.
			var scrolled := absf(_text.get_v_scroll_bar().value - _press_scroll) > 1.0
			if _tap or long_press or scrolled:
				_text.deselect.call_deferred()
			else:
				_maybe_show_selection_bar.call_deferred(e.position)
	elif e is InputEventScreenDrag and e.position.distance_to(_press_at) > 12:
		_tap = false
		_press_timer.stop()


## Shows the selection bar after a touch release, once the label has caught up
## with the touch. Only when text ended up selected, so taps and scrolls do nothing.
func _maybe_show_selection_bar(anchor: Vector2) -> void:
	if _text.get_selected_text().strip_edges() == "":
		return
	_show_selection_bar(anchor)


## Shows the selection bar at a touch point: Copy, Bookmark and More when text
## is selected, Bookmark and Copy paragraph on a long press with no selection.
func _show_selection_bar(anchor: Vector2) -> void:
	if _items.is_empty():
		return
	var i := _paragraph_at(anchor)
	if i < 0:
		return
	_sel_paragraph = i
	_sel_bar.show_at(anchor, Rect2(Vector2.ZERO, _read_stack.size),
		_selection_actions(_text.get_selected_text().strip_edges() != "", _bookmarked(i)))


## Hides the selection bar and its More menu, if either is open.
func _hide_selection_bar() -> void:
	if is_instance_valid(_sel_bar):
		_sel_bar.hide()
	if is_instance_valid(_sel_popup):
		_sel_popup.hide()
		_sel_popup = null


## Whether paragraph i of this chapter already has a bookmark.
func _bookmarked(i: int) -> bool:
	return i >= 0 and not Library.bookmark_at(book, chapter, i).is_empty()


## The buttons for the touch selection bar: Copy, Bookmark and More with a
## selection; Bookmark and Copy paragraph without one.
static func _selection_actions(has_selection: bool, bookmarked: bool) -> Array:
	var mark := {"id": SEL_BOOKMARK, "text": "Edit bookmark" if bookmarked else "Bookmark",
		"icon": "bookmark_fill" if bookmarked else "bookmark"}
	if not has_selection:
		return [mark, {"id": SEL_COPY_PARA, "text": "Copy paragraph", "icon": "copy"}]
	return [{"id": SEL_COPY, "text": "Copy", "icon": "copy"}, mark,
		{"id": SEL_MORE, "text": "More", "icon": "more"}]


func _on_selection_action(id: int) -> void:
	match id:
		SEL_COPY:
			_copy_text(_text.get_selected_text().strip_edges())
			_text.deselect()
		SEL_COPY_PARA:
			_copy_text(_paragraph_plain(_sel_paragraph))
		SEL_BOOKMARK:
			bookmarks.edit_bookmark(_sel_paragraph)
		SEL_MORE:
			_show_more_menu()
			return
	_hide_selection_bar()


## Copies text to the clipboard, if there is any, and says so.
func _copy_text(s: String) -> void:
	if s == "":
		return
	DisplayServer.clipboard_set(s)
	main.toast("Copied.", "ok")


## The paragraph's shown text, without BBCode, for copying.
func _paragraph_plain(i: int) -> String:
	if i < 0 or i >= _items.size():
		return ""
	return _visible_text(_items[i].bb).strip_edges()


## The three selection rule actions as a pop-up, reusing the menu logic.
func _show_more_menu() -> void:
	_hide_selection_bar()
	var menu := PopupMenu.new()
	menu.add_item("Fix pronunciation of selection…", MENU_FIX_SPEECH)
	menu.add_item("Don't read selection aloud…", MENU_SKIP_SPEECH)
	menu.add_item("Replace selection in text…", MENU_REPLACE_TEXT)
	add_child(menu)
	_sel_popup = menu
	menu.id_pressed.connect(_on_menu_item)
	menu.popup_hide.connect(func(): menu.queue_free())
	var r := _sel_bar.get_global_rect()
	menu.popup(Rect2i(Vector2i(int(r.position.x), int(r.end.y + 4)), Vector2i.ZERO))


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
			bookmarks.edit_bookmark(_menu_paragraph)
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
	var r := await Sources.refresh(book, false, true)
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
