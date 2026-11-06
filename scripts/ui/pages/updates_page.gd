class_name UpdatesPage
extends Page
## New chapters for followed web serials, and saved searches.

const SEARCHES_TAB := 2
## Check for updates stays locked at least this long, so it can't be pressed over and over.
const MIN_CHECK_SECONDS := 10.0

var _content: VBoxContainer
var _refreshing := false
var _checked := 0       # books done in the running check
var _to_check := 0      # books in the running check
var _ring: ProgressRing
var _rebuild_queued := false


func _ready() -> void:
	_content = UI.vbox(6)
	var s := UI.scroll(UI.margin(_content, 32, 24, 32, 40))
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(s)
	Library.changed.connect(_rebuild_soon)
	SavedSearches.changed.connect(func():
		if visible and tab == SEARCHES_TAB:
			_rebuild())


## Rebuilds at the end of the frame, once however many books changed (a sync
## can add hundreds at a time).
func _rebuild_soon() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild_queued_now.call_deferred()


func _rebuild_queued_now() -> void:
	_rebuild_queued = false
	if visible:
		_rebuild()


func page_title() -> String:
	return "Updates"


func tabs() -> PackedStringArray:
	return ["Latest", "Following", "Saved searches"]


func build_actions(bar: HBoxContainer) -> void:
	var b := UI.button("" if compact else ("Checking…" if _refreshing else "Check for updates"), "refresh", "", refresh_all)
	b.disabled = _refreshing
	if _refreshing:
		_ring = ProgressRing.new()
		bar.add_child(_ring)
		_update_ring()
	bar.add_child(b)


func _update_ring() -> void:
	if is_instance_valid(_ring):
		_ring.value = float(_checked) / _to_check if _to_check > 0 else 1.0
		_ring.tooltip_text = "Checked %d of %d" % [_checked, _to_check]


func on_shown() -> void:
	_rebuild()


func _on_tab(_i: int) -> void:
	_rebuild()


func refresh_all() -> void:
	if _refreshing:
		return
	_refreshing = true
	var total := 0
	var errors := 0
	var skipped := 0
	var started := Time.get_ticks_msec()
	var books := _web_books()
	_checked = 0
	_to_check = books.size()
	header_changed.emit()
	for b in books:
		if Net.blocked_since(b.url, started):  # don't keep asking a site that's showing a bot check
			skipped += 1
		else:
			var r: Dictionary = await Sources.refresh(b, true)
			total += r.new
			if r.error != "":
				errors += 1
		_checked += 1
		_update_ring()
	var found := "%d new chapter(s)" % total
	if skipped:
		found += " · %d skipped (bot check)" % skipped
	main.toast("%s%s" % [found, (" · %d source(s) failed" % errors) if errors else ""], "warn" if errors or skipped else "ok")
	_rebuild()
	var left := MIN_CHECK_SECONDS - (Time.get_ticks_msec() - started) / 1000.0
	if left > 0.0:
		await get_tree().create_timer(left).timeout
	_refreshing = false
	header_changed.emit()


func _web_books() -> Array:
	return Library.books.filter(func(b): return b.kind == "web")


func _rebuild() -> void:
	UI.clear(_content)
	if tab == SEARCHES_TAB:
		_searches()
		return
	var books := _web_books()
	if books.is_empty():
		var col := UI.vbox(8)
		col.add_child(UI.label("No web serials yet", "H2"))
		col.add_child(UI.label("Add a web serial and new chapters will show up here.", "Muted", true))
		col.add_child(UI.margin(UI.button("Browse web novels", "compass", "PrimaryButton", func(): main.navigate("browse")), 0, 8, 0, 0))
		_content.add_child(col)
		return
	if tab == 0:
		_latest(books)
	else:
		_following(books)


func _latest(books: Array) -> void:
	var entries: Array = []
	for b in books:
		var n: int = b.chapters.size()
		for i in range(max(0, n - 6), n):
			entries.append({"book": b, "index": i, "date": float(b.chapters[i].get("date", 0))})
	entries.sort_custom(func(a, c): return a.date > c.date if a.date != c.date else a.index > c.index)
	var last_group := ""
	for e in entries.slice(0, 40):
		var group := _group(e.date)
		if group != last_group:
			_content.add_child(UI.margin(UI.label(group.to_upper(), "Overline"), 12, 16 if last_group != "" else 0, 0, 6))
			last_group = group
		_content.add_child(_chapter_row(e.book, e.index, e.date))


func _group(date: float) -> String:
	if date <= 0:
		return "Earlier"
	var days := (Time.get_unix_time_from_system() - date) / 86400.0
	if days < 1: return "Today"
	if days < 7: return "This week"
	if days < 31: return "This month"
	return "Older"


func _chapter_row(book: Dictionary, index: int, date: float) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", UiTheme.box(Color.TRANSPARENT, 10))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE, 10))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_2, 10))
	b.custom_minimum_size.y = 72
	var row := UI.hbox(14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover := CoverView.new()
	cover.custom_minimum_size = Vector2(36, 54)
	cover.radius = 4
	cover.set_book(book)
	row.add_child(cover)
	var info := UI.vbox(2)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t := UI.label(book.chapters[index].title, "H3")
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.custom_minimum_size.x = 80
	info.add_child(t)
	var sub := UI.label("%s  ·  %s" % [book.title, UI.relative_time(date) if date > 0 else "Chapter %d" % (index + 1)], "Small")
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.custom_minimum_size.x = 80
	info.add_child(sub)
	row.add_child(info)
	var unread: bool = index > book.progress.chapter or book.last_read == 0
	if unread:
		row.add_child(UI.chip("Unread", UiTheme.ACCENT))
	var cached: bool = Library.has_chapter(book.id, index) and not Library.load_chapter(book.id, index).get("excerpt", false)
	var ic := UI.icon("check" if cached else ("rss" if book.get("rss_only") else "download"), UiTheme.GOOD if cached else UiTheme.FAINT, 16)
	ic.tooltip_text = "Downloaded" if cached else "Preview only"
	row.add_child(ic)
	var m := UI.margin(row, 12, 9, 14, 9)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(m)
	b.pressed.connect(func(): main.open_reader(book.id, index))
	return b


func _following(books: Array) -> void:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16)
	flow.add_theme_constant_override("v_separation", 16)
	for b in books:
		var card := UI.panel("Card")
		card.custom_minimum_size.x = 340 if not compact else 0
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL if compact else Control.SIZE_FILL
		var row := UI.hbox(16)
		var cover := CoverView.new()
		cover.custom_minimum_size = Vector2(64, 96)
		cover.radius = 6
		cover.set_book(b)
		row.add_child(cover)
		var col := UI.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t := UI.label(b.title, "H3")
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		t.custom_minimum_size.x = 120
		col.add_child(t)
		col.add_child(UI.label(BookCard._source_name(b) + ("  ·  RSS" if b.get("rss_only") else ""), "Small"))
		var unread: int = b.chapters.size() - (b.progress.chapter + 1 if b.last_read > 0 else 0)
		col.add_child(UI.label("%d chapters  ·  %d unread" % [b.chapters.size(), unread], "Muted"))
		col.add_child(UI.label("Checked " + UI.relative_time(b.get("last_checked", 0)), "Small"))
		var actions := UI.hbox(8)
		actions.add_child(UI.button("Read", "", "ChipButton", func(): main.open_reader(b.id)))
		actions.add_child(UI.button("Check", "", "ChipButton", func():
			var r: Dictionary = await Sources.refresh(b)
			main.toast(r.error if r.error != "" else "%d new chapter(s)" % r.new, "error" if r.error != "" else "ok")))
		col.add_child(UI.margin(actions, 0, 6, 0, 0))
		row.add_child(col)
		card.add_child(row)
		flow.add_child(card)
	_content.add_child(flow)


# --- saved searches ----------------------------------------------------------

func _searches() -> void:
	var intro := UI.panel("Card")
	var col := UI.vbox(10)
	col.add_child(UI.label("Saved searches", "H2"))
	var how := "When you open one in the Web tab, works that weren't on it the last time get a thick border and a note at the top." \
		if main.web_available() else "They open in your browser."
	col.add_child(UI.label("Do a search on a site whose plugin supports saved searches, then press Save search in the Web tab, or paste the page's link here. " + how, "Muted", true))
	var row := UI.hbox(10)
	var url_edit := LineEdit.new()
	url_edit.placeholder_text = "Link to a search or list of works"
	url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_edit.custom_minimum_size = Vector2(120, 40)
	row.add_child(url_edit)
	var save := func():
		var s := SavedSearches.add(url_edit.text)
		if s.has("error"):
			main.toast(s.error, "error")
		else:
			url_edit.text = ""
			main.toast("Saved “%s”" % s.name, "ok")
	url_edit.text_submitted.connect(func(_t): save.call())
	row.add_child(UI.button("Save", "plus", "PrimaryButton", save))
	col.add_child(row)
	intro.add_child(col)
	_content.add_child(intro)
	for s in SavedSearches.searches():
		_content.add_child(UI.margin(_search_card(s), 0, 10, 0, 0))


func _search_card(s: Dictionary) -> Control:
	var card := UI.panel("Card")
	var col := UI.vbox(8)
	var head := UI.hbox(10, [UI.icon("search", UiTheme.ACCENT, 20)])
	var name := LineEdit.new()
	name.text = s.name
	name.flat = true
	name.tooltip_text = "Rename"
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.add_theme_font_size_override("font_size", 17)
	var rename := func(): if name.text.strip_edges() != "" and name.text != s.name: SavedSearches.update(s.id, {"name": name.text.strip_edges()})
	name.text_submitted.connect(func(_t): rename.call())
	name.focus_exited.connect(rename)
	head.add_child(name)
	head.add_child(UI.button("" if compact else "Open", "globe", "PrimaryButton", func():
		SavedSearches.mark_opened(s.id)
		main.open_web(s.url)))
	head.add_child(UI.icon_button("x", "Remove this saved search", func(): SavedSearches.remove(s.id)))
	col.add_child(head)
	var opened := SavedSearches.last_opened(s.id)
	var line := ("Last checked " + UI.relative_time(opened)) if opened > 0 else "Not checked yet"
	if opened > 0 and main.web_available() and SavedSearches.last_found(s.id) > 0:
		line += "  ·  %d new then" % SavedSearches.last_found(s.id)
	col.add_child(UI.label(line, "Small"))
	var tip := SavedSearches.tip(s.url)
	if tip != "":
		col.add_child(UI.label(tip, "Small", true))
	card.add_child(col)
	return card
