class_name Picker
extends Button
## A drop-down picker with the parts of OptionButton's API the pages use, for
## touch screens: OptionButton's list picks the row a drag ends on, so scrolling
## it on a phone changes the choice. Here a row is picked only by a tap (a press
## and release that barely moved and didn't scroll the list). Its width is capped
## to the window, long texts end in "…", so it never runs off a narrow screen.

signal item_selected(index: int)

## Widest the button gets, as a share of the window width.
const MAX_WIDTH_SHARE := 0.9
## How far (px) a press may move and still count as a tap.
const TAP_SLOP := 10.0

var _items: Array[String] = []
var _selected := -1
var _popover: Popover = null
var _press_index := -1
var _press_pos := Vector2.ZERO
var _press_scroll := 0


## A row is picked only by a tap: press and release close together with the
## list unmoved in between. Kept static so the self-test can check it headless.
static func is_tap(press_pos: Vector2, release_pos: Vector2, scroll_before: int, scroll_after: int) -> bool:
	if scroll_before != scroll_after:
		return false
	return press_pos.distance_to(release_pos) <= TAP_SLOP


func _init() -> void:
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Once clipped, the minimum size no longer tracks the text, so the width
	# is pinned by hand in _refresh_width; without that the cap below would
	# never take effect inside an HFlowContainer.
	clip_text = true
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pressed.connect(_open)


func _ready() -> void:
	_refresh_chrome()
	if not get_viewport().size_changed.is_connected(_on_resized):
		get_viewport().size_changed.connect(_on_resized)
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_inside_tree():
		_refresh_chrome()
		_refresh_width()
	elif what == NOTIFICATION_EXIT_TREE:
		# The list lives on the window root, so a page rebuild that frees this
		# picker would otherwise leave it open, pointing at nothing.
		_close_list()


## Popover doesn't follow its anchor, so a resize closes the list.
func _on_resized() -> void:
	_close_list()
	_refresh_width()


func _close_list() -> void:
	if is_instance_valid(_popover):
		var p := _popover
		_popover = null
		p.close()


func add_item(label: String) -> void:
	_items.append(label)
	if _selected == -1:
		_selected = 0
	_refresh()


func get_item_count() -> int:
	return _items.size()


func get_item_text(index: int) -> String:
	return _items[index] if index >= 0 and index < _items.size() else ""


## Shows [param index] as picked, without emitting item_selected (like OptionButton.select).
func select(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	_selected = index
	_refresh()


func get_selected() -> int:
	return _selected


func _refresh() -> void:
	text = _items[_selected] if _selected >= 0 and _selected < _items.size() else ""
	_refresh_width()


func _refresh_chrome() -> void:
	icon = Icons.get_icon("chev_down", UiTheme.TEXT, 18)


func _cap() -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	return vp.get_visible_rect().size.x * MAX_WIDTH_SHARE


func _refresh_width() -> void:
	if not is_inside_tree():
		return
	var cap := _cap()
	if cap <= 0.0:
		return
	custom_minimum_size.x = minf(_natural_width(text), cap)


func _natural_width(s: String) -> float:
	var w := 0.0
	if s != "":
		var font := get_theme_font("font")
		if font != null:
			w = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_font_size("font_size")).x
	var chrome := 0.0
	if has_theme_stylebox("normal"):
		var sb := get_theme_stylebox("normal")
		chrome += sb.content_margin_left + sb.content_margin_right
	if icon != null:
		chrome += icon.get_width() + get_theme_constant("h_separation")
	return w + chrome + 1.0


func _open() -> void:
	if _items.is_empty() or not is_inside_tree() or is_instance_valid(_popover):
		return
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	var row_cap := maxf(64.0, _cap() - 48.0)
	for i in _items.size():
		list.add_child(_make_row(i, row_cap))
	_popover = Popover.show_for(self, list)
	_popover.tree_exited.connect(_on_popover_closed)


func _on_popover_closed() -> void:
	_popover = null
	_press_index = -1


func _make_row(index: int, row_cap: float) -> Control:
	var row := PanelContainer.new()
	row.theme_type_variation = "Row"
	# Lets a drag pass through to the ScrollContainer (which Popover adds for
	# tall lists) while still reporting press/release to gui_input below.
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(h)
	var mark := TextureRect.new()
	mark.custom_minimum_size = Vector2(18, 18)
	mark.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if index == _selected:
		mark.texture = Icons.get_icon("check", UiTheme.ACCENT, 18)
	h.add_child(mark)
	var l := Label.new()
	l.text = _items[index]
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if index == _selected:
		l.add_theme_color_override("font_color", UiTheme.ACCENT)
	h.add_child(l)
	row.custom_minimum_size.x = minf(_natural_width(_items[index]) + 26.0, row_cap)
	row.gui_input.connect(_on_row_gui_input.bind(index, row))
	return row


func _on_row_gui_input(event: InputEvent, index: int, row: Control) -> void:
	# Button.pressed fires on release even after a scroll-drag, so rows decide
	# on raw press/release pairs instead. The event is never accepted here, so
	# dragging across rows still scrolls the list.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_press_index = index
			_press_pos = mb.position
			_press_scroll = _scroll_of(row)
		elif index == _press_index and _press_index != -1:
			var before := _press_scroll
			_press_index = -1
			if is_tap(_press_pos, mb.position, before, _scroll_of(row)):
				_pick(index)
	elif event is InputEventScreenTouch and not _touch_is_mouse():
		var st := event as InputEventScreenTouch
		if st.pressed:
			_press_index = index
			_press_pos = st.position
			_press_scroll = _scroll_of(row)
		elif index == _press_index and _press_index != -1:
			var before := _press_scroll
			_press_index = -1
			if is_tap(_press_pos, st.position, before, _scroll_of(row)):
				_pick(index)


## Touch screens report through emulated mouse events unless the project turns
## that off (this one doesn't: project.godot leaves the Godot default on), in
## which case raw touch would double-count each tap.
func _touch_is_mouse() -> bool:
	return bool(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true))


func _scroll_of(row: Control) -> int:
	var n := row.get_parent()
	while n != null:
		if n is ScrollContainer:
			return (n as ScrollContainer).scroll_vertical
		n = n.get_parent()
	return 0


func _pick(index: int) -> void:
	_close_list()
	_press_index = -1
	if index == _selected:
		return
	_selected = index
	_refresh()
	item_selected.emit(index)
