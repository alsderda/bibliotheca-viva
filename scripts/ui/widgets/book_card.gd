class_name BookCard
extends Button
## Library grid card: cover, title, author and reading progress.

signal open_requested(id: String)
signal menu_requested(id: String, at: Vector2)

var book_id := ""
var _card_w := 0.0
var _col: VBoxContainer
var _cover_box: Control
var _badge: PanelContainer
var _title: Label
var _author: Label


func setup(book: Dictionary, width := 168.0) -> void:
	book_id = book.id
	flat = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		add_theme_stylebox_override(s, StyleBoxEmpty.new())
	_col = UI.vbox(6)
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.set_anchors_preset(Control.PRESET_TOP_WIDE)

	_cover_box = Control.new()
	_cover_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover := CoverView.new()
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.radius = 10
	cover.set_book(book)
	_cover_box.add_child(cover)
	_badge = UI.panel("Badge", UI.label(_badge_text(book), "Small"))
	_badge.get_child(0).add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover_box.add_child(_badge)
	_col.add_child(_cover_box)

	_title = UI.label(book.title, "H3")
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_col.add_child(UI.margin(_title, 2, 4, 2, 0))
	_author = UI.label(book.author if book.author != "" else _source_name(book), "Small")
	_author.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_col.add_child(UI.margin(_author, 2, -4, 2, 0))

	var ratio := Library.progress_ratio(book)
	var prog_row := UI.hbox(8)
	prog_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_col.add_child(UI.margin(prog_row, 2, 0, 2, 0))
	add_child(_col)
	set_card_width(width)
	pressed.connect(func(): open_requested.emit(book_id))
	gui_input.connect(_on_input)


## Resize without rebuilding: the grid calls this on every card when the
## window size or cover-size setting changes the column width.
func set_card_width(width: float) -> void:
	if _col == null or width == _card_w:
		return
	_card_w = width
	custom_minimum_size = Vector2(width, width * 1.5 + 86)
	_col.custom_minimum_size.x = width
	_cover_box.custom_minimum_size = Vector2(width, width * 1.5)
	# The badge sits at a fixed offset over the cover, so it fits at any
	# card size; it only moves in a little on the smallest cards.
	_badge.position = Vector2(6, 6) if width < 110 else Vector2(8, 8)
	_title.custom_minimum_size.x = width
	_title.add_theme_font_size_override("font_size", 12 if width < 110 else 14)
	_author.custom_minimum_size.x = width


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
