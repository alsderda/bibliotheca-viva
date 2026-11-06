class_name SearchView
extends MarginContainer
## The reader's Search tab: finds text in a range of the book's chapters. Searches the
## text as the reader shows it (after display rules). Clicking a result opens the
## chapter there and marks the match. Only chapters on this device are searched:
## it never downloads any.

const MAX_SHOWN := 300      # result rows; more are counted but not listed

var reader: ReaderPage
var _book_id := ""
var _query: LineEdit
var _regex: CheckBox
var _from: SpinBox
var _to: SpinBox
var _search_btn: Button
var _status: Label
var _missing_box: PanelContainer
var _results: VBoxContainer
var _missing: Array = []    # chapters in the searched range that aren't downloaded
var _token := 0             # bumped to cancel a running search
var _busy := false


func _init(owner_page: ReaderPage) -> void:
	reader = owner_page
	var col := UI.vbox(12)
	add_child(UI.scroll(UI.margin(col, 0, 20, 0, 40)))

	var row := UI.hbox(8)
	_query = LineEdit.new()
	_query.theme_type_variation = "SearchField"
	_query.placeholder_text = "Search this book"
	_query.right_icon = Icons.get_icon("search", UiTheme.FAINT, 18)
	_query.custom_minimum_size.y = 40
	_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query.text_submitted.connect(func(_t): _run())
	row.add_child(_query)
	_search_btn = UI.button("Search", "search", "PrimaryButton", _on_search_pressed)
	row.add_child(_search_btn)
	col.add_child(row)

	var opts := HFlowContainer.new()  # wraps on narrow (phone) screens
	opts.add_theme_constant_override("h_separation", 10)
	opts.add_theme_constant_override("v_separation", 8)
	_from = _spin()
	_to = _spin()
	opts.add_child(UI.hbox(8, [_mid_label("Chapters"), _from, _mid_label("to"), _to]))
	opts.add_child(UI.button("This chapter", "", "ChipButton", func(): _set_range(reader.chapter + 1, reader.chapter + 1)))
	opts.add_child(UI.button("Whole book", "", "ChipButton", func(): _set_range(1, _chapter_count())))
	_regex = CheckBox.new()
	_regex.text = "Regex"
	_regex.focus_mode = Control.FOCUS_NONE
	_regex.tooltip_text = "Search with a regular expression. Matches case as written; add (?i) to ignore it."
	opts.add_child(_regex)
	col.add_child(opts)

	_status = UI.label("", "Muted", true)
	col.add_child(_status)
	_missing_box = UI.panel("Banner")
	_missing_box.hide()
	col.add_child(_missing_box)
	_results = UI.vbox(4)
	col.add_child(_results)


## Called when the tab is shown: a different book starts a fresh search.
func refresh() -> void:
	var n := _chapter_count()
	_from.max_value = maxi(1, n)
	_to.max_value = maxi(1, n)
	if reader.book.get("id", "") != _book_id:
		_book_id = reader.book.get("id", "")
		_token += 1
		_set_busy(false)
		_query.text = ""
		_set_range(1, n)
		_clear()
	_query.grab_focus.call_deferred()


func set_compact(value: bool) -> void:
	var side := 8 if value else 24
	add_theme_constant_override("margin_left", side)
	add_theme_constant_override("margin_right", side)


# --- searching ---------------------------------------------------------------

func _on_search_pressed() -> void:
	if _busy:
		_token += 1
		_set_busy(false)
		_status.text = "Stopped."
	else:
		_run()


func _run() -> void:
	var query := _query.text
	if query.strip_edges() == "":
		return
	var re := BookSearch.compile(query, _regex.button_pressed)
	if re == null:
		_clear()
		_status.text = "That isn't a valid regular expression."
		return
	var book: Dictionary = reader.book
	var a := int(_from.value) - 1
	var b := int(_to.value) - 1
	if a > b:
		_set_range(b + 1, a + 1)
		var t := a; a = b; b = t
	_token += 1
	var token := _token
	_clear()
	_set_busy(true)
	var hl := UiTheme.ACCENT.to_html(false)
	var total := 0
	var chapters_hit := 0
	var shown := 0
	var started := Time.get_ticks_msec()
	for i in range(a, b + 1):
		if Time.get_ticks_msec() - started > 12:  # keep the app responsive on big books
			_status.text = "Searching… %d of %d chapters" % [i - a, b - a + 1]
			await get_tree().process_frame
			if token != _token or reader.book.get("id", "") != book.id:
				return
			started = Time.get_ticks_msec()
		if book.kind == "web" and not Library.has_full_chapter(book.id, i):
			_missing.append(i)
		var data: Dictionary = Library.load_chapter(book.id, i)
		if data.is_empty():
			continue
		var hits := []  # [paragraph, span, paragraph text]
		var items := reader.chapter_items(data, i)
		for p in items.size():
			var text := ReaderPage._visible_text(items[p].bb)
			for span in BookSearch.find_all(re, text):
				hits.append([p, span, text])
		if hits.is_empty():
			continue
		total += hits.size()
		chapters_hit += 1
		if shown >= MAX_SHOWN:
			continue
		_results.add_child(_chapter_header(book, i, hits.size()))
		for h in hits:
			if shown >= MAX_SHOWN:
				break
			_results.add_child(_result_row(i, h[0], h[1], h[2], hl))
			shown += 1
	_set_busy(false)
	var range_text := "chapter %d" % (a + 1) if a == b else "chapters %d–%d" % [a + 1, b + 1]
	if total == 0:
		_status.text = "No matches in %s." % range_text
	else:
		_status.text = "%d match%s in %d chapter%s (%s)." % [total, "" if total == 1 else "es", chapters_hit, "" if chapters_hit == 1 else "s", range_text]
		if shown < total:
			_status.text += " Showing the first %d. Narrow the chapter range to see the rest." % shown
	_show_missing(book)


func _clear() -> void:
	UI.clear(_results)
	_missing.clear()
	_status.text = ""
	_missing_box.hide()


func _set_busy(value: bool) -> void:
	_busy = value
	_search_btn.text = "Stop" if value else "Search"
	_search_btn.icon = Icons.get_icon("x" if value else "search", Color("#06121f"), 18)


# --- chapters that aren't downloaded -----------------------------------------

func _show_missing(book: Dictionary) -> void:
	UI.clear(_missing_box)
	_missing_box.visible = not _missing.is_empty()
	if _missing.is_empty():
		return
	var n := _missing.size()
	var text := "%d chapter%s in this range %s downloaded, so only %s preview (if any) was searched." % [
		n, "" if n == 1 else "s", "isn't" if n == 1 else "aren't", "its" if n == 1 else "their"]
	var l := UI.label(text, "Small", true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", UiTheme.WARN)
	_missing_box.add_child(UI.hbox(10, [UI.icon("download", UiTheme.WARN, 18), l]))


# --- results -----------------------------------------------------------------

func _chapter_header(book: Dictionary, index: int, hits: int) -> Control:
	var title := UI.label("%d.   %s" % [index + 1, book.chapters[index].title], "H3")
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := UI.hbox(10, [title, UI.chip(str(hits))])
	return UI.margin(row, 6, 14, 6, 2)


func _result_row(index: int, paragraph: int, span: Vector2i, text: String, color: String) -> Control:
	var pad := Vector4(14, 10, 14, 10)
	var normal := UiTheme.box(Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, pad)
	var hover := UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, pad)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", normal)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.tooltip_text = "Open chapter %d here" % (index + 1)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.add_theme_color_override("default_color", UiTheme.MUTED)
	rt.text = BookSearch.snippet(text, span, color)
	panel.add_child(rt)
	panel.mouse_entered.connect(func(): panel.add_theme_stylebox_override("panel", hover))
	panel.mouse_exited.connect(func(): panel.add_theme_stylebox_override("panel", normal))
	var matched := text.substr(span.x, span.y - span.x)
	panel.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			reader.show_match(index, paragraph, span.x, matched)
		elif e is InputEventScreenTouch and not e.pressed:
			reader.show_match(index, paragraph, span.x, matched))
	return panel


# --- helpers -----------------------------------------------------------------

func _chapter_count() -> int:
	return reader.book.get("chapters", []).size()


func _set_range(from: int, to: int) -> void:
	_from.value = from
	_to.value = to


func _spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = 1
	s.step = 1
	s.rounded = true
	s.select_all_on_focus = true
	s.custom_minimum_size = Vector2(96, 40)
	s.get_line_edit().text_submitted.connect(func(_t): _run.call_deferred())
	return s


static func _mid_label(text: String) -> Label:
	var l := UI.label(text, "Muted")
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l
