class_name ConfirmDialog
extends Control
## Small in-app modal asking the user to confirm something.
## Usage: ConfirmDialog.open(host, {title, text, detail, icon, confirm, confirm_icon, danger}, then)
##   detail:  optional path/link shown in a monospace box under the text
##   danger:  red confirm button and icon, for removing things
##   alt, alt_icon, alt_then: an optional second choice, a button next to the confirm one
##   input:   adds a text field with this text (placeholder: input_hint); `then` gets what's typed
##   require: with input, the confirm button stays disabled until this word is typed (any case)

signal closed

var _then: Callable
var _input: LineEdit
var _require := ""
var _center: CenterContainer
var _card: PanelContainer
var _kb_height := -1.0


static func open(host: Control, opts: Dictionary, then: Callable) -> ConfirmDialog:
	var d := ConfirmDialog.new()
	d._then = then
	d.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(d)
	d._build(opts)
	return d


func _build(o: Dictionary) -> void:
	var danger: bool = o.get("danger", false)
	var tint := UiTheme.BAD if danger else UiTheme.ACCENT

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _close())
	add_child(dim)

	var center := CenterContainer.new()
	_center = center
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var card := UI.panel("Card")
	_card = card
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE, 16, UiTheme.BORDER, 1, Vector4(24, 22, 24, 20)))
	card.custom_minimum_size.x = minf(460, get_viewport_rect().size.x - 24)
	center.add_child(card)
	var col := UI.vbox(14)
	card.add_child(col)

	var badge := UI.panel("", UI.icon(o.get("icon", "info"), tint, 20))
	badge.add_theme_stylebox_override("panel", UiTheme.box(Color(tint, 0.14), 10, Color.TRANSPARENT, 0, Vector4(9, 9, 9, 9)))
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var title := UI.label(o.get("title", ""), "H2", true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UI.hbox(12, [badge, title]))

	if o.get("text", "") != "":
		col.add_child(UI.label(o.text, "Muted", true))
	if o.get("detail", "") != "":
		var dl := UI.label(o.detail, "Small", true)
		dl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY  # long paths and links have no spaces to break at
		dl.add_theme_font_override("font", UiTheme.mono)
		dl.add_theme_color_override("font_color", UiTheme.TEXT)
		var box := UI.panel("", dl)
		box.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE_2, 8, UiTheme.BORDER, 1, Vector4(12, 9, 12, 9)))
		col.add_child(box)

	if o.has("input"):
		_input = LineEdit.new()
		_input.text = o.input
		_input.placeholder_text = o.get("input_hint", "")
		_input.custom_minimum_size.y = 40
		_input.select_all_on_focus = true
		_input.text_submitted.connect(func(_t): _confirm())
		_require = o.get("require", "")
		col.add_child(_input)
		_input.grab_focus.call_deferred()

	var buttons := UI.hbox(10)
	buttons.add_child(UI.spacer())
	buttons.add_child(UI.button("Cancel", "", "GhostButton", _close))
	if o.get("alt", "") != "":
		var alt_then: Callable = o.get("alt_then", Callable())
		buttons.add_child(UI.button(o.alt, o.get("alt_icon", ""), "", func():
			_close()
			if alt_then.is_valid():
				alt_then.call()))
	var ok := UI.button(o.get("confirm", "OK"), o.get("confirm_icon", ""), "PrimaryButton", _confirm)
	if _require != "":
		ok.disabled = true
		_input.text_changed.connect(func(_t): ok.disabled = not _typed_required())
	if danger:
		var pad := Vector4(16, 9, 16, 9)
		ok.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.BAD, 8, Color.TRANSPARENT, 0, pad))
		ok.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.BAD.lightened(0.12), 8, Color.TRANSPARENT, 0, pad))
		ok.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.BAD.darkened(0.1), 8, Color.TRANSPARENT, 0, pad))
	buttons.add_child(ok)
	col.add_child(UI.margin(buttons, 0, 6, 0, 0))

	if _input == null or not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		set_process(false)


## Keeps the card in the part of the screen the on-screen keyboard leaves free.
## `height` is the keyboard's height in UI units (window pixels divided by the
## window's content_scale_factor); 0 means no keyboard. Centres the card in the
## space above the keyboard; when the card is taller than that space, its bottom
## (text field and buttons) sits right on the keyboard and the top runs off-screen.
func _fit_above_keyboard(height: float) -> void:
	if is_equal_approx(height, _kb_height):
		return
	_kb_height = height
	if height <= 0.0:
		_center.offset_top = 0
		_center.offset_bottom = 0
		return
	_center.offset_bottom = -height
	var free := size.y - height
	var need := _card.get_combined_minimum_size().y
	if need > free:
		_center.offset_top = free - need
	else:
		_center.offset_top = 0


# The keyboard height changes while it slides in and out, and no signal reports it.
func _process(_delta: float) -> void:
	_fit_above_keyboard(float(DisplayServer.virtual_keyboard_get_height()) / get_window().content_scale_factor)


func _confirm() -> void:
	if is_queued_for_deletion():
		return  # Enter in the text field also reaches _unhandled_key_input
	if not _typed_required():
		return
	_close()
	if _input:
		_then.call(_input.text)
	else:
		_then.call()


func _typed_required() -> bool:
	return _require == "" or _input.text.strip_edges().to_lower() == _require.to_lower()


func _close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_confirm()
		get_viewport().set_input_as_handled()
