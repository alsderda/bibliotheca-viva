class_name LibraryPage
extends Page
## Book grid with "continue reading" hero and filters in the top bar.

const FILTERS := ["All", "Reading", "Ebooks", "Web serials"]

var _filter_text := ""
## Book source to show ("" = all): a plugin id, "web" or "file".
var _source := ""
## The picked plugin's own filters: filter key -> option key.
var _plugin_filters := {}
## Tag to show ("" = any), see Library.has_tag.
var _tag := ""
var _show_filters := false  # phones: the filter row is opened from the top bar
var _content: VBoxContainer
var _menu: PopupMenu
var _menu_book := ""
var _file_dialog: FileDialog
var _dirty := true
var _rebuild_queued := false


func _ready() -> void:
	_content = UI.vbox(28)
	add_child(_full(UI.scroll(UI.margin(_content, 32, 28, 32, 40))))
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
		var search := LineEdit.new()
		search.theme_type_variation = "SearchField"
		search.placeholder_text = "Filter books"
		search.custom_minimum_size.x = 220
		search.text = _filter_text
		search.right_icon = Icons.get_icon("search", UiTheme.FAINT, 18)
		search.text_changed.connect(func(t): _filter_text = t; _rebuild())
		bar.add_child(search)
		bar.add_child(UI.button("Import", "import", "", import_dialog))
		bar.add_child(UI.button("Add web novel", "plus", "PrimaryButton", func(): main.pages.browse.tab = 0; main.navigate("browse")))
	else:
		var f := UI.icon_button("filter", "Filter by source", func(): _show_filters = not _show_filters; header_changed.emit(); _rebuild())
		if _filters_active():
			f.icon = Icons.get_icon("filter", UiTheme.ACCENT, 20)
		bar.add_child(f)
		bar.add_child(UI.icon_button("import", "Import ebook", import_dialog))
		bar.add_child(UI.icon_button("plus", "Add web novel", func(): main.navigate("browse")))


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
	var books := _filtered()
	if Library.books.is_empty():
		_content.add_child(_empty_state())
		return
	var last := Library.last_read()
	if tab == 0 and _filter_text == "" and not _filters_active() and not last.is_empty():
		_content.add_child(_hero(last))

	var header := UI.hbox(10)
	header.add_child(UI.label(FILTERS[tab] if tab > 0 else "All books", "H2"))
	var count := UI.label(str(books.size()), "Muted")
	count.size_flags_vertical = Control.SIZE_SHRINK_END
	header.add_child(count)
	_content.add_child(header)
	if not compact or _show_filters or _filters_active():
		var row := _filter_row()
		if row:
			_content.add_child(row)

	if books.is_empty():
		_content.add_child(UI.label("Nothing here yet.", "Muted"))
		return
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16 if compact else 22)
	flow.add_theme_constant_override("v_separation", 20)
	var avail := get_viewport_rect().size.x - (32 if compact else 236 + 64)
	var width := 168.0
	if compact:
		width = floor((avail - 32) / 2.0) if avail < 520 else 150.0
	for b in books:
		var card := BookCard.new()
		card.setup(b, width)
		card.open_requested.connect(func(id): main.open_reader(id))
		card.menu_requested.connect(_show_menu)
		flow.add_child(card)
	_content.add_child(flow)


func _filtered() -> Array:
	var out := []
	for b in Library.books:
		match tab:
			1:
				if not Library.is_reading(b): continue
			2:
				if b.kind == "web": continue
			3:
				if b.kind != "web": continue
		if _filter_text != "" and not (_filter_text.to_lower() in (b.title + " " + b.author + " " + " ".join(PackedStringArray(b.get("tags", [])))).to_lower()):
			continue
		if _source != "" and b.source != _source:
			continue
		if _tag != "" and not Library.has_tag(b, _tag):
			continue
		if not _plugin_filters.is_empty() and not _plugin_match(b):
			continue
		out.append(b)
	out.sort_custom(func(a, c): return max(a.last_read, a.added) > max(c.last_read, c.added))
	return out


func _filters_active() -> bool:
	return _source != "" or _tag != "" or not _plugin_filters.is_empty()


## Opens the library showing every book with a tag (from a tag on a book's Details tab).
func show_tag(tag: String) -> void:
	_tag = tag
	tab = 0
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
		sources[b.source] = true
	var tags := Library.all_tags()
	if sources.size() < 2 and _source == "" and tags.is_empty() and _tag == "":
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
		var pick := OptionButton.new()
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
	var pick := OptionButton.new()
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
	var pick := OptionButton.new()
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
	var row := UI.hbox(14 if compact else 22)
	var cover := CoverView.new()
	cover.radius = 8
	cover.custom_minimum_size = Vector2(92, 138) if not compact else Vector2(64, 96)
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
	info.add_child(sub)
	var bar := UI.progress(Library.progress_ratio(book), 4)
	bar.custom_minimum_size.x = 120
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.margin(bar, 0, 6, 0, 8))
	var buttons := UI.hbox(10)
	buttons.add_child(UI.button("Continue", "book", "PrimaryButton", func(): main.open_reader(book.id)))
	buttons.add_child(UI.button("" if compact else "Listen", "headphones", "", func(): main.open_reader(book.id); main.pages.reader.start_tts()))
	info.add_child(buttons)
	row.add_child(info)
	card.add_child(row)
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
	_menu.set_item_disabled(_menu.get_item_index(1), book.kind != "web")
	_menu.set_item_disabled(_menu.get_item_index(3), not Library.is_file_book(book))
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
