class_name BookEditor
extends Control
## Modal editor for an imported book's title, author, tags and description.
## Usage: BookEditor.open(main, book_id, then)  (then is called after saving)

signal closed

var book_id := ""
var _then: Callable
var _title: LineEdit
var _author: LineEdit
var _tags: LineEdit
var _synopsis: TextEdit
var _suggest: HFlowContainer
var _status: Label
var _body: VBoxContainer
var _scroll: ScrollContainer


static func open(host: Control, id: String, then := Callable()) -> BookEditor:
	var ed := BookEditor.new()
	ed.book_id = id
	ed._then = then
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(ed)
	ed._build(Library.get_book(id))
	return ed


func _build(book: Dictionary) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _close())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var card := UI.panel("Card")
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE, 16, UiTheme.BORDER, 1, Vector4(24, 22, 24, 22)))
	card.custom_minimum_size.x = minf(560, get_viewport_rect().size.x - 24)
	center.add_child(card)
	var col := UI.vbox(12)
	card.add_child(col)

	var head := UI.hbox(10, [UI.icon("pencil", UiTheme.ACCENT, 22), UI.label("Edit details", "H2")])
	head.add_child(UI.spacer())
	head.add_child(UI.icon_button("x", "Close", _close))
	col.add_child(head)
	# the fields scroll when the window is too short for them (phones in landscape)
	_body = UI.vbox(12)
	_scroll = UI.scroll(_body)
	col.add_child(_scroll)

	_title = _field(_body, "Title", book.get("title", ""), "Book title")
	_author = _field(_body, "Author", book.get("author", ""), "Unknown")
	_tags = _field(_body, "Tags", ", ".join(PackedStringArray(book.get("tags", []))), "Separate tags with commas, e.g. Fantasy, Finished")
	_tags.text_changed.connect(func(_t): _fill_suggestions())
	_suggest = HFlowContainer.new()
	_suggest.add_theme_constant_override("h_separation", 6)
	_suggest.add_theme_constant_override("v_separation", 6)
	_body.add_child(_suggest)

	_body.add_child(UI.label("DESCRIPTION", "Overline"))
	_synopsis = TextEdit.new()
	_synopsis.text = book.get("synopsis", "")
	_synopsis.custom_minimum_size.y = 120 if get_viewport_rect().size.y > 640 else 72
	_synopsis.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_synopsis.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 8, UiTheme.BORDER, 1, Vector4(10, 8, 10, 8)))
	_synopsis.add_theme_stylebox_override("focus", UiTheme.box(UiTheme.SURFACE, 8, UiTheme.ACCENT, 1, Vector4(10, 8, 10, 8)))
	_synopsis.add_theme_color_override("font_color", UiTheme.TEXT)
	_body.add_child(_synopsis)
	_fill_suggestions()

	_status = UI.label("", "Small", true)
	_status.add_theme_color_override("font_color", UiTheme.BAD)
	_status.visible = false
	col.add_child(_status)

	var buttons := UI.hbox(10)
	buttons.add_child(UI.spacer())
	buttons.add_child(UI.button("Cancel", "", "GhostButton", _close))
	buttons.add_child(UI.button("Save", "check", "PrimaryButton", _save))
	col.add_child(UI.margin(buttons, 0, 6, 0, 0))
	_title.grab_focus.call_deferred()


## Tags other books have that this one doesn't yet: click to add.
func _fill_suggestions() -> void:
	UI.clear(_suggest)
	var have := Library.clean_tags(_tags.text)
	var lower := have.map(func(t): return t.to_lower())
	var shown := 0
	for tag in Library.all_tags():
		if tag.to_lower() in lower:
			continue
		if shown == 0:
			_suggest.add_child(UI.label("Add:", "Small"))
		var b := UI.button(tag, "plus", "ChipButton", func():
			_tags.text = ", ".join(PackedStringArray(Library.clean_tags(_tags.text) + [tag]))
			_fill_suggestions(), UiTheme.MUTED)
		_suggest.add_child(b)
		shown += 1
		if shown >= 12:
			break
	_suggest.visible = shown > 0
	_fit.call_deferred()


func _fit() -> void:
	if _scroll:
		_scroll.custom_minimum_size.y = minf(_body.get_combined_minimum_size().y, get_viewport_rect().size.y - 190)


func _field(col: VBoxContainer, label: String, value: String, placeholder: String) -> LineEdit:
	col.add_child(UI.label(label.to_upper(), "Overline"))
	var le := LineEdit.new()
	le.text = value
	le.placeholder_text = placeholder
	le.custom_minimum_size.y = 40
	le.text_submitted.connect(func(_t): _save())
	col.add_child(le)
	return le


func _save() -> void:
	var err := Library.edit_details(book_id, {
		"title": _title.text, "author": _author.text, "tags": _tags.text, "synopsis": _synopsis.text,
	})
	if err != "":
		_status.text = err
		_status.visible = true
		return
	_close()
	if _then.is_valid():
		_then.call()


func _close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
