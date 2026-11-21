class_name LibraryPage
extends Page
## Book grid with "continue reading" hero and filters in the top bar.

const FILTERS := ["Reading", "All", "Ebooks", "Web serials", "Favorites", "Archive"]
const READING_TAB := 0
const ALL_TAB := 1
const EBOOKS_TAB := 2
const WEB_TAB := 3
const FAVORITES_TAB := 4
const ARCHIVE_TAB := 5
## Settings "library_cover_size" -> scale of the cover width the grid aims for.
## The grid then stretches or shrinks covers a little so the columns fill the width.
const COVER_SIZES := {"large": 1.5, "normal": 1.0, "small": 2.0 / 3.0, "smallest": 0.5}

var _filter_text := ""
## Book source to show ("" = all): a plugin id, "web" or "file".
var _source := ""
## The picked plugin's own filters: filter key -> option key.
var _plugin_filters := {}
## Tag to show ("" = any), see Library.has_tag.
var _tag := ""
var _show_filters := false  # phones: the filter row is opened from the top bar
var _content: VBoxContainer
var _scroll: ScrollContainer
var _grid: GridContainer
var _cards: Array[BookCard] = []
var _cols := 0
var _card_w := 0.0
var _relayout_queued := false
var _menu: PopupMenu
var _menu_book := ""
var _file_dialog: FileDialog
var _dirty := true
var _rebuild_queued := false
## The top bar's filter box. Kept across top bar rebuilds (a sync or plugin
## change can rebuild it while you type), so it doesn't lose focus.
var _search: SearchBox


func _ready() -> void:
	_content = UI.vbox(28)
	_scroll = UI.scroll(UI.margin(_content, 32, 28, 32, 40))
	add_child(_full(_scroll))
	_scroll.resized.connect(_relayout_soon)
	get_viewport().size_changed.connect(_relayout_soon)
	_menu = PopupMenu.new()
	_menu.add_item("Open", 0)
	_menu.add_item("Edit details", 3)
	_menu.add_item("Check for new chapters", 1)
	_menu.add_separator()
	_menu.add_item("Remove from library", 2)
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	Library.changed.connect(func(): _dirty = true; _rebuild_soon())
	Plugins.changed.connect(func(): if visible: _rebuild())
	Settings.changed.connect(func(k): if k == "tag_aliases" and visible: _rebuild())
	Settings.changed.connect(func(k): if (k == "library_sort" or k == "library_sort_desc") and visible: _rebuild_soon())
	Settings.changed.connect(func(k): if k == "library_cover_size" and visible: _relayout_soon())


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
	return "Library"


func tabs() -> PackedStringArray:
	return FILTERS


func build_actions(bar: HBoxContainer) -> void:
	if not compact:
		bar.add_child(_search_field())
		bar.add_child(UI.button("Import", "import", "", import_dialog))
		bar.add_child(UI.button("Add web novel", "plus", "PrimaryButton", func(): main.pages.browse.tab = 0; main.navigate("browse")))
	else:
		var f := UI.icon_button("filter", "Filter by source", func(): _show_filters = not _show_filters; header_changed.emit(); _rebuild())
		if _filters_active():
			f.icon = Icons.get_icon("filter", UiTheme.ACCENT, 20)
		bar.add_child(f)
		bar.add_child(UI.icon_button("import", "Import ebook", import_dialog))
		bar.add_child(UI.icon_button("plus", "Add web novel", func(): main.navigate("browse")))


func _search_field() -> SearchBox:
	if _search == null:
		_search = SearchBox.new("Filter books", 220.0)
		_search.field.text_changed.connect(func(t): _filter_text = t; _rebuild())
	if _search.field.text != _filter_text:
		_search.field.text = _filter_text
	if _search.get_parent():
		_search.get_parent().remove_child(_search)
	return _search


func on_shown() -> void:
	_rebuild()


func _on_tab(_i: int) -> void:
	_rebuild()


func set_compact(v: bool) -> void:
	super(v)
	if is_inside_tree():
		var m: MarginContainer = _content.get_parent()
		for side in ["left", "right"]:
			m.add_theme_constant_override("margin_" + side, 16 if v else 32)
		_rebuild()


func _rebuild() -> void:
	if _content == null:
		return
	UI.clear(_content)
	_grid = null
	_cards.clear()
	_cols = 0
	_card_w = 0.0
	var books := _filtered()
	if Library.books.is_empty():
		_content.add_child(_empty_state())
		return
	if tab == READING_TAB and _filter_text == "" and not _filters_active() and not books.is_empty():
		_content.add_child(_hero(_most_recent(books)))

	var header := UI.hbox(10)
	var heading := UI.hbox(10)  # its own row, so the count stays on the title's baseline
	heading.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heading.add_child(UI.label("All books" if tab == ALL_TAB else FILTERS[tab], "H2"))
	var count := UI.label(str(books.size()), "Muted")
	count.size_flags_vertical = Control.SIZE_SHRINK_END
	heading.add_child(count)
	header.add_child(heading)
	header.add_child(UI.spacer())
	header.add_child(_sort_pick())
	header.add_child(_sort_dir_button())
	_content.add_child(header)
	if not compact or _show_filters or _filters_active():
		var row := _filter_row()
		if row:
			_content.add_child(row)

	if books.is_empty():
		var none := "Nothing here yet."
		if tab == READING_TAB and _filter_text == "" and not _filters_active():
			none = "No books in progress. Open one from All to start reading."
		elif tab == FAVORITES_TAB and _filter_text == "" and not _filters_active():
			none = "No favorites yet. Press Favorite on a book's Details tab to add it here."
		elif tab == ARCHIVE_TAB and _filter_text == "" and not _filters_active():
			none = "Nothing archived. Books you archive from their Details tab move here, out of Reading, the other tabs and Updates. Favorites keep showing in Favorites."
		_content.add_child(UI.label(none, "Muted", true))
		return
	var layout := _grid_layout(_measure_width(), _grid_target(), _grid_gap())
	_grid = GridContainer.new()
	_grid.columns = layout[0]
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN  # keeps covers 2:3 when the page is wider than the window
	_grid.add_theme_constant_override("h_separation", 16 if compact else 22)
	_grid.add_theme_constant_override("v_separation", 20)
	_cards.clear()
	for b in books:
		var card := BookCard.new()
		card.setup(b, layout[1])
		card.open_requested.connect(func(id): main.open_reader(id))
		card.menu_requested.connect(_show_menu)
		_grid.add_child(card)
		_cards.append(card)
	_cols = layout[0]
	_card_w = layout[1]
	_content.add_child(_grid)
	_relayout_soon()


## Cover scale from the setting, 1.0 for anything unexpected.
func _cover_scale() -> float:
	return float(COVER_SIZES.get(str(Settings.get_value("library_cover_size")), 1.0))


## Columns and card width that exactly fill w: pick the column count whose
## ideal row (target + gap each) best matches, then split the width evenly.
## Covers end up up to about half a column narrower or wider than the target.
static func _grid_layout(w: float, target: float, gap: float) -> Array:
	w = maxf(w, 1.0)
	var n := maxi(1, roundi((w + gap) / (target + gap)))
	return [n, floor((w - gap * float(n - 1)) / float(n))]


func _grid_gap() -> float:
	return 16.0 if compact else 22.0


func _grid_target() -> float:
	return (150.0 if compact else 168.0) * _cover_scale()


## The width the grid actually gets: the scroller's width minus the content
## margins, always reserving the vertical scrollbar's width so showing or
## hiding it can't change the answer (that feedback loop would never settle).
## Capped at the window's right edge: a wide top bar can stretch the page past
## it on narrow windows, and the covers should still fit what you can see.
func _measure_width() -> float:
	if _scroll != null and _scroll.size.x > 0:
		var m := _content.get_parent() as MarginContainer
		var side := float(m.get_theme_constant("margin_left") + m.get_theme_constant("margin_right"))
		var visible_w := minf(_scroll.size.x, get_viewport_rect().size.x - _scroll.global_position.x)
		return visible_w - side - _scrollbar_reserve()
	return get_viewport_rect().size.x - (32.0 if compact else 236.0 + 64.0)


func _scrollbar_reserve() -> float:
	var sb := _scroll.get_v_scroll_bar()
	if sb == null:
		return 0.0
	if sb.visible and sb.size.x > 0:
		return sb.size.x
	return sb.get_combined_minimum_size().x


## Recompute columns and card widths in place, without rebuilding the cards.
## Runs deferred so the scroller has its real size; a no-op unless the
## columns or width actually changed, so a resize settles after one pass.
func _relayout_soon() -> void:
	if _relayout_queued:
		return
	_relayout_queued = true
	_relayout_now.call_deferred()


func _relayout_now() -> void:
	_relayout_queued = false
	if not visible or _grid == null or not is_instance_valid(_grid):
		return
	var layout := _grid_layout(_measure_width(), _grid_target(), _grid_gap())
	if layout[0] == _cols and layout[1] == _card_w:
		return
	_cols = layout[0]
	_card_w = layout[1]
	_grid.columns = _cols
	for card in _cards:
		if is_instance_valid(card):
			card.set_card_width(_card_w)


func _filtered() -> Array:
	var out := []
	for b in Library.books:
		if _archive_hides(b):
			continue
		match tab:
			READING_TAB:
				if not Library.is_reading(b): continue
			EBOOKS_TAB:
				if b.kind == "web": continue
			WEB_TAB:
				if b.kind != "web": continue
			FAVORITES_TAB:
				if not Library.is_favorite(b): continue
			ARCHIVE_TAB:
				if not Library.is_archived(b): continue
		if _filter_text != "" and not (_filter_text.to_lower() in (b.title + " " + b.author + " " + " ".join(PackedStringArray(b.get("tags", [])))).to_lower()):
			continue
		if _source != "" and b.source != _source:
			continue
		if _tag != "" and not Library.matches_tag(b, _tag):
			continue
		if not _plugin_filters.is_empty() and not _plugin_match(b):
			continue
		out.append(b)
	BookSort.sort(out, _sort_key(), bool(Settings.get_value("library_sort_desc")))
	return out


## Archived books show only on the Archive tab, and on Favorites when they're
## favorites: a favorite you reread now and then stays at hand without coming
## back to Reading every time.
func _archive_hides(book: Dictionary) -> bool:
	return Library.is_archived(book) and tab != ARCHIVE_TAB and tab != FAVORITES_TAB


## The stored sort key, "recent" for anything unexpected.
func _sort_key() -> String:
	var key := str(Settings.get_value("library_sort"))
	return key if BookSort.ORDERS.has(key) else "recent"


func _sort_pick() -> Control:
	var keys := BookSort.ORDERS.keys()
	var pick := Picker.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for k in keys:
		pick.add_item("Sort: %s" % BookSort.ORDERS[k] if not compact else str(BookSort.ORDERS[k]))
	pick.select(keys.find(_sort_key()))
	pick.item_selected.connect(func(i: int): _on_sort_key(str(keys[i])))
	return pick


func _sort_dir_button() -> Control:
	var desc := bool(Settings.get_value("library_sort_desc"))
	var b := UI.icon_button("sort_desc" if desc else "sort_asc",
		"Descending: press for ascending" if desc else "Ascending: press for descending",
		_on_sort_dir)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


## Picking a key also resets the direction to that key's usual one; the
## Settings.changed hook above does the rebuild, so a synced change re-sorts too.
func _on_sort_key(key: String) -> void:
	Settings.set_value("library_sort", key)
	Settings.set_value("library_sort_desc", BookSort.default_descending(key))


func _on_sort_dir() -> void:
	Settings.set_value("library_sort_desc", not bool(Settings.get_value("library_sort_desc")))


## The most recently read of the given books, whatever the grid's sort order is.
static func _most_recent(books: Array) -> Dictionary:
	var best: Dictionary = books[0]
	for b in books:
		if b.last_read > best.last_read:
			best = b
	return best


func _filters_active() -> bool:
	return _source != "" or _tag != "" or not _plugin_filters.is_empty()


## Opens the library showing every book with a tag (from a tag on a book's Details tab).
func show_tag(tag: String) -> void:
	_tag = Library.main_tag(tag)
	tab = ALL_TAB
	_filter_text = ""
	_source = ""
	_plugin_filters.clear()
	main.navigate("library")


func _plugin_match(book: Dictionary) -> bool:
	var p := Plugins.get_plugin(_source)
	if p == null:
		return true
	for key in _plugin_filters:
		if not p.library_filter_matches(book, key, _plugin_filters[key]):
			return false
	return true


## Source picker, the picked plugin's own filters, and a tag picker. null when
## every book has the same source and no book has tags.
func _filter_row() -> Control:
	var sources := {}
	for b in Library.books:
		if _archive_hides(b):
			continue
		sources[b.source] = true
	var every := Library.all_tags()
	if sources.size() < 2 and _source == "" and every.is_empty() and _tag == "":
		return null
	var names := {}
	for id in sources:
		names[id] = "Imported files" if id == "file" else ("Web pages" if id == "web" else _plugin_name(id))
	var ids := sources.keys()
	ids.sort_custom(func(a, c): return names[a].naturalnocasecmp_to(names[c]) < 0)
	ids.push_front("")
	names[""] = "All sources"
	if _source != "" and not names.has(_source):  # its last book was just removed
		ids.append(_source)
		names[_source] = _plugin_name(_source)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 10)
	if ids.size() > 2 or _source != "":
		var pick := Picker.new()
		pick.focus_mode = Control.FOCUS_NONE
		for id in ids:
			pick.add_item(names[id])
		pick.select(ids.find(_source))
		pick.item_selected.connect(func(i):
			_source = ids[i]
			_plugin_filters.clear()
			header_changed.emit()
			_rebuild())
		row.add_child(pick)
	var tags := Library.all_tags(_source)
	if not tags.is_empty() or _tag != "":
		row.add_child(_tag_pick(tags))

	var p := Plugins.get_plugin(_source) if _source != "" else null
	if p:
		for f in p.library_filters():
			row.add_child(_plugin_filter_pick(f))
	if _filters_active():
		row.add_child(UI.button("Clear", "x", "GhostButton", func():
			_source = ""
			_tag = ""
			_plugin_filters.clear()
			header_changed.emit()
			_rebuild()))
	return row


func _tag_pick(tags: Array) -> Control:
	var at := -1
	for i in tags.size():
		if tags[i].to_lower() == _tag.to_lower():
			at = i
	if _tag != "" and at < 0:  # its last book was just untagged
		tags = tags + [_tag]
		at = tags.size() - 1
	var pick := Picker.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.add_item("Tag: Any")
	for t in tags:
		pick.add_item("Tag: %s" % t)
	pick.select(at + 1)
	pick.item_selected.connect(func(i):
		_tag = "" if i == 0 else tags[i - 1]
		header_changed.emit()
		_rebuild())
	return pick


## One of a plugin's filters: {key, label, options: [{key, label}]}, with "Any" first.
func _plugin_filter_pick(f: Dictionary) -> Control:
	var key := str(f.get("key", ""))
	var options: Array = f.get("options", [])
	var pick := Picker.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.add_item("%s: Any" % f.get("label", key))
	for o in options:
		pick.add_item("%s: %s" % [f.get("label", key), o.get("label", o.get("key", ""))])
	var at := 0
	for i in options.size():
		if _plugin_filters.has(key) and str(options[i].get("key", "")) == _plugin_filters[key]:
			at = i + 1
	pick.select(at)
	pick.item_selected.connect(func(i):
		if i == 0:
			_plugin_filters.erase(key)
		else:
			_plugin_filters[key] = str(options[i - 1].get("key", ""))
		header_changed.emit()
		_rebuild())
	return pick


func _plugin_name(id: String) -> String:
	var n := Plugins.display_name(id)
	return n if n != "" else id


func _hero(book: Dictionary) -> Control:
	var card := UI.panel("Card")
	var col := UI.vbox(10)
	var row := UI.hbox(14 if compact else 22)
	var cover := CoverView.new()
	cover.radius = 8
	cover.custom_minimum_size = Vector2(112, 168) if not compact else Vector2(80, 120)
	# the row grows with a wrapping title; filling it would stretch the cover out of 2:3
	cover.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cover.set_book(book)
	row.add_child(cover)
	var info := UI.vbox(6)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label("CONTINUE READING", "AccentLabel"))
	var t := UI.label(book.title, "H1")
	t.add_theme_font_override("font", UiTheme.serif_bold)
	t.add_theme_font_size_override("font_size", 20 if compact else 26)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(t)
	var ch_title: String = book.chapters[book.progress.chapter].title if book.progress.chapter < book.chapters.size() else ""
	var where := "Section %d of %d" % [book.progress.chapter + 1, book.chapters.size()]
	var sub := UI.label(("%s  ·  %s" % [ch_title, where]) if ch_title != "" else where, "Muted")
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.custom_minimum_size.x = 120
	var details := UI.vbox(6)
	details.add_child(sub)
	var bar := UI.progress(Library.progress_ratio(book), 4)
	bar.custom_minimum_size.x = 120
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_child(UI.margin(bar, 0, 6, 0, 8))
	var buttons := UI.hbox(10)
	buttons.add_child(UI.button("Continue", "book", "PrimaryButton", func(): main.open_reader(book.id)))
	buttons.add_child(UI.button("" if compact else "Listen", "headphones", "", func():
		var want: String = book.id
		await main.open_reader(book.id)
		var reader: ReaderPage = main.pages.reader
		if main.current == reader and reader.book.get("id", "") == want:
			reader.start_tts()))
	details.add_child(buttons)
	info.add_child(details)
	row.add_child(info)
	col.add_child(row)
	card.add_child(col)
	# With a title too tall to leave room beside the cover, the details move under the
	# cover and use the card's full width. Moving them doesn't change the title column's
	# width, so the choice can't flip back and forth.
	var place := func():
		if not is_instance_valid(details):
			return
		var sep := info.get_theme_constant("separation")
		var beside := t.position.y + t.size.y + sep + details.get_combined_minimum_size().y
		var want: Control = col if beside > cover.size.y + 1 else info
		if details.get_parent() != want:
			details.reparent(want, false)
	info.resized.connect(func(): place.call_deferred())
	return card


func _empty_state() -> Control:
	var col := UI.vbox(14)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(UI.label("Your library is empty", "H1"))
	col.add_child(UI.label("Import an EPUB or text file, or add a web serial from a site you have a plugin for, or from any page in the Web tab.", "Muted", true))
	var actions := HFlowContainer.new()  # wraps on narrow (phone) screens
	actions.add_theme_constant_override("h_separation", 10)
	actions.add_theme_constant_override("v_separation", 10)
	actions.add_child(UI.button("Import ebook", "import", "PrimaryButton", import_dialog))
	actions.add_child(UI.button("Browse web novels", "compass", "", func(): main.navigate("browse")))
	col.add_child(actions)
	return UI.margin(col, 0, 80, 0, 0)


func import_dialog() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.use_native_dialog = true
		_file_dialog.filters = PackedStringArray(["*.epub ; EPUB ebooks", "*.txt ; Text files"])
		_file_dialog.files_selected.connect(_import_files)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.6)


## A file that looks like a later part of a book already imported (the next
## chapters of a serial) can be added to that book instead; see Library.find_series_book.
func _import_files(paths: PackedStringArray) -> void:
	for p in paths:
		var parsed := Library.read_file(p)
		if parsed.has("error"):
			main.toast(parsed.error, "error")
			continue
		var into := Library.find_series_book(parsed)
		var fresh := Library.new_chapters_for(into.id, parsed) if not into.is_empty() else []
		if not fresh.is_empty():
			var choice := [""]
			var skipped: int = parsed.chapters.size() - fresh.size()
			var d := ConfirmDialog.open(main, {
				"title": "Add to “%s”?" % into.title,
				"text": "“%s” looks like more of “%s”, which is in your library with %d chapters. Add its %d new chapter(s) to the end of that book%s, or import it as a separate book?" % [
					parsed.title, into.title, into.chapters.size(), fresh.size(),
					" (%d it already has are skipped)" % skipped if skipped > 0 else ""],
				"icon": "import", "confirm": "Add to book", "confirm_icon": "import",
				"alt": "Import separately", "alt_then": func(): choice[0] = "new",
			}, func(): choice[0] = "add")
			await d.tree_exited
			if choice[0] == "add":
				if Library.get_book(into.id).is_empty():
					main.toast("That book is no longer in your library", "error")
				else:
					Library.append_chapters(into.id, parsed, fresh)
					main.toast("Added %d chapter(s) to “%s”" % [fresh.size(), into.title], "ok")
				continue
			if choice[0] != "new":
				continue
		var r := Library.add_imported(parsed, p)
		main.toast("Imported “%s”" % r.title, "ok")


func _show_menu(id: String, at: Vector2) -> void:
	_menu_book = id
	var book := Library.get_book(id)
	var archived := Library.is_archived(book)
	_menu.set_item_disabled(_menu.get_item_index(1), book.kind != "web" or archived)
	_menu.set_item_tooltip(_menu.get_item_index(1), "Archived books are only checked from their chapter list" if archived and book.kind == "web" else "")
	_menu.set_item_disabled(_menu.get_item_index(3), Library.editable_fields(book).is_empty())
	_menu.position = Vector2i(at * get_window().content_scale_factor)
	_menu.popup()


func _on_menu(id: int) -> void:
	var book := Library.get_book(_menu_book)
	if book.is_empty():
		return
	match id:
		0: main.open_reader(book.id)
		3: BookEditor.open(main, book.id, func(): main.toast("Details saved", "ok"))
		1:
			var r := await Sources.refresh(book)
			main.toast(r.error if r.error != "" else "%d new chapter(s)" % r.new, "error" if r.error != "" else "ok")
		2:
			Library.remove_book(book.id)
			main.toast("Removed “%s”" % book.title)


static func _full(c: Control) -> Control:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	return c
