class_name ReaderBookmarks
extends RefCounted
## The reader's Bookmarks tab: lists the book's bookmarks and lets the reader rename,
## edit or remove them. The ReaderPage keeps the tabs and the text view; this helper
## builds its own rows and calls back into the page for rendering and for jumping to
## a bookmark.

var page: ReaderPage
var view: Control
var list: VBoxContainer


func _init(p: ReaderPage) -> void:
	page = p


func build_view() -> void:
	list = UI.vbox(8)
	var scroll := UI.scroll(UI.margin(list, 0, 20, 0, 40))
	view = UI.margin(scroll, 8 if page.compact else 24, 0, 8 if page.compact else 24, 0)
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	view.hide()
	page.add_child(view)


func build() -> void:
	UI.clear(list)
	var marks := Library.bookmarks(page.book)
	var mobile := OS.has_feature("mobile")
	var how := "Long-press" if mobile else "Right-click"
	var pick := "Bookmark" if mobile else "Bookmark this paragraph"
	var side := 6 if page.compact else 12
	list.add_child(UI.margin(UI.label("%d bookmark%s" % [marks.size(), "" if marks.size() == 1 else "s"], "H2"), side, 0, side, 4))
	if marks.is_empty():
		var hint := UI.label("%s a paragraph while reading and choose “%s” to add one. You can give each bookmark a name." % [how, pick], "Muted", true)
		list.add_child(UI.margin(hint, side, 0, side, 0))
		return
	list.add_child(UI.margin(UI.label("%s a paragraph while reading to add more." % how, "Small", true), side, 0, side, 8))
	for m in marks:
		list.add_child(_bookmark_row(m))


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
	var ch_title: String = page.book.chapters[m.chapter].title if m.chapter < page.book.chapters.size() else ""
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
	b.pressed.connect(func(): page.go_to_bookmark(m))
	var row := UI.hbox(4, [b])
	var edit := UI.icon_button("pencil", "Rename", func(): _rename_bookmark(m))
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(edit)
	var del := UI.icon_button("trash", "Remove bookmark", func():
		Library.remove_bookmark(page.book.id, m.id)
		_after_bookmarks_changed()
		page.main.toast("Bookmark removed.", "info"))
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(del)
	return row


## Opens the dialog to add a bookmark at paragraph i of this chapter, or to rename
## or remove the one that's there.
func edit_bookmark(i: int) -> void:
	if i < 0 or i >= page._items.size():
		return
	var existing := Library.bookmark_at(page.book, page.chapter, i)
	var excerpt := _paragraph_excerpt(i)
	var opts := {
		"title": "Edit bookmark" if not existing.is_empty() else "Add bookmark", "icon": "bookmark",
		"text": "Chapter %d · “%s”" % [page.chapter + 1, excerpt.left(140) + ("…" if excerpt.length() > 140 else "")],
		"input": existing.get("name", ""), "input_hint": "Name (optional)",
		"confirm": "Save", "confirm_icon": "check",
	}
	var id: String = page.book.id
	var at := page.chapter
	if not existing.is_empty():
		var remove := func():
			Library.remove_bookmark(id, existing.id)
			_after_bookmarks_changed()
			page.main.toast("Bookmark removed.", "info")
		opts.merge({"alt": "Remove", "alt_icon": "trash", "alt_then": remove})
	var save := func(typed: String):
		if page.book.get("id", "") != id:
			return
		if existing.is_empty():
			Library.add_bookmark(id, at, i, typed, excerpt.left(200))
			page.main.toast("Bookmark added.", "ok")
		else:
			Library.rename_bookmark(id, existing.id, typed)
		_after_bookmarks_changed()
	ConfirmDialog.open(page.main, opts, save)


func _rename_bookmark(m: Dictionary) -> void:
	ConfirmDialog.open(page.main, {
		"title": "Rename bookmark", "icon": "pencil", "text": "“%s”" % m.text.left(140) if m.text != "" else "",
		"input": m.name, "input_hint": "Name (optional)", "confirm": "Save", "confirm_icon": "check",
	}, func(typed: String):
		Library.rename_bookmark(page.book.id, m.id, typed)
		_after_bookmarks_changed())


func _after_bookmarks_changed() -> void:
	page.book = Library.get_book(page.book.id)
	page._render()
	if view.visible:
		build()


## The shown text of paragraph i, on one line.
func _paragraph_excerpt(i: int) -> String:
	var t := ReaderPage._visible_text(page._items[i].bb).replace("\n", " ").strip_edges()
	return RegEx.create_from_string("\\s+").sub(t, " ", true)
