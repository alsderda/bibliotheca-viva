class_name SettingsSection
extends RefCounted
## Base for the Settings tabs. Each tab is a subclass that builds its cards into the
## page's content column. The row and control builders shared by the tabs live here.

var page: SettingsPage
var _content: VBoxContainer


func _init(p: SettingsPage, content: VBoxContainer) -> void:
	page = p
	_content = content


func _section(title: String, rows: Array) -> void:
	var card := UI.panel("Card")
	var col := UI.vbox(16)
	col.add_child(UI.label(title, "H3"))
	for r in rows:
		col.add_child(r)
	card.add_child(col)
	card.custom_minimum_size.x = 0
	_content.add_child(card)


## Label (and hint) beside a control; on narrow screens the control goes
## below the label at full width, except for switches which stay on the right.
func _row(label: String, hint: String, control: Control) -> Control:
	var v := UI.vbox(2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(label, "", page.compact))
	if hint != "":
		v.add_child(UI.label(hint, "Small", true))
	if page.compact and not control is CheckButton:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := UI.vbox(10, [v, control])
		return col
	var row := UI.hbox(16)
	row.add_child(v)
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	return row


## Line edit that is a fixed width beside its label, or full width when compact.
func _line_edit(text: String, width := 300) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size.x = 0 if page.compact else width
	return e


## Row of choice chips; wraps onto more lines when compact.
func _chip_row() -> Container:
	if not page.compact:
		return UI.hbox(6)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	return flow


func _slider(key: String, lo: float, hi: float, step: float, fmt := "%d") -> Control:
	var box := UI.hbox(12)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.custom_minimum_size = Vector2(220 if not page.compact else 80, 24)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL if page.compact else Control.SIZE_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var l := UI.label(fmt % s.value, "Muted")
	l.custom_minimum_size.x = 48
	s.value_changed.connect(func(v): l.text = fmt % v; Settings.set_value(key, v))
	box.add_child(s)
	box.add_child(l)
	return box


func _toggle(key: String) -> CheckButton:
	var c := CheckButton.new()
	c.button_pressed = bool(Settings.get_value(key))
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(v): Settings.set_value(key, v))
	return c


func _segmented(key: String, options: Array) -> Control:
	var row := _chip_row()
	var group := ButtonGroup.new()
	for o in options:
		var b := UI.button(o[1], "", "ChipButton")
		if page.compact:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Settings.get_value(key) == o[0]
		b.pressed.connect(func(): Settings.set_value(key, o[0]); page.rebuild_keep_scroll())
		row.add_child(b)
	return row
