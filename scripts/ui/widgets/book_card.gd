class_name BookCard
extends Button
## Library grid card: cover, title, author and reading progress.

signal open_requested(id: String)
signal menu_requested(id: String, at: Vector2)

var book_id := ""


func setup(book: Dictionary, width := 168.0) -> void:
	book_id = book.id
	flat = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(width, 0)
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		add_theme_stylebox_override(s, StyleBoxEmpty.new())
	var col := UI.vbox(6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_preset(Control.PRESET_TOP_WIDE)
	col.custom_minimum_size.x = width

	var cover_box := Control.new()
	cover_box.custom_minimum_size = Vector2(width, width * 1.5)
	cover_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover := CoverView.new()
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.radius = 10
	cover.set_book(book)
	cover_box.add_child(cover)
	var badge := UI.panel("Badge", UI.label(_badge_text(book), "Small"))
	badge.get_child(0).add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	badge.position = Vector2(8, 8)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover_box.add_child(badge)
	col.add_child(cover_box)

	var title := UI.label(book.title, "H3")
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.custom_minimum_size.x = width
	title.add_theme_font_size_override("font_size", 14)
	col.add_child(UI.margin(title, 2, 4, 2, 0))
	var author := UI.label(book.author if book.author != "" else _source_name(book), "Small")
	author.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	author.custom_minimum_size.x = width
	col.add_child(UI.margin(author, 2, -4, 2, 0))

	var ratio := Library.progress_ratio(book)
	var prog_row := UI.hbox(8)
	var bar := UI.progress(ratio, 3)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prog_row.add_child(bar)
	var n: int = book.chapters.size()
	var pct := UI.label("%d%%" % int(ratio * 100) if book.last_read > 0 else "New", "Small")
	if book.last_read == 0:
		pct.add_theme_color_override("font_color", UiTheme.ACCENT)
	prog_row.add_child(pct)
	prog_row.tooltip_text = "%d chapters" % n
	col.add_child(UI.margin(prog_row, 2, 0, 2, 0))
	add_child(col)
	custom_minimum_size.y = width * 1.5 + 86
	pressed.connect(func(): open_requested.emit(book_id))
	gui_input.connect(_on_input)


func _on_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		menu_requested.emit(book_id, get_global_mouse_position())
	elif e is InputEventScreenTouch and e.pressed and e.double_tap:
		menu_requested.emit(book_id, e.position)


static func _badge_text(book: Dictionary) -> String:
	match book.kind:
		"epub": return "EPUB"
		"txt": return "TXT"
	return "RSS" if book.get("rss_only", false) else "WEB"


static func _source_name(book: Dictionary) -> String:
	if book.kind != "web":
		return "Imported file"
	var p := Plugins.for_url(book.url)
	return p.name if p else book.url.get_slice("/", 2).trim_prefix("www.")
